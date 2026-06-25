/// The app-wide background layer: a user-chosen image (when set and present on
/// disk) or a default, very-light "map-style" topographic motif painted with a
/// [CustomPainter], topped by a readability veil whose opacity is user-tunable.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass.dart';

/// A single contour arc to draw: a centre, a radius, and the sweep it spans.
class ContourArc {
  /// Creates an arc descriptor.
  const ContourArc({
    required this.center,
    required this.radius,
    required this.startAngle,
    required this.sweepAngle,
  });

  /// The arc's centre, in the paint space.
  final Offset center;

  /// The arc's radius.
  final double radius;

  /// Where the sweep begins, in radians.
  final double startAngle;

  /// How far the sweep extends, in radians.
  final double sweepAngle;
}

/// Builds a faint family of concentric contour arcs filling a [size] canvas.
///
/// Pure geometry (no painting), so it can be unit-tested: arcs radiate from two
/// off-canvas focal points and step out by [spacing], clipped to those that can
/// intersect the canvas. The result reads as topographic contour lines.
List<ContourArc> contourArcs(Size size, {double spacing = 64}) {
  if (size.isEmpty || spacing <= 0) return const [];
  final maxR = size.longestSide * 1.6;
  final foci = <Offset>[
    Offset(-size.width * 0.15, size.height * 0.78),
    Offset(size.width * 1.1, -size.height * 0.05),
  ];
  final arcs = <ContourArc>[];
  for (final focus in foci) {
    for (var r = spacing; r <= maxR; r += spacing) {
      // Skip rings too small to reach the canvas from an off-screen focus.
      final dx = math.max(0.0, math.max(-focus.dx, focus.dx - size.width));
      final dy = math.max(0.0, math.max(-focus.dy, focus.dy - size.height));
      final minReach = math.sqrt(dx * dx + dy * dy);
      if (r < minReach) continue;
      arcs.add(
        ContourArc(
          center: focus,
          radius: r,
          startAngle: 0,
          sweepAngle: 2 * math.pi,
        ),
      );
    }
  }
  return arcs;
}

/// Paints the default very-light map background: a faint grid plus topographic
/// contour arcs in the paper/contour palette. Scales to any window — no asset.
class MapBackgroundPainter extends CustomPainter {
  /// Creates the painter for the given [brightness].
  const MapBackgroundPainter({required this.brightness});

  /// Drives the palette (paper vs dusk).
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final light = brightness == Brightness.light;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = light ? AppColors.paper : AppColors.dusk,
    );

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = (light ? AppColors.contour : AppColors.contourBright)
          .withValues(alpha: light ? 0.05 : 0.06);
    const step = 56.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = (light ? AppColors.contour : AppColors.contourBright)
          .withValues(alpha: light ? 0.08 : 0.10);
    for (final arc in contourArcs(size)) {
      canvas.drawCircle(arc.center, arc.radius, line);
    }
  }

  @override
  bool shouldRepaint(MapBackgroundPainter oldDelegate) =>
      oldDelegate.brightness != brightness;
}

/// The full-bleed background stack: image-or-default-map at the bottom and the
/// readability veil on top. Sized to fill its parent.
class AppBackground extends StatelessWidget {
  /// Creates the background. [imagePath], when non-null and present on disk,
  /// is shown; otherwise the default painted map is used. [veil] is the veil
  /// opacity (0.0–1.0).
  const AppBackground({super.key, this.imagePath, required this.veil});

  /// A user-chosen background image path, or null for the default map.
  final String? imagePath;

  /// Opacity of the readability veil over the background.
  final double veil;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final path = imagePath;
    final hasImage = path != null && File(path).existsSync();
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            Image.file(File(path), fit: BoxFit.cover)
          else
            CustomPaint(painter: MapBackgroundPainter(brightness: brightness)),
          ColoredBox(color: veilColor(brightness, veil)),
        ],
      ),
    );
  }
}
