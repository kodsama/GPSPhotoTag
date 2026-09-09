@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/engine/mcp_service.dart';

void main() {
  test('start binds a localhost port, then stop tears it down', () async {
    final service = McpService();
    addTearDown(service.stop);

    expect(service.running, isFalse);
    expect(service.port, isNull);

    // Use a high base port to avoid colliding with a real running app.
    await service.start(base: 18800);

    // The worker isolate binds asynchronously; poll until it reports ready.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(service.error, isNull, reason: 'startup error: ${service.error}');
    expect(service.running, isTrue);
    expect(service.port, isNotNull);
    expect(service.port, inInclusiveRange(18800, 18809));

    await service.stop();
    expect(service.running, isFalse);
    expect(service.port, isNull);
  });

  test('start is idempotent while already starting', () async {
    final service = McpService();
    addTearDown(service.stop);

    await service.start(base: 18820);
    // A second start before the first reports ready is a no-op (no throw).
    await service.start(base: 18820);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);
    await service.stop();
  });

  test('walks past a port another app already holds', () async {
    // The real-world case: an unrelated app already holds the base port, so the
    // server must land on the next one rather than failing. Without the walk
    // this binds nothing and `running` stays false.
    const base = 18930;
    final squatter = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      base,
    );
    addTearDown(squatter.close);

    final service = McpService();
    addTearDown(service.stop);
    await service.start(base: base);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(service.error, isNull, reason: 'startup error: ${service.error}');
    expect(service.running, isTrue);
    expect(service.port, base + 1, reason: 'must skip the occupied base port');
  });

  test('reports an error when every port in the range is taken', () async {
    // Occupy the whole 10-port range the worker probes, so it can bind none and
    // reports back the "no free port" error.
    const base = 18840;
    final blockers = <ServerSocket>[];
    for (var p = base; p < base + 10; p++) {
      blockers.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, p));
    }
    addTearDown(() async {
      for (final s in blockers) {
        await s.close();
      }
    });

    final service = McpService();
    addTearDown(service.stop);
    await service.start(base: base);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (service.error == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(service.running, isFalse);
    expect(service.port, isNull);
    expect(service.error, contains('no free port'));
  });

  test('a bundled exiftool dir routes the server through the bundle', () async {
    // With a bundleDir set, the server isolate builds an ExiftoolRunner around
    // the bundled invocation (the `cfg.bundleDir != null` arm) and treats
    // exiftool as available without probing PATH. The server still binds.
    final service = McpService(exiftoolBundleDir: '/some/bundle/dir');
    addTearDown(service.stop);
    await service.start(base: 18880);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.error, isNull, reason: 'startup error: ${service.error}');
    expect(service.running, isTrue);
    expect(service.port, inInclusiveRange(18880, 18889));
    await service.stop();
  });

  test('dispose stops the running server', () async {
    final service = McpService();
    await service.start(base: 18860);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);

    service.dispose(); // tears down the isolate via stop()
    expect(service.running, isFalse);
    expect(service.port, isNull);
  });

  // AC: T-02 - error path when Isolate.spawn itself throws.
  // Exercising this required the IsolateSpawner seam; before the seam existed,
  // the catch block was guarded by coverage:ignore-start and had no test because
  // Isolate.spawn cannot be made to throw under `flutter test` without injection.
  test(
    'T-02_happy: spawner throws → error set, listener notified, not running',
    () async {
      var notified = false;
      final service = McpService(
        spawn: (_, _, {debugName, onExit, onError}) => throw StateError('boom'),
      );
      addTearDown(service.dispose);

      service.addListener(() => notified = true);

      await service.start(base: 18900);

      expect(
        service.error,
        contains('boom'),
        reason: 'error field must capture the thrown StateError',
      );
      expect(
        notified,
        isTrue,
        reason: 'ChangeNotifier must fire when spawn fails',
      );
      expect(
        service.running,
        isFalse,
        reason: 'service must not be running after spawn failure',
      );
    },
  );

  test('the port it reports actually answers a request', () async {
    // `running` and `port` only echo the isolate's ready message. A socket
    // that died with the isolate still leaves both set, so the only honest
    // check is a real client connection.
    final service = McpService();
    addTearDown(service.stop);
    await service.start(base: 18950);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      service.port!,
    );
    addTearDown(socket.close);
    socket.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'liveness', 'version': '1'},
        },
      }),
    );
    await socket.flush();

    final reply = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    expect(jsonDecode(reply), containsPair('id', 1));
  });

  test('a worker that dies is noticed and the server comes back', () async {
    // The bug this pins: the app reported `running on :8788` for hours while
    // the process held no socket at all. Nothing watched the worker, so the
    // last `ready` port stayed on display after the isolate was gone.
    //
    // The spawner seam forwards the real entry and config untouched, so a real
    // server binds; capturing the Isolate is what lets the test kill it the
    // way the worker went away in the wild.
    Isolate? worker;
    final service = McpService(
      spawn: (entry, message, {debugName, onExit, onError}) async {
        worker = await Isolate.spawn(
          entry,
          message,
          debugName: debugName,
          onExit: onExit,
          onError: onError,
        );
        return worker!;
      },
    );
    addTearDown(service.stop);
    await service.start(base: 19200);

    var deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue, reason: 'server never came up');
    expect(
      await _answers(service.port!),
      isTrue,
      reason: 'socket dead at once',
    );

    worker!.kill(priority: Isolate.immediate);

    // A live port again is the only proof that matters: before the fix the
    // status stayed green on a port nothing was listening on.
    deadline = DateTime.now().add(const Duration(seconds: 20));
    var back = false;
    while (!back && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      back = service.running && await _answers(service.port!);
    }
    expect(
      back,
      isTrue,
      reason:
          'worker death left a stale port: ${service.port} / ${service.error}',
    );
  });

  test('restart brings the server back on a live socket', () async {
    final service = McpService();
    addTearDown(service.stop);
    await service.start(base: 19500);

    var deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);

    await service.restart();
    deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);
    expect(await _answers(service.port!), isTrue);
  });

  test('an error the worker survives does not spawn a second server', () async {
    // The rough edge this pins: the process was seen holding two listeners at
    // once, one of them silent. `onError` only says an error was reported, and
    // if the isolate lives through it a respawn binds the next port alongside
    // the still-serving one, leaving the endpoint ambiguous. Only `onExit`
    // proves the worker is gone.
    SendPort? errorPort;
    final service = McpService(
      spawn: (entry, message, {debugName, onExit, onError}) {
        errorPort = onError;
        return Isolate.spawn(
          entry,
          message,
          debugName: debugName,
          onExit: onExit,
          onError: onError,
        );
      },
    );
    addTearDown(service.stop);
    await service.start(base: 19600);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!service.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(service.running, isTrue);
    final bound = service.port!;

    // Report an error the way a live isolate would, without killing it.
    errorPort!.send(<String>['synthetic failure', 'stack']);
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      service.port,
      bound,
      reason: 'a survivable error must not move the endpoint',
    );
    expect(service.error, contains('synthetic failure'));
    // Poll rather than asking once: a single handshake under load can time out
    // and read as a dead server when the worker is simply busy.
    var serving = false;
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (!serving && DateTime.now().isBefore(until)) {
      serving = await _answers(bound);
    }
    expect(
      serving,
      isTrue,
      reason: 'the original worker is still the one serving',
    );
    // Nothing may have bound the next port in the range.
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        bound + 1,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
      reason: 'a duplicate worker would be listening here',
    );
  });

  test('gives up loudly when the worker cannot stay alive', () async {
    // A worker that dies on every spawn must not be retried forever.
    final service = McpService(
      spawn: (entry, message, {debugName, onExit, onError}) =>
          Isolate.spawn(_diesAtOnce, null, onExit: onExit, onError: onError),
    );
    addTearDown(service.stop);
    await service.start(base: 19300);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while ((service.error == null || !service.error!.contains('gave up')) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(service.running, isFalse);
    expect(service.error, contains('gave up'));
  });
}

/// A worker that returns immediately, so its isolate exits without ever
/// binding. Top-level because [Isolate.spawn] cannot take a closure.
void _diesAtOnce(void _) {}

/// True when [port] completes an MCP `initialize` handshake.
Future<bool> _answers(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'liveness', 'version': '1'},
        },
      }),
    );
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 3));
    socket.destroy();
    return (jsonDecode(reply) as Map)['result'] != null;
  } on Object {
    return false;
  }
}
