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
});

/// Runs the MCP server on a localhost TCP socket in a dedicated worker isolate,
/// started automatically when the app launches — so an LLM always has a live
/// endpoint while Stunda is open, without ever touching the UI isolate.
class McpService extends ChangeNotifier {
  /// Creates the service. [exiftoolBundleDir] is the on-disk dir of the bundled
  /// exiftool, forwarded into the server isolate so its tools use it.
  ///
  /// [spawn] is an optional seam used in tests to replace [Isolate.spawn].
  /// Production callers omit it and get the real implementation.
  // ignore: library_private_types_in_public_api
  McpService({this.exiftoolBundleDir, _IsolateSpawner? spawn})
    : _spawn = spawn ?? Isolate.spawn;

  /// On-disk dir of the bundled exiftool, or null to use `PATH`.
  final String? exiftoolBundleDir;

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

  /// Starts the server, trying ports in [base]..[base]+9 until one binds.
  Future<void> start({int base = 8787}) async {
    if (_isolate != null) return;
    _error = null;
    _receive = ReceivePort();
    _receive!.listen(_onMessage);
    try {
      _isolate = await _spawn(
        _serverEntry,
        _Config(_receive!.sendPort, base, exiftoolBundleDir),
        debugName: 'mcp-server',
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
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
    _port = null;
    notifyListeners();
  }

  void _onMessage(Object? message) {
    if (message is! Map) return;
    if (message['ready'] is int) {
      _port = message['ready'] as int;
      _error = null;
      notifyListeners();
    } else if (message['error'] is String) {
      _error = message['error'] as String;
      _port = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class _Config {
  const _Config(this.send, this.basePort, this.bundleDir);
  final SendPort send;
  final int basePort;
  final String? bundleDir;
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
  );

  for (var port = cfg.basePort; port < cfg.basePort + 10; port++) {
    try {
      await serveTcp(server, port: port);
      cfg.send.send({'ready': port});
      return; // serveTcp keeps the socket open; the isolate stays alive.
    } on Object {
      continue; // port busy — try the next.
    }
  }
  cfg.send.send({
    'error': 'no free port in ${cfg.basePort}..${cfg.basePort + 9}',
  });
}
