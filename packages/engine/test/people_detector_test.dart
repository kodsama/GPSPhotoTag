import 'dart:typed_data';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('NoopPeopleDetector', () {
    const detector = NoopPeopleDetector();

    test('reports itself unavailable', () {
      expect(detector.isAvailable, isFalse);
    });

    test('scores nothing (always null), even on real-looking bytes', () async {
      expect(await detector.scoreImage(Uint8List.fromList([1, 2, 3])), isNull);
      expect(await detector.scoreImage(Uint8List(0)), isNull);
    });
  });
}
