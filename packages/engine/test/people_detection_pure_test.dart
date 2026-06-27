import 'package:image/image.dart' as img;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('isPersonOrAnimal (COCO mapping)', () {
    test('person id 1 counts', () {
      expect(isPersonOrAnimal(kCocoPersonId), isTrue);
      expect(kCocoPersonId, 1);
    });

    test('every animal id counts', () {
      for (final id in kCocoAnimalIds) {
        expect(isPersonOrAnimal(id), isTrue, reason: 'animal $id');
      }
      // Spot-check the documented set: dog=18, cat=17, bird=16, giraffe=25.
      expect(kCocoAnimalIds, containsAll(<int>{16, 17, 18, 25}));
    });

    test('non-person non-animal ids do not count', () {
      for (final id in const [0, 2, 3, 15, 26, 80]) {
        expect(isPersonOrAnimal(id), isFalse, reason: 'id $id');
      }
    });
  });

  group('peopleScoreFromDetections', () {
    test('returns the max qualifying score above threshold', () {
      final score = peopleScoreFromDetections(
        [0.9, 0.4, 0.7],
        [1, 1, 18], // person, person, dog
        3,
      );
      // 0.4 is below threshold; max of the two qualifying (0.9, 0.7) is 0.9.
      expect(score, 0.9);
    });

    test('ignores classes that are neither person nor animal', () {
      final score = peopleScoreFromDetections([0.95, 0.6], [3, 18], 2);
      // class 3 (not person/animal) is skipped; dog at 0.6 wins.
      expect(score, closeTo(0.6, 1e-9));
    });

    test('returns 0 when nothing clears the threshold', () {
      expect(peopleScoreFromDetections([0.2, 0.49], [1, 18], 2), 0);
    });

    test('returns 0 when no qualifying class', () {
      expect(peopleScoreFromDetections([0.99, 0.99], [3, 4], 2), 0);
    });

    test('honours a custom threshold', () {
      expect(peopleScoreFromDetections([0.3], [1], 1, threshold: 0.2), 0.3);
      expect(peopleScoreFromDetections([0.3], [1], 1, threshold: 0.4), 0);
    });

    test('clamps numDetections to the shortest array (no overrun)', () {
      // Claims 99 detections but only 1 entry exists.
      expect(peopleScoreFromDetections([0.9], [1], 99), 0.9);
      // classes shorter than scores: limit is the classes length.
      expect(peopleScoreFromDetections([0.9, 0.9], [1], 2), 0.9);
    });

    test('a negative count reads nothing', () {
      expect(peopleScoreFromDetections([0.9], [1], -5), 0);
    });

    test('reads only the first numDetections entries', () {
      // The valid window is 1; the high-score person at index 1 is padding.
      expect(peopleScoreFromDetections([0.0, 0.95], [1, 1], 1), 0);
    });
  });

  group('preprocessToNhwcUint8', () {
    test('produces side*side*3 bytes in RGB order', () {
      final image = img.Image(width: 2, height: 2);
      image.setPixelRgb(0, 0, 10, 20, 30);
      image.setPixelRgb(1, 0, 40, 50, 60);
      image.setPixelRgb(0, 1, 70, 80, 90);
      image.setPixelRgb(1, 1, 100, 110, 120);
      final out = preprocessToNhwcUint8(image, side: 2);
      expect(out, hasLength(2 * 2 * 3));
      // First pixel (0,0) is R,G,B = 10,20,30.
      expect(out.sublist(0, 3), [10, 20, 30]);
      // Pixel (1,0) follows in row-major order.
      expect(out.sublist(3, 6), [40, 50, 60]);
    });

    test('resizes to the requested side', () {
      final image = img.Image(width: 8, height: 4);
      final out = preprocessToNhwcUint8(image, side: 5);
      expect(out, hasLength(5 * 5 * 3));
    });

    test('default side is the model input (300)', () {
      expect(kDetectorInputSide, 300);
      final out = preprocessToNhwcUint8(img.Image(width: 10, height: 10));
      expect(out, hasLength(300 * 300 * 3));
    });
  });

  group('resolveOnnxBundle / ortLibraryFileName', () {
    test('per-platform library names', () {
      expect(
        ortLibraryFileName(operatingSystem: 'macos'),
        'libonnxruntime.dylib',
      );
      expect(ortLibraryFileName(operatingSystem: 'linux'), 'libonnxruntime.so');
      expect(ortLibraryFileName(operatingSystem: 'windows'), 'onnxruntime.dll');
      expect(ortLibraryFileName(operatingSystem: 'fuchsia'), isNull);
    });

    test('null bundle dir resolves to null', () {
      expect(resolveOnnxBundle(null), isNull);
    });

    test('unsupported platform resolves to null', () {
      expect(resolveOnnxBundle('/x', operatingSystem: 'fuchsia'), isNull);
    });

    test('builds lib + model paths under the bundle dir', () {
      final bundle = resolveOnnxBundle('/bundle', operatingSystem: 'linux')!;
      expect(bundle.libraryPath, '/bundle/libonnxruntime.so');
      expect(bundle.modelPath, '/bundle/$kOnnxModelFileName');
    });

    test('isComplete is false when files are absent', () {
      final bundle = resolveOnnxBundle(
        '/definitely/not/here',
        operatingSystem: 'macos',
      )!;
      expect(bundle.isComplete, isFalse);
    });
  });

  group('OrtPeopleDetector (no bundle → unavailable, total)', () {
    test('null bundle dir → unavailable, scores null', () async {
      final d = OrtPeopleDetector.fromBundleDir(null);
      expect(d.isAvailable, isFalse);
      expect(await d.scoreDecoded(img.Image(width: 4, height: 4)), isNull);
      expect(
        await d.scoreImage(img.encodeJpg(img.Image(width: 4, height: 4))),
        isNull,
      );
      d.close(); // idempotent / safe when unavailable
      d.close();
    });

    test('missing files → unavailable', () {
      final d = OrtPeopleDetector.fromBundleDir(
        '/no/such/bundle',
        operatingSystem: 'macos',
      );
      expect(d.isAvailable, isFalse);
    });
  });
}
