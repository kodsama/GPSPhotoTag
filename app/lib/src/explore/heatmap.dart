import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'explore_model.dart';

/// Per-point influence radius, in SCREEN pixels — a constant, never scaled by
/// zoom or photo count. A tight cluster therefore reads as a small hot dot when
/// zoomed out and spreads naturally as you zoom in. Density (and thus heat)
/// comes from how many points overlap within this radius, not from inflating it.
const double kHeatRadius = 34;

/// Overall opacity (0..1) of the entire composited heat overlay, including the
/// hot red cores, so the map (streets, labels, water) always reads through it —
/// like a reference heatmap.js layer. Tune this single knob to make the heat
/// more or less translucent.
const double kHeatLayerOpacity = 0.65;

/// One heat point to paint: a soft additive splat centred at [offset], reaching
/// [kHeatRadius] pixels, contributing [weight] (0..1) of density at its core.
@immutable
class HeatBlob {
  /// Creates a splat at [offset] contributing [weight] (0..1) of density.
  const HeatBlob({required this.offset, required this.weight});

  /// Splat centre in screen pixels.
  final Offset offset;

  /// Per-point density contribution at the centre, in 0..1. More photos at one
  /// coordinate ⇒ a heavier single splat; overlapping splats then accumulate.
  final double weight;

  @override
  bool operator ==(Object other) =>
      other is HeatBlob && other.offset == offset && other.weight == weight;

  @override
  int get hashCode => Object.hash(offset, weight);
}

/// Computes the heat splats to paint for points given each point's projected
/// screen [offsets] and the viewport [size].
///
/// Pure (no widgets, no map camera) so the projection→cull→weight math is unit
/// testable: input is the already-projected screen offsets (one per point, in
/// the same order) plus each point's photo [counts]; output is the splat list.
/// Points whose influence can't reach the viewport (offset further than
/// [radius] outside it) are dropped. Each splat's [HeatBlob.weight] grows with
/// the point's photo count — a single photo is a light splat, a stacked
/// coordinate a heavier one — but the radius is the same constant for all, so
/// density (and heat) builds from OVERLAP, not from inflating any one splat.
List<HeatBlob> computeHeatBlobs({
  required List<Offset> offsets,
  required List<int> counts,
  required Size size,
  double radius = kHeatRadius,
}) {
  assert(offsets.length == counts.length, 'offsets/counts length mismatch');
  if (offsets.isEmpty) return const [];

  final blobs = <HeatBlob>[];
  for (var i = 0; i < offsets.length; i++) {
    final o = offsets[i];
    // Cull splats whose influence can't reach the viewport.
    if (o.dx < -radius ||
        o.dy < -radius ||
        o.dx > size.width + radius ||
        o.dy > size.height + radius) {
      continue;
    }
    blobs.add(HeatBlob(offset: o, weight: weightForCount(counts[i])));
  }
  return blobs;
}

/// The per-point density [HeatBlob.weight] for a coordinate holding [count]
/// photos, in 0..1.
///
/// A single photo gets a soft floor so it still shows as a cool spot; extra
/// photos at the same coordinate add diminishing weight (log-shaped) so one
/// huge stack doesn't swamp the field on its own — overlap between distinct
/// points is what drives the hot core.
double weightForCount(int count) {
  final n = count < 1 ? 1 : count;
  // 1 → 0.45, 2 → ~0.76, 6 → ~1.0 (clamped). log2 so a single huge stack rises
  // fast then flattens, letting overlap between points drive the hot core.
  final w = 0.45 + 0.31 * (math.log(n) / math.ln2);
  return w.clamp(0.0, 1.0);
}

/// Builds the 256-entry intensity→RGBA palette lookup table used to colorize
/// the accumulated density field, returned as a flat `Uint8List` of length
/// 256×4 (`[r,g,b,a, r,g,b,a, …]`, straight/unpremultiplied).
///
/// Index `i` (0..255) is density `i/255`. The ramp matches a classic
/// heatmap.js / leaflet.heat look: the cold end is fully transparent (so sparse
/// areas reveal the map under both light and dark tiles), rising through blue,
/// cyan, green, yellow to an opaque hot red core. Pure, so the key stops and
/// the transparent floor are unit testable.
Uint8List buildHeatPalette() {
  // (stop in 0..1, color, alpha 0..255). Alpha ramps in quickly from the
  // transparent floor so even sparse density is faintly visible.
  const stops = <(double, int, int, int, int)>[
    (0.00, 0x00, 0x00, 0x00, 0), // transparent
    (0.15, 0x22, 0x22, 0xEE, 90), // blue
    (0.35, 0x22, 0xCC, 0xEE, 160), // cyan
    (0.55, 0x22, 0xEE, 0x44, 205), // green
    (0.75, 0xEE, 0xEE, 0x22, 235), // yellow
    (1.00, 0xEE, 0x22, 0x22, 255), // hot red
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

/// A flutter_map layer drawing a density heat overlay for [points] that tracks
/// pan/zoom via the live [MapCamera].
///
/// Thin glue: projection per-frame uses the camera, then the unit-tested
/// [computeHeatBlobs] decides what to splat. The two-pass density→colorize
/// render (accumulate grayscale, then map through [buildHeatPalette]) happens in
/// [_HeatmapLayerState], which recomputes the colorized image only when the
/// splats or viewport change — not every paint — so panning stays smooth.
class HeatmapLayer extends StatefulWidget {
  /// Creates the heat overlay for [points].
  const HeatmapLayer({super.key, required this.points});

  /// The grouped map points to render as heat.
  final List<MapPoint> points;

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
    final offsets = <Offset>[];
    final counts = <int>[];
    for (final point in widget.points) {
      offsets.add(camera.latLngToScreenOffset(point.position));
      counts.add(point.count);
    }
    final blobs = computeHeatBlobs(
      offsets: offsets,
      counts: counts,
      size: size,
    );

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
/// gradient (alpha = its [HeatBlob.weight] at centre, fading to transparent at
/// [kHeatRadius]) composited additively so overlapping splats sum their alpha,
/// saturating at full. Pass 2 reads that field back and maps each pixel's
/// accumulated alpha through [palette] to RGBA, producing the cool→hot gradient
/// with a transparent cold floor.
Future<ui.Image?> renderHeatmapImage({
  required List<HeatBlob> blobs,
  required Size size,
  required Uint8List palette,
}) async {
  final w = size.width.floor();
  final h = size.height.floor();
  if (blobs.isEmpty || w <= 0 || h <= 0) return null;

  // Pass 1: accumulate grayscale density.
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final blob in blobs) {
    final core = const Color(0xFFFFFFFF).withValues(alpha: blob.weight);
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(blob.offset, kHeatRadius, <Color>[
        core,
        const Color(0x00FFFFFF),
      ]);
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
  // density field directly: a lone splat (weight ≈ 0.45) lands mid-blue/cyan,
  // and a few overlapping splats ramp it to the hot red core.
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
