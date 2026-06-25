import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The Stunda logo drawn as a crisp vector — a camera aperture (the instant the
/// shutter opens) with a warm "moment" of light caught in the iris. Mirrors
/// `assets/logo.svg` (the app-icon source) so brand and app stay consistent.
class LogoMark extends StatelessWidget {
  /// Draws the mark at [size] square.
  const LogoMark({super.key, this.size = 40});

  /// Edge length in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    canvas.scale(s / 100); // author on a 100x100 grid
    const c = Offset(50, 50);
    const r = 40.0;

    // Lens rim.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..color = AppColors.terracotta,
    );

    // Six aperture blades forming a flat-top hexagonal opening.
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final p = Offset(50 + r * math.cos(a), 50 + r * math.sin(a));
      i == 0 ? hex.moveTo(p.dx, p.dy) : hex.lineTo(p.dx, p.dy);
    }
    hex.close();
    canvas.drawPath(
      hex,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.contour,
    );

    // The caught moment: a warm spark at the centre.
    canvas.drawCircle(
      c,
      11,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFF4C36B), Color(0xFFE0A33A), AppColors.terracotta],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: 11)),
    );
    canvas.drawCircle(
      const Offset(46.5, 46.5),
      3,
      Paint()..color = AppColors.paperRaised.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
