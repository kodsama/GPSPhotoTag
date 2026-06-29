import 'dart:typed_data';

import 'package:image/image.dart' as img;
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

    test('scoreDecoded is also always null', () async {
      expect(
        await detector.scoreDecoded(img.Image(width: 4, height: 4)),
        isNull,
      );
    });
  });
}
