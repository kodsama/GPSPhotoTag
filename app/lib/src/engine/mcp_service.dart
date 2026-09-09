import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda_mcp/stunda_mcp.dart';

/// Signature matching [Isolate.spawn] for the worker that runs the MCP server.
/// Injected in tests to induce the spawn-failure error path.
typedef _IsolateSpawner = Future<Isolate> Function(
  void Function(_Config) entry,
  _Config message, {
  String? debugName,
  SendPort? onExit,
  SendPort? onError,
});

/// Runs the MCP server on a localhost TCP socket in a dedicated worker isolate,
/// started automatically when the app launches - so an LLM always has a live
/// endpoint while Stunda is open, without ever touching the UI isolate.
class McpService extends ChangeNotifier {
  /// Creates the service. [exiftoolBundleDir] is the on-disk dir of the bundled
  /// exiftool, forwarded into the server isolate so its tools use it.
  ///
  /// [spawn] is an optional seam used in tests to replace [Isolate.spawn].
  /// Production callers omit it and get the real implementation.
  // ignore: library_private_types_in_public_api
  McpService({this.exiftoolBundleDir, this.appVersion, _IsolateSpawner? spawn})
    : _spawn = spawn ?? Isolate.spawn;

  /// On-disk dir of the bundled exiftool, or null to use `PATH`.
  final String? exiftoolBundleDir;

  /// Version this app reports over MCP, or null to use the package default.
  final String? appVersion;

  final _IsolateSpawner _spawn;

  /// Whether the server is currently listening.
  bool get running => _port != null;

  /// The bound port once listening, else null.
  int? get port => _port;
  int? _port;

  /// The last error, if startup failed.
  String? get error => _error;
  String? _error;

  Isolate? _isolate;
  ReceivePort? _receive;

  /// The base [start] was last called with, so a lost worker comes back on the
  /// same range rather than the default.
  int _base = 8787;

  /// Automatic restarts since the last successful bind. Bounded so a worker
  /// that dies on every spawn cannot spin.
  int _restarts = 0;
  static const _maxRestarts = 3;

  /// The last error the worker reported, kept so the exit that may follow it
  /// can say what actually went wrong instead of "exited".
  String? _lastWorkerError;

  /// Starts the server, trying ports in [base]..[base]+9 until one binds.
  Future<void> start({int base = 8787}) async {
    if (_isolate != null) return;
    _base = base;
    _error = null;
    _receive = ReceivePort();
    _receive!.listen(_onMessage);
    try {
      _isolate = await _spawn(
        _serverEntry,
        _Config(_receive!.sendPort, base, exiftoolBundleDir, appVersion),
        debugName: 'mcp-server',
        onExit: _receive!.sendPort,
        onError: _receive!.sendPort,
      );
    } on Object catch (e) {
      // Reached when the spawner itself throws (e.g., a process-level failure
      // to create the worker isolate). Exercised in tests via the [spawn] seam.
      _error = '$e';
      notifyListeners();
    }
  }

  /// Stops the server and tears down the isolate.
  Future<void> stop() async {
    // Close the port before the kill: `onExit` fires either way, and a
    // deliberate teardown must not be mistaken for the worker dying.
    _receive?.close();
    _receive = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port = null;
    notifyListeners();
  }

  /// Tears the worker down and brings it back on the last base port, clearing
  /// the automatic-restart budget: asking by hand is a fresh chance.
  Future<void> restart() async {
    await stop();
    _restarts = 0;
    await start(base: _base);
  }

  void _onMessage(Object? message) {
    // `onExit` sends null, `onError` sends [error, stackTrace]. Only the exit
    // proves the worker is gone: an error it survives must not trigger a
    // respawn, or a second server binds the next port alongside the live one
    // and the endpoint becomes ambiguous.
    if (message == null) {
      _onWorkerExited(_lastWorkerError ?? 'MCP server worker exited');
      return;
    }
    if (message is List) {
      _lastWorkerError = 'MCP server worker error: ${message.first}';
      _error = _lastWorkerError;
      notifyListeners();
      return;
    }
    if (message is! Map) return;
    if (message['ready'] is int) {
      _port = message['ready'] as int;
      _error = null;
      _restarts = 0;
      _lastWorkerError = null;
      notifyListeners();
    } else if (message['error'] is String) {
      // The worker reports its own failure and then returns, so an `onExit`
      // follows. Stop listening here so that expected exit cannot overwrite a
      // precise diagnostic ("no free port in 8787..8796") with a generic one,
      // or burn restarts retrying a failure that is deterministic.
      _receive?.close();
      _receive = null;
      _isolate = null;
      _error = message['error'] as String;
      _port = null;
      notifyListeners();
    }
  }

  /// Drops the stale port and brings the worker back, so an LLM reconnecting
  /// hours later finds a socket instead of a port number nothing answers on.
  void _onWorkerExited(String reason) {
    // Fatal isolate errors deliver on both ports; the first call closes the
    // receive port, so this guard swallows the duplicate.
    if (_receive == null) return;
    _receive!.close();
    _receive = null;
    _isolate = null;
    _port = null;
    if (_restarts >= _maxRestarts) {
      _error = '$reason; gave up after $_maxRestarts restarts';
      notifyListeners();
      return;
    }
    _restarts++;
    _error = reason;
    _lastWorkerError = null;
    notifyListeners();
    start(base: _base);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class _Config {
  const _Config(this.send, this.basePort, this.bundleDir, this.appVersion);
  final SendPort send;
  final int basePort;
  final String? bundleDir;
  final String? appVersion;
}

/// Isolate entry: probe exiftool, build the tool catalog, and serve TCP. Tries a
/// small range of ports so a busy port doesn't leave the app without a server.
Future<void> _serverEntry(_Config cfg) async {
  final ProcessRunner runner = cfg.bundleDir == null
      ? const SystemProcessRunner()
      : ExiftoolRunner(
          const SystemProcessRunner(),
          ExiftoolInvocation.resolve(cfg.bundleDir),
        );
  final tools = await ToolkitChecker(runner).check();
  final exiftool =
      cfg.bundleDir != null ||
      tools.any((t) => t.id == 'exiftool' && t.present);
  final server = McpServer(
    tools: buildTools(runner: runner, exiftoolAvailable: exiftool),
    version: cfg.appVersion ?? kMcpDefaultVersion,
  );

  for (var port = cfg.basePort; port < cfg.basePort + 10; port++) {
    try {
      await serveTcp(server, port: port);
      cfg.send.send({'ready': port});
      return; // serveTcp keeps the socket open; the isolate stays alive.
    } on Object {
      continue; // port busy - try the next.
    }
  }
  cfg.send.send({
    'error': 'no free port in ${cfg.basePort}..${cfg.basePort + 9}',
  });
}
