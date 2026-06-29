import 'package:image/image.dart' as img;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('preprocessToNchwFloat', () {
    test('produces a 3 * side * side float buffer in NCHW order', () {
      final image = img.Image(width: 10, height: 10);
      final out = preprocessToNchwFloat(image, side: 8);
      expect(out.length, 3 * 8 * 8);
    });

    test('uses the default side when none is given', () {
      final image = img.Image(width: 5, height: 5);
      final out = preprocessToNchwFloat(image);
      expect(out.length, 3 * kEmbedderInputSide * kEmbedderInputSide);
    });

    test('skips the resize when the image is already the model size', () {
      final image = img.Image(width: 4, height: 4);
      final out = preprocessToNchwFloat(image, side: 4);
      expect(out.length, 3 * 4 * 4);
    });

    test('ImageNet-normalizes each channel (black pixel → -mean/std)', () {
      final black = img.Image(width: 2, height: 2);
      img.fill(black, color: img.ColorRgb8(0, 0, 0));
      final out = preprocessToNchwFloat(black, side: 2);
      const plane = 2 * 2;
      // R channel: (0 - 0.485) / 0.229
      expect(out[0], closeTo((-kImageNetMean[0]) / kImageNetStd[0], 1e-5));
      // G channel starts at `plane`.
      expect(out[plane], closeTo((-kImageNetMean[1]) / kImageNetStd[1], 1e-5));
      // B channel starts at `2 * plane`.
      expect(
        out[2 * plane],
        closeTo((-kImageNetMean[2]) / kImageNetStd[2], 1e-5),
      );
    });

    test('a white pixel normalizes to (1 - mean) / std per channel', () {
      final white = img.Image(width: 1, height: 1);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      final out = preprocessToNchwFloat(white, side: 1);
      expect(out[0], closeTo((1 - kImageNetMean[0]) / kImageNetStd[0], 1e-5));
      expect(out[1], closeTo((1 - kImageNetMean[1]) / kImageNetStd[1], 1e-5));
      expect(out[2], closeTo((1 - kImageNetMean[2]) / kImageNetStd[2], 1e-5));
    });
  });
}
