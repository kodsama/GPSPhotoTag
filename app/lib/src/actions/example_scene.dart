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

/// A pair of small "photo" tiles that previews what the Shrink "Low quality"
/// stage flags: a KEPT sample (sharp, high-contrast, vivid) on the LEFT versus a
/// FLAGGED sample on the RIGHT, degraded by [degradation] (0 = identical to the
/// kept side, 1 = very blurry/flat/grey). The degradation visibly reduces the
/// three real quality components — edge crispness (sharpness), tonal range
/// (contrast), and saturation (colourfulness) — so the user SEES what a
/// low-quality photo looks like. Drawn with a [CustomPainter] — no bundled image
/// assets — to match the app's cartographic feel and stay deterministic.
class QualityExamplePair extends StatelessWidget {
  /// Builds the kept-vs-flagged pair. [degradation] (0..1) controls how degraded
  /// the flagged (right) tile looks; [keptLabel]/[flaggedLabel] caption the
  /// tiles and [caption] describes what the current threshold flags.
  const QualityExamplePair({
    super.key,
    required this.degradation,
    required this.keptLabel,
    required this.flaggedLabel,
    required this.caption,
    this.tileSize = 68,
  });

  /// How degraded the flagged (right) tile looks (0 = crisp/vivid, 1 = worst).
  final double degradation;

  /// Caption under the LEFT (kept) tile.
  final String keptLabel;

  /// Caption under the RIGHT (flagged) tile.
  final String flaggedLabel;

  /// One-line descriptor of what the current threshold flags.
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _QualityTile(
              degradation: 0,
              size: tileSize,
              label: keptLabel,
              accent: AppColors.success,
            ),
            const SizedBox(width: 16),
            _QualityTile(
              degradation: degradation,
              size: tileSize,
              label: flaggedLabel,
              accent: AppColors.danger,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(caption, style: text.bodySmall),
      ],
    );
  }
}

/// A single quality sample: a rounded tile drawn by [_QualityScenePainter] at
/// [degradation], with a small [accent]-coloured [label] beneath it.
class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.degradation,
    required this.size,
    required this.label,
    required this.accent,
  });

  final double degradation;
  final double size;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: _QualityScenePainter(degradation: degradation),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: size,
          child: Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints the same simple scene at two quality levels, degraded by
/// [degradation].
///
/// At degradation 0 the scene is crisp: a sharp horizon edge, a bright sun, and
/// vivid colours. As degradation grows the painter (a) softens the horizon edge
/// into a blurry band (less sharpness), (b) compresses the sky/ground tones
/// toward a flat mid-grey (less contrast), and (c) desaturates the colours
/// toward grey (less colourfulness) — the three components of the engine's
/// composite quality. Every step is a pure function of [degradation], so the
/// render is deterministic.
class _QualityScenePainter extends CustomPainter {
  _QualityScenePainter({required this.degradation});

  /// Degradation of this tile, clamped to 0..1.
  final double degradation;

  @override
  void paint(Canvas canvas, Size size) {
    final d = degradation.clamp(0.0, 1.0);
    final w = size.width;
    final h = size.height;

    // Contrast: as degradation grows the sky and ground tones converge toward a
    // flat mid-grey, standing in for a low-contrast (washed-out) frame.
    const grey = Color(0xFF8C857A);
    final sky = Color.lerp(AppColors.contourBright, grey, d)!;
    final ground = Color.lerp(AppColors.terracotta, grey, d)!;
    // Colourfulness: desaturate both bands toward their own luma as d grows.
    final skyTone = _desaturate(sky, d);
    final groundTone = _desaturate(ground, d);

    final horizon = h * 0.55;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, horizon), Paint()..color = skyTone);
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, w, h - horizon),
      Paint()..color = groundTone,
    );

    // Sharpness: a crisp horizon edge at d=0 that, as d grows, becomes a soft
    // blurred band blending sky into ground (a gradient stripe).
    final blur = (h * 0.04) + (h * 0.40) * d;
    canvas.drawRect(
      Rect.fromLTWH(0, horizon - blur / 2, w, blur),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [skyTone, groundTone],
        ).createShader(Rect.fromLTWH(0, horizon - blur / 2, w, blur)),
    );

    // Sun: a vivid disc that dims and desaturates with degradation.
    final sun = _desaturate(Color.lerp(const Color(0xFFE0A33A), grey, d)!, d);
    canvas.drawCircle(
      Offset(w * 0.30, horizon * 0.5),
      w * 0.13,
      Paint()..color = sun,
    );
  }

  /// Blends [color] toward its own grayscale luma by [amount] (0 = unchanged,
  /// 1 = fully grey), modelling a drop in colourfulness.
  static Color _desaturate(Color color, double amount) {
    final luma =
        (0.299 * (color.r * 255) +
                0.587 * (color.g * 255) +
                0.114 * (color.b * 255))
            .round();
    return Color.lerp(color, Color.fromARGB(255, luma, luma, luma), amount)!;
  }

  @override
  bool shouldRepaint(covariant _QualityScenePainter oldDelegate) =>
      oldDelegate.degradation != degradation;
}
