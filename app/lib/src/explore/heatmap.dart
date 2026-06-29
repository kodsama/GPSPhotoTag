import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'explore_model.dart';

/// Per-photo influence radius, in SCREEN pixels — a constant, never scaled by
/// zoom or photo count. This is the distance at which a splat's gaussian
/// falloff has decayed to essentially nothing. A larger radius blends nearby
/// photos into a smoother field. Heat comes from how many splats OVERLAP within
/// this radius, not from inflating it (every splat is the same size).
const double kHeatRadius = 48;

/// Per-photo peak alpha (0..1) deposited at a splat's exact centre, before
/// accumulation. Deliberately low so a single isolated photo is only a faint
/// glow; density — and thus heat — builds up only where many splats overlap and
/// their alphas sum (via [BlendMode.plus]).
const double kHeatPointAlpha = 0.18;

/// Overall opacity (0..1) of the entire composited heat overlay, including the
/// hot red cores, so the map (streets, labels, water) always reads through it —
/// like a reference heatmap.js / leaflet.heat layer. Tune this single knob to
/// make the heat more or less translucent.
const double kHeatLayerOpacity = 0.6;

/// Number of radial gradient colour stops used to approximate the gaussian
/// falloff of one splat. More stops = smoother curve; this is plenty for a
/// soft, blended look.
const int _kGaussianStops = 8;

/// One heat splat to paint: a soft gaussian blob centred at [offset]
/// contributing [weight] (0..1) of peak density at its core, fading smoothly to
/// nothing by [kHeatRadius].
@immutable
class HeatBlob {
  /// Creates a splat at [offset] contributing [weight] (0..1) of peak density.
  const HeatBlob({required this.offset, required this.weight});

  /// Splat centre in screen pixels.
  final Offset offset;

  /// Peak density contribution at the centre, in 0..1.
  final double weight;

  @override
  bool operator ==(Object other) =>
      other is HeatBlob && other.offset == offset && other.weight == weight;

  @override
  int get hashCode => Object.hash(offset, weight);
}

/// Computes the heat splats to paint given each photo's projected screen
/// [offsets] and the viewport [size].
///
/// Pure (no widgets, no map camera) so the projection→cull math is unit
/// testable: input is the already-projected screen offsets — ONE PER PHOTO, at
/// full coordinate precision (the field is built from individual photos, never
/// pre-grouped points) — plus the viewport [size]; output is the splat list.
/// Each splat carries the same low [kHeatPointAlpha] peak weight, so a city's
/// many photos blend into a smooth field and a lone photo stays faint; heat
/// builds purely from OVERLAP. Splats whose influence can't reach the viewport
/// (centre further than [radius] outside it) are dropped.
List<HeatBlob> computeHeatBlobs({
  required List<Offset> offsets,
  required Size size,
  double radius = kHeatRadius,
  double pointAlpha = kHeatPointAlpha,
}) {
  if (offsets.isEmpty) return const [];

  final blobs = <HeatBlob>[];
  for (final o in offsets) {
    // Cull splats whose influence can't reach the viewport.
    if (o.dx < -radius ||
        o.dy < -radius ||
        o.dx > size.width + radius ||
        o.dy > size.height + radius) {
      continue;
    }
    blobs.add(HeatBlob(offset: o, weight: pointAlpha));
  }
  return blobs;
}

/// The normalized gaussian falloff alpha at fractional distance [t] (0..1) from
/// a splat's centre to its [kHeatRadius] edge.
///
/// Returns `exp(-(t/σ)²/2)` with σ tuned so the blob has a soft, rounded core
/// and is nearly zero at the edge (t = 1) — NOT a near-flat plateau that cuts
/// off abruptly. Pure, so the falloff shape is unit testable: 1.0 at the centre,
/// monotonically decreasing, and small (< ~0.05) at the rim.
double gaussianFalloff(double t) {
  // σ ≈ 0.38 puts the edge (t=1) at exp(-3.46) ≈ 0.031 — a clean soft fade.
  const sigma = 0.38;
  final x = t.clamp(0.0, 1.0) / sigma;
  return math.exp(-(x * x) / 2);
}

/// Builds the 256-entry intensity→RGBA palette lookup table used to colorize
/// the accumulated density field, returned as a flat `Uint8List` of length
/// 256×4 (`[r,g,b,a, r,g,b,a, …]`, straight/unpremultiplied).
///
/// Index `i` (0..255) is accumulated density `i/255`. The ramp matches a classic
/// heatmap.js / leaflet.heat look but with a LONG transparent/cool tail: the low
/// end stays fully (then barely) transparent so sparse areas reveal the map
/// under both light and dark tiles, ramping blue→cyan→green→yellow→red only as
/// many splats overlap and density climbs — never an abrupt jump straight to
/// opaque red. Pure, so the key stops and the transparent floor are unit
/// testable.
Uint8List buildHeatPalette() {
  // (stop in 0..1, r, g, b, alpha 0..255). A long transparent tail keeps sparse
  // density see-through; alpha and warmth ramp up only as density accumulates.
  const stops = <(double, int, int, int, int)>[
    (0.00, 0x00, 0x00, 0x00, 0), // fully transparent
    (0.20, 0x20, 0x40, 0xEE, 0), // still transparent (long cool tail)
    (0.35, 0x20, 0x60, 0xEE, 70), // blue, just becoming visible
    (0.50, 0x20, 0xC0, 0xEE, 130), // cyan
    (0.65, 0x20, 0xEE, 0x50, 175), // green
    (0.82, 0xEE, 0xEE, 0x20, 215), // yellow
    (1.00, 0xEE, 0x20, 0x20, 255), // hot red core
  ];

  final lut = Uint8List(256 * 4);
  for (var i = 0; i < 256; i++) {
    final t = i / 255.0;
    // Find the bracketing stops for t.
    var lo = stops.first;
    var hi = stops.last;
    for (var s = 0; s < stops.length - 1; s++) {
      if (t >= stops[s].$1 && t <= stops[s + 1].$1) {
        lo = stops[s];
        hi = stops[s + 1];
        break;
      }
    }
    final span = hi.$1 - lo.$1;
    final f = span <= 0 ? 0.0 : (t - lo.$1) / span;
    final r = _lerpByte(lo.$2, hi.$2, f);
    final g = _lerpByte(lo.$3, hi.$3, f);
    final b = _lerpByte(lo.$4, hi.$4, f);
    final a = _lerpByte(lo.$5, hi.$5, f);
    final base = i * 4;
    lut[base] = r;
    lut[base + 1] = g;
    lut[base + 2] = b;
    lut[base + 3] = a;
  }
  return lut;
}

int _lerpByte(int a, int b, double f) =>
    (a + (b - a) * f).round().clamp(0, 255);

/// Looks up the RGBA bytes for [intensity] (0..1) in a [palette] built by
/// [buildHeatPalette], as a 4-int `(r, g, b, a)` record. Pure helper exposing
/// the LUT for both the per-pixel colorize pass and unit tests.
(int, int, int, int) colorizeIntensity(Uint8List palette, double intensity) {
  final i = (intensity.clamp(0.0, 1.0) * 255).round();
  final base = i * 4;
  return (
    palette[base],
    palette[base + 1],
    palette[base + 2],
    palette[base + 3],
  );
}

/// A flutter_map layer drawing a density heat overlay for individual [photos]
/// that tracks pan/zoom via the live [MapCamera].
///
/// Thin glue: each photo's full-precision coordinate is projected per-frame
/// using the camera (NOT pre-grouped), then the unit-tested [computeHeatBlobs]
/// decides what to splat. The two-pass density→colorize render (accumulate a
/// soft gaussian field, then map through [buildHeatPalette]) happens in
/// [_HeatmapLayerState], which recomputes the colorized image only when the
/// splats or viewport change — not every paint — so panning stays smooth.
class HeatmapLayer extends StatefulWidget {
  /// Creates the heat overlay from individual [photos].
  const HeatmapLayer({super.key, required this.photos});

  /// The individual geotagged photos to render as heat (full precision, NOT
  /// grouped). Overlapping splats are what create the smooth gradient.
  final List<ExplorePhoto> photos;

  @override
  State<HeatmapLayer> createState() => _HeatmapLayerState();
}

class _HeatmapLayerState extends State<HeatmapLayer> {
  static final Uint8List _palette = buildHeatPalette();

  List<HeatBlob> _blobs = const [];
  Size _size = Size.zero;
  ui.Image? _image;
  int _generation = 0;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final size = camera.size;
    final offsets = <Offset>[
      for (final photo in widget.photos)
        camera.latLngToScreenOffset(photo.position),
    ];
    final blobs = computeHeatBlobs(offsets: offsets, size: size);

    // Only rebuild the (expensive) colorized image when inputs change.
    if (blobs != _blobs || size != _size) {
      _blobs = blobs;
      _size = size;
      _scheduleRender();
    }

    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: _HeatPainter(_image)),
    );
  }

  void _scheduleRender() {
    final generation = ++_generation;
    final blobs = _blobs;
    final size = _size;
    // Async two-pass render; on completion swap in the new image if still
    // current (drops stale renders from rapid pan/zoom).
    unawaited(
      renderHeatmapImage(blobs: blobs, size: size, palette: _palette).then((
        image,
      ) {
        if (!mounted || generation != _generation) {
          image?.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      }),
    );
  }
}

/// Renders [blobs] into a colorized heat [ui.Image] sized [size] using the
/// two-pass density→palette technique, or null when there's nothing to draw or
/// the viewport is empty.
///
/// Pass 1 accumulates a grayscale density field: each splat is a white radial
/// gradient whose alpha follows [gaussianFalloff] (peak = its [HeatBlob.weight]
/// at centre, fading smoothly to ~0 at [kHeatRadius]) composited additively so
/// overlapping splats SUM their alpha, saturating at full only where many pile
/// up. Pass 2 reads that field back and maps each pixel's accumulated alpha
/// through [palette] to RGBA, producing the cool→hot gradient with its long
/// transparent cold floor.
Future<ui.Image?> renderHeatmapImage({
  required List<HeatBlob> blobs,
  required Size size,
  required Uint8List palette,
}) async {
  final w = size.width.floor();
  final h = size.height.floor();
  if (blobs.isEmpty || w <= 0 || h <= 0) return null;

  // Precompute the gaussian gradient colour stops (shared by every splat shape;
  // only the peak alpha per blob differs). _kGaussianStops samples of
  // gaussianFalloff from centre (t=0) to rim (t=1).
  final stopPositions = <double>[
    for (var s = 0; s < _kGaussianStops; s++) s / (_kGaussianStops - 1),
  ];
  final falloffs = <double>[for (final t in stopPositions) gaussianFalloff(t)];

  // Pass 1: accumulate a soft gaussian grayscale density field.
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final blob in blobs) {
    final colors = <Color>[
      for (final f in falloffs)
        const Color(0xFFFFFFFF).withValues(alpha: blob.weight * f),
    ];
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(
        blob.offset,
        kHeatRadius,
        colors,
        stopPositions,
      );
    canvas.drawCircle(blob.offset, kHeatRadius, paint);
  }
  final picture = recorder.endRecording();
  final density = await picture.toImage(w, h);
  picture.dispose();

  final bytes = await density.toByteData();
  density.dispose();
  if (bytes == null) return null;

  // Pass 2: colorize each pixel's accumulated alpha through the palette LUT.
  // The accumulated alpha (0..255, saturating where many splats overlap) is the
  // density field directly: a lone faint splat stays in the transparent cold
  // tail, and many overlapping splats ramp it up to the hot red core.
  final src = bytes.buffer.asUint8List();
  final out = Uint8List(src.length);
  for (var i = 0; i < src.length; i += 4) {
    // density alpha is the accumulated intensity (RGB are white, ignored).
    final idx = src[i + 3] * 4;
    out[i] = palette[idx];
    out[i + 1] = palette[idx + 1];
    out[i + 2] = palette[idx + 2];
    out[i + 3] = palette[idx + 3];
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    out,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Paints the pre-rendered colorized heat [image] (built by
/// [renderHeatmapImage]) into the layer. A null image draws nothing (no points,
/// or the first frame before the async render lands).
class _HeatPainter extends CustomPainter {
  _HeatPainter(this.image);

  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final image = this.image;
    if (image == null) return;
    // Draw the whole colorized field at a reduced opacity so the map stays
    // visible through every part of the overlay, hot cores included.
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: kHeatLayerOpacity),
    );
  }

  @override
  bool shouldRepaint(_HeatPainter oldDelegate) => oldDelegate.image != image;
}
