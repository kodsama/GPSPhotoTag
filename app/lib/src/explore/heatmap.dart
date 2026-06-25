import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../theme/app_colors.dart';
import 'explore_model.dart';

/// One heat blob to paint: a radial gradient centred at [offset], reaching
/// [radius] pixels, at relative [intensity] (0..1) driving its opacity.
@immutable
class HeatBlob {
  /// Creates a blob at [offset] of [radius] px and [intensity] (0..1).
  const HeatBlob({
    required this.offset,
    required this.radius,
    required this.intensity,
  });

  /// Blob centre in screen pixels.
  final Offset offset;

  /// Blob radius in screen pixels.
  final double radius;

  /// Relative weight in 0..1 (more stacked photos here ⇒ hotter).
  final double intensity;

  @override
  bool operator ==(Object other) =>
      other is HeatBlob &&
      other.offset == offset &&
      other.radius == radius &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(offset, radius, intensity);
}

/// Computes the heat blobs to paint for [points] given each point's projected
/// screen [offsets] and the viewport [size].
///
/// Pure (no widgets, no map camera) so the projection→weight→radius math is
/// unit testable: input is the already-projected screen offsets (one per point,
/// in the same order) plus each point's photo [counts]; output is the blob list.
/// Points whose offset falls outside the viewport (with a [radius] margin) are
/// dropped. Intensity scales with the point's photo count relative to the
/// busiest point so dense clusters glow hotter; radius grows mildly with count.
List<HeatBlob> computeHeatBlobs({
  required List<Offset> offsets,
  required List<int> counts,
  required Size size,
  double radius = 42,
}) {
  assert(offsets.length == counts.length, 'offsets/counts length mismatch');
  if (offsets.isEmpty) return const [];

  var maxCount = 1;
  for (final c in counts) {
    if (c > maxCount) maxCount = c;
  }

  final blobs = <HeatBlob>[];
  for (var i = 0; i < offsets.length; i++) {
    final o = offsets[i];
    // Cull blobs whose influence can't reach the viewport.
    final r = radius * (1 + 0.4 * ((counts[i] - 1) / maxCount));
    if (o.dx < -r ||
        o.dy < -r ||
        o.dx > size.width + r ||
        o.dy > size.height + r) {
      continue;
    }
    // Intensity: a floor so single photos are still visible, scaling to 1 at
    // the busiest point.
    final intensity = (0.45 + 0.55 * (counts[i] / maxCount)).clamp(0.0, 1.0);
    blobs.add(HeatBlob(offset: o, radius: r, intensity: intensity));
  }
  return blobs;
}

/// A flutter_map layer drawing a density heat overlay for [points] that tracks
/// pan/zoom via the live [MapCamera].
///
/// Thin glue: projection per-frame uses the camera, then the unit-tested
/// [computeHeatBlobs] decides what to paint and [_HeatPainter] paints additive
/// translucent terracotta radial gradients.
class HeatmapLayer extends StatelessWidget {
  /// Creates the heat overlay for [points].
  const HeatmapLayer({super.key, required this.points});

  /// The grouped map points to render as heat.
  final List<MapPoint> points;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final offsets = <Offset>[];
    final counts = <int>[];
    for (final point in points) {
      offsets.add(camera.latLngToScreenOffset(point.position));
      counts.add(point.count);
    }
    final blobs = computeHeatBlobs(
      offsets: offsets,
      counts: counts,
      size: camera.size,
    );
    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: _HeatPainter(blobs)),
    );
  }
}

/// Paints [HeatBlob]s as additively-blended terracotta radial gradients
/// (hot core → transparent edge) so overlapping blobs build up density.
class _HeatPainter extends CustomPainter {
  _HeatPainter(this.blobs);

  final List<HeatBlob> blobs;

  @override
  void paint(Canvas canvas, Size size) {
    for (final blob in blobs) {
      final core = AppColors.terracotta.withValues(
        alpha: 0.55 * blob.intensity,
      );
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(colors: [core, core.withValues(alpha: 0)])
            .createShader(
              Rect.fromCircle(center: blob.offset, radius: blob.radius),
            );
      canvas.drawCircle(blob.offset, blob.radius, paint);
    }
  }

  @override
  bool shouldRepaint(_HeatPainter oldDelegate) => oldDelegate.blobs != blobs;
}
