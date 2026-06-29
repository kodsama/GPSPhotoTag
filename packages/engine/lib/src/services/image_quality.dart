import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Fast, relative image-quality scoring for the duplicate-finder's keep rules.
///
/// Every metric here is computed on the small (~160 px) thumbnail the duplicate
/// finder already decodes for the perceptual hash, NOT the full-resolution
/// source. That makes scoring effectively free (the decode is reused) at the
/// cost of absolute precision — which is fine because the scores are only ever
/// compared *within a duplicate group* (the same scene at similar sizes), where
/// the thumbnail is a faithful proxy for relative sharpness/contrast/colour.
///
/// All functions are pure (they read a decoded [img.Image] and return a number),
/// so the whole quality model is unit-testable on tiny synthetic bitmaps.

/// The composite [quality] weights. Sharpness dominates (a crisp frame is the
/// strongest "keep me" signal), with contrast and colourfulness as tie-breakers.
const double _sharpnessWeight = 0.5;
const double _contrastWeight = 0.3;
const double _colorfulnessWeight = 0.2;

/// A single quality component the user can choose to include when deciding what
/// counts as "low quality" in the Shrink stage.
///
/// The four map onto the four stored [ImageQuality] components. The Shrink stage
/// exposes them as toggles and filters on [compositeFrom] over the enabled set.
enum QualityParam {
  /// Sharpness ([ImageQuality.sharpness]) — "Blurriness".
  sharpness,

  /// Contrast ([ImageQuality.contrast]) — "Histogram".
  contrast,

  /// Colourfulness ([ImageQuality.colorfulness]) — "Color".
  color,

  /// Exposure ([ImageQuality.exposure]) — "Exposure".
  exposure,
}

/// The per-component quality scores plus their weighted [composite], all in
/// 0..1. Returned by [qualityScore] and stored on a hashed file.
class ImageQuality {
  /// Creates a quality record.
  const ImageQuality({
    required this.sharpness,
    required this.contrast,
    required this.colorfulness,
    required this.composite,
    this.exposure = 0,
  });

  /// A zero-quality record (used when no thumbnail is available).
  static const zero = ImageQuality(
    sharpness: 0,
    contrast: 0,
    colorfulness: 0,
    composite: 0,
    exposure: 0,
  );

  /// Normalised Laplacian-variance sharpness, 0 (flat/blurry) .. 1 (crisp).
  final double sharpness;

  /// Normalised luma standard deviation, 0 (flat) .. 1 (high contrast).
  final double contrast;

  /// Normalised Hasler–Süsstrunk colourfulness, 0 (grey) .. 1 (vivid).
  final double colorfulness;

  /// Normalised exposure, 0 (crushed/blown/extreme brightness) .. 1
  /// (well-spread mid-toned). See [exposureOf].
  final double exposure;

  /// Weighted blend of sharpness/contrast/colourfulness in 0..1 (see the weight
  /// consts). Intentionally three-component: it is the standard "keep me" score
  /// the duplicate keep-rule uses, and [exposure] is stored separately so that
  /// rule is unchanged.
  final double composite;

  /// The 0..1 value of [param] on this record.
  double component(QualityParam param) => switch (param) {
    QualityParam.sharpness => sharpness,
    QualityParam.contrast => contrast,
    QualityParam.color => colorfulness,
    QualityParam.exposure => exposure,
  };

  /// JSON view of the scores (the four components + the composite).
  Map<String, double> toJson() => {
    'sharpness': sharpness,
    'contrast': contrast,
    'colorfulness': colorfulness,
    'exposure': exposure,
    'composite': composite,
  };
}

/// A 0..1 score over only the [enabled] components of [q]: the unweighted mean
/// of the chosen components. With all four enabled it is a sensible "overall"
/// score; with one enabled it is just that component.
///
/// An empty [enabled] set returns 1.0 so nothing is flagged (every photo scores
/// at the maximum and falls above any threshold), the safe default when the user
/// has turned every parameter off.
double compositeFrom(ImageQuality q, Set<QualityParam> enabled) {
  if (enabled.isEmpty) return 1;
  var sum = 0.0;
  for (final param in enabled) {
    sum += q.component(param);
  }
  return (sum / enabled.length).clamp(0.0, 1.0);
}

/// The grayscale luma plane (row-major, 0..255 as doubles) of [image].
List<double> _lumaPlane(img.Image image) {
  final out = List<double>.filled(image.width * image.height, 0);
  var i = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      out[i++] = img.getLuminance(image.getPixel(x, y)).toDouble();
    }
  }
  return out;
}

/// Normalised sharpness in 0..1: the variance of a 4-neighbour Laplacian over
/// the grayscale [image], squashed so a flat image scores ~0 and an edgy one
/// approaches 1. A degenerate (≤2 px in either axis) image scores 0.
double sharpnessOf(img.Image image) {
  final w = image.width;
  final h = image.height;
  if (w < 3 || h < 3) return 0;
  final luma = _lumaPlane(image);
  var sum = 0.0;
  var sumSq = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = luma[y * w + x];
      // Discrete Laplacian: 4·center − (up + down + left + right).
      final lap =
          4 * c -
          luma[(y - 1) * w + x] -
          luma[(y + 1) * w + x] -
          luma[y * w + x - 1] -
          luma[y * w + x + 1];
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  if (n == 0) return 0;
  final variance = (sumSq / n) - (sum / n) * (sum / n);
  return _squash(variance, 500);
}

/// Normalised contrast in 0..1: the standard deviation of luma over [image],
/// scaled so a flat image scores 0 and a black/white split approaches 1.
double contrastOf(img.Image image) {
  final luma = _lumaPlane(image);
  if (luma.isEmpty) return 0;
  var sum = 0.0;
  for (final v in luma) {
    sum += v;
  }
  final mean = sum / luma.length;
  var sumSq = 0.0;
  for (final v in luma) {
    final d = v - mean;
    sumSq += d * d;
  }
  final std = math.sqrt(sumSq / luma.length);
  // Max possible luma std (a 50/50 black/white split) is 127.5.
  return (std / 127.5).clamp(0.0, 1.0);
}

/// Normalised colourfulness in 0..1 via the Hasler–Süsstrunk metric: the
/// combined spread (std) and bias (mean) of the red-green and yellow-blue
/// opponent channels, scaled into 0..1. A grey image scores 0.
double colorfulnessOf(img.Image image) {
  final n = image.width * image.height;
  if (n == 0) return 0;
  var sumRg = 0.0, sumSqRg = 0.0;
  var sumYb = 0.0, sumSqYb = 0.0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final px = image.getPixel(x, y);
      final r = px.r.toDouble();
      final g = px.g.toDouble();
      final b = px.b.toDouble();
      final rg = r - g;
      final yb = 0.5 * (r + g) - b;
      sumRg += rg;
      sumSqRg += rg * rg;
      sumYb += yb;
      sumSqYb += yb * yb;
    }
  }
  final meanRg = sumRg / n;
  final meanYb = sumYb / n;
  final stdRg = math.sqrt(math.max(0, (sumSqRg / n) - meanRg * meanRg));
  final stdYb = math.sqrt(math.max(0, (sumSqYb / n) - meanYb * meanYb));
  final stdRoot = math.sqrt(stdRg * stdRg + stdYb * stdYb);
  final meanRoot = math.sqrt(meanRg * meanRg + meanYb * meanYb);
  final metric = stdRoot + 0.3 * meanRoot;
  // Empirically a vivid image lands near 150 on this metric; scale to 0..1.
  return (metric / 150).clamp(0.0, 1.0);
}

/// Normalised exposure in 0..1: higher means better-exposed. Penalises a photo
/// for clipped tones (a large fraction of pixels crushed near black or blown
/// near white) and for an extreme mean brightness (too dark or too bright),
/// scoring a mid-grey, well-spread image high. An empty image scores 0.
///
/// Reads the [image] luma plane, counts pixels within [_clipThreshold] of 0 or
/// 255 as clipped, and combines that clip penalty with a brightness penalty that
/// peaks (1.0, no penalty) at mid-grey (127.5) and falls to 0 at pure black or
/// white.
double exposureOf(img.Image image) {
  final luma = _lumaPlane(image);
  if (luma.isEmpty) return 0;
  var clipped = 0;
  var sum = 0.0;
  for (final v in luma) {
    if (v <= _clipThreshold || v >= 255 - _clipThreshold) clipped++;
    sum += v;
  }
  final clipFraction = clipped / luma.length;
  // A triangular brightness term: 1 at mid-grey, 0 at the extremes.
  final mean = sum / luma.length;
  final brightness = (1 - (mean - 127.5).abs() / 127.5).clamp(0.0, 1.0);
  // Either failing badly should drag the score down, so multiply the (inverted)
  // clip term by the brightness term.
  return ((1 - clipFraction) * brightness).clamp(0.0, 1.0);
}

/// The composite [ImageQuality] of [image]: each component plus the weighted
/// 0..1 blend (sharpness 0.5, contrast 0.3, colourfulness 0.2). [exposure] is
/// scored and stored too, but is NOT part of [composite] (which stays the
/// three-component duplicate keep-rule score).
ImageQuality qualityScore(img.Image image) {
  final sharpness = sharpnessOf(image);
  final contrast = contrastOf(image);
  final colorfulness = colorfulnessOf(image);
  final exposure = exposureOf(image);
  final composite =
      _sharpnessWeight * sharpness +
      _contrastWeight * contrast +
      _colorfulnessWeight * colorfulness;
  return ImageQuality(
    sharpness: sharpness,
    contrast: contrast,
    colorfulness: colorfulness,
    exposure: exposure,
    composite: composite.clamp(0.0, 1.0),
  );
}

/// Pixels within this many luma levels of 0 or 255 count as clipped
/// shadows/highlights for [exposureOf].
const double _clipThreshold = 4;

/// Maps an unbounded non-negative [value] into 0..1 via `value/(value+scale)`,
/// a smooth saturating curve where [scale] is the value that maps to 0.5.
double _squash(double value, double scale) {
  if (value <= 0) return 0;
  return value / (value + scale);
}
