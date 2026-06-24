@Timeout(Duration(seconds: 30))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_gui/src/engine/mcp_service.dart';

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
}
