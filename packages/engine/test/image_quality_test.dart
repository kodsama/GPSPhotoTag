import 'package:image/image.dart' as img;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A flat grey image: no edges, no contrast, no colour.
img.Image _flat(int w, int h, [int v = 128]) =>
    img.Image(width: w, height: h)..clear(img.ColorRgb8(v, v, v));

/// A tight vertical-stripe pattern (2-px period) so neighbouring pixels differ
/// strongly — high Laplacian variance and high luma spread.
img.Image _stripes(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = ((x ~/ 2) % 2 == 0) ? 230 : 20;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// A mid-grey image with a small spread of values around 128 so it isn't
/// clipped and sits near the ideal exposure (no crushed/blown pixels).
img.Image _midToned(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = 110 + ((x + y) % 40);
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// A vivid colour gradient: large opponent-channel spread, low luma edges.
img.Image _colorful(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(
        x,
        y,
        (x * 8) % 256,
        (y * 8) % 256,
        ((x + y) * 4) % 256,
      );
    }
  }
  return image;
}

void main() {
  group('sharpnessOf', () {
    test('a flat image has zero sharpness', () {
      expect(sharpnessOf(_flat(32, 32)), 0);
    });

    test('an edgy image scores higher than a flat one', () {
      expect(
        sharpnessOf(_stripes(32, 32)),
        greaterThan(sharpnessOf(_flat(32, 32))),
      );
    });

    test('stays within 0..1', () {
      final s = sharpnessOf(_stripes(32, 32));
      expect(s, inInclusiveRange(0, 1));
    });

    test('a degenerate (tiny) image scores zero (no interior pixels)', () {
      expect(sharpnessOf(_stripes(2, 2)), 0);
      expect(sharpnessOf(_flat(1, 8)), 0);
    });
  });

  group('contrastOf', () {
    test('a flat image has zero contrast', () {
      expect(contrastOf(_flat(16, 16)), 0);
    });

    test('a black/white split scores high contrast', () {
      expect(contrastOf(_stripes(16, 16)), greaterThan(0.5));
    });

    test('an empty image is zero (never throws)', () {
      expect(contrastOf(img.Image(width: 0, height: 0)), 0);
    });
  });

  group('colorfulnessOf', () {
    test('a grey image has zero colourfulness', () {
      expect(colorfulnessOf(_flat(16, 16)), 0);
    });

    test('a vivid image scores higher than a grey one', () {
      expect(
        colorfulnessOf(_colorful(32, 32)),
        greaterThan(colorfulnessOf(_flat(32, 32))),
      );
    });

    test('an empty image is zero (never throws)', () {
      expect(colorfulnessOf(img.Image(width: 0, height: 0)), 0);
    });
  });

  group('qualityScore', () {
    test('a flat grey image scores ~0 across the board', () {
      final q = qualityScore(_flat(32, 32));
      expect(q.sharpness, 0);
      expect(q.contrast, 0);
      expect(q.colorfulness, 0);
      expect(q.composite, 0);
    });

    test('an edgy striped image scores a high composite', () {
      final q = qualityScore(_stripes(32, 32));
      expect(q.sharpness, greaterThan(0.5));
      expect(q.contrast, greaterThan(0.5));
      expect(q.composite, greaterThan(0.5));
    });

    test('monotonic: a sharper, busier image beats a flat one', () {
      expect(
        qualityScore(_stripes(32, 32)).composite,
        greaterThan(qualityScore(_flat(32, 32)).composite),
      );
    });

    test('composite stays within 0..1 and toJson exposes the four scores', () {
      final q = qualityScore(_colorful(32, 32));
      expect(q.composite, inInclusiveRange(0, 1));
      expect(
        q.toJson().keys,
        containsAll(['sharpness', 'contrast', 'colorfulness', 'composite']),
      );
    });

    test('ImageQuality.zero is all zeros', () {
      expect(ImageQuality.zero.composite, 0);
      expect(ImageQuality.zero.sharpness, 0);
      expect(ImageQuality.zero.contrast, 0);
      expect(ImageQuality.zero.colorfulness, 0);
      expect(ImageQuality.zero.exposure, 0);
    });

    test(
      'scores and stores an exposure component (mid-grey is well-exposed)',
      () {
        final q = qualityScore(_midToned(32, 32));
        expect(q.exposure, greaterThan(0.8));
        expect(q.toJson().keys, contains('exposure'));
      },
    );

    test('composite stays a three-component score (excludes exposure)', () {
      // A perfectly mid-grey flat image: blurry/flat/grey but well-exposed.
      final q = qualityScore(_flat(32, 32));
      expect(q.exposure, greaterThan(0.9));
      // Composite is sharpness/contrast/colour only, so it stays 0.
      expect(q.composite, 0);
    });
  });

  group('exposureOf', () {
    test('a well-spread mid-grey image scores high', () {
      expect(exposureOf(_midToned(32, 32)), greaterThan(0.8));
    });

    test('an all-black image scores ~0 (crushed shadows + too dark)', () {
      expect(exposureOf(_flat(16, 16, 0)), lessThan(0.05));
    });

    test('an all-white image scores ~0 (blown highlights + too bright)', () {
      expect(exposureOf(_flat(16, 16, 255)), lessThan(0.05));
    });

    test('a heavily-clipped split scores below a clean mid-grey', () {
      // Half pure black, half pure white: every pixel is clipped.
      final image = img.Image(width: 16, height: 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final v = x < 8 ? 0 : 255;
          image.setPixelRgb(x, y, v, v, v);
        }
      }
      expect(exposureOf(image), lessThan(exposureOf(_midToned(16, 16))));
    });

    test('an empty image is zero (never throws)', () {
      expect(exposureOf(img.Image(width: 0, height: 0)), 0);
    });

    test('stays within 0..1', () {
      expect(exposureOf(_midToned(16, 16)), inInclusiveRange(0, 1));
    });
  });

  group('compositeFrom', () {
    const q = ImageQuality(
      sharpness: 0.2,
      contrast: 0.4,
      colorfulness: 0.6,
      exposure: 0.8,
      composite: 0,
    );

    test('one enabled param returns that component', () {
      expect(compositeFrom(q, {QualityParam.sharpness}), 0.2);
      expect(compositeFrom(q, {QualityParam.contrast}), 0.4);
      expect(compositeFrom(q, {QualityParam.color}), 0.6);
      expect(compositeFrom(q, {QualityParam.exposure}), 0.8);
    });

    test('a subset is the mean of the chosen components', () {
      expect(
        compositeFrom(q, {QualityParam.sharpness, QualityParam.contrast}),
        closeTo(0.3, 1e-9),
      );
      expect(
        compositeFrom(q, {
          QualityParam.contrast,
          QualityParam.color,
          QualityParam.exposure,
        }),
        closeTo(0.6, 1e-9),
      );
    });

    test('all four enabled is the mean of all four', () {
      expect(compositeFrom(q, QualityParam.values.toSet()), closeTo(0.5, 1e-9));
    });

    test('the empty set returns 1.0 (nothing is flagged)', () {
      expect(compositeFrom(q, const {}), 1);
    });

    test('component reads each stored score by param', () {
      expect(q.component(QualityParam.sharpness), 0.2);
      expect(q.component(QualityParam.contrast), 0.4);
      expect(q.component(QualityParam.color), 0.6);
      expect(q.component(QualityParam.exposure), 0.8);
    });
  });
}
