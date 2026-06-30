@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

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

  // AC: T-02 — error path when Isolate.spawn itself throws.
  // Exercising this required the IsolateSpawner seam; before the seam existed,
  // the catch block was guarded by coverage:ignore-start and had no test because
  // Isolate.spawn cannot be made to throw under `flutter test` without injection.
  test('T-02_happy: spawner throws → error set, listener notified, not running',
      () async {
    var notified = false;
    final service = McpService(
      spawn: (_, _, {debugName}) => throw StateError('boom'),
    );
    addTearDown(service.dispose);

    service.addListener(() => notified = true);

    await service.start(base: 18900);

    expect(
      service.error,
      contains('boom'),
      reason: 'error field must capture the thrown StateError',
    );
    expect(notified, isTrue, reason: 'ChangeNotifier must fire when spawn fails');
    expect(service.running, isFalse, reason: 'service must not be running after spawn failure');
  });
}
