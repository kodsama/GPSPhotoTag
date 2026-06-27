import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A pair of small "photo" tiles that previews how alike two photos must be to
/// group at the current similarity level.
///
/// The LEFT tile is a fixed reference scene; the RIGHT tile is the SAME scene
/// drawn by the same painter but perturbed by [variance] (0 = pixel-identical,
/// 1 = "same place, a different shot"). A "≈" sits between them. The whole thing
/// is drawn with a [CustomPainter] — no bundled image assets — so it stays light
/// and matches the app's cartographic feel.
class ExampleScenePair extends StatelessWidget {
  /// Builds the example pair at [variance] (0..1) with the [caption] below it.
  const ExampleScenePair({
    super.key,
    required this.variance,
    required this.caption,
    this.tileSize = 68,
  });

  /// How far the right tile diverges from the left (0 = identical, 1 = loosest).
  final double variance;

  /// One-line descriptor of what the current level catches.
  final String caption;

  /// Edge length of each square tile in logical pixels.
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SceneTile(variance: 0, size: tileSize),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '≈',
                style: text.titleLarge?.copyWith(color: AppColors.inkSoft),
              ),
            ),
            _SceneTile(variance: variance, size: tileSize),
          ],
        ),
        const SizedBox(height: 8),
        Text(caption, style: text.bodySmall),
      ],
    );
  }
}

/// A single rounded scene tile drawn by [_ScenePainter] at [variance].
class _SceneTile extends StatelessWidget {
  const _SceneTile({required this.variance, required this.size});

  final double variance;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ScenePainter(variance: variance)),
      ),
    );
  }
}

/// Paints a simple sky + sun + mountains scene, perturbed by [variance].
///
/// At variance 0 the scene is the fixed reference. As variance grows the painter
/// progressively (a) warms/dims the sky, (b) nudges + resizes the sun, then
/// (c) shifts the mountain heights/positions — so the tile reads as "same place,
/// a different shot" by the loosest level. Every offset is a pure function of
/// [variance], so the render is deterministic.
class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.variance});

  /// Divergence from the reference scene, clamped to 0..1.
  final double variance;

  @override
  void paint(Canvas canvas, Size size) {
    final v = variance.clamp(0.0, 1.0);
    final w = size.width;
    final h = size.height;

    // Sky: a top→bottom gradient that warms (toward terracotta) and dims as
    // variance grows, standing in for an exposure/white-balance shift.
    final top = Color.lerp(AppColors.contour, AppColors.terracotta, v * 0.5)!;
    final bottom = Color.lerp(
      AppColors.paperRaised,
      AppColors.warning,
      v * 0.35,
    )!;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(Offset.zero & size),
    );

    // Sun: nudged right + down and grown a touch as variance grows.
    final sunCenter = Offset(w * (0.28 + 0.18 * v), h * (0.30 + 0.10 * v));
    final sunRadius = w * (0.12 + 0.05 * v);
    canvas.drawCircle(
      sunCenter,
      sunRadius,
      Paint()..color = const Color(0xFFE0A33A),
    );

    // Mountains: two silhouettes whose peak heights and lateral positions drift
    // with variance, so the skyline changes shape at looser levels.
    final back = Path()
      ..moveTo(0, h)
      ..lineTo(w * (0.30 - 0.08 * v), h * (0.45 + 0.12 * v))
      ..lineTo(w * (0.62 + 0.06 * v), h * (0.58 - 0.10 * v))
      ..lineTo(w, h * 0.50)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(back, Paint()..color = AppColors.contour);

    final front = Path()
      ..moveTo(0, h)
      ..lineTo(w * (0.18 + 0.10 * v), h * (0.62 + 0.10 * v))
      ..lineTo(w * (0.52 - 0.10 * v), h * (0.72 - 0.08 * v))
      ..lineTo(w, h * (0.66 + 0.06 * v))
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(front, Paint()..color = AppColors.contourBright);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) =>
      oldDelegate.variance != variance;
}
