import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The Stunda logo drawn as a crisp vector — a map pin (a place, a moment "you
/// were here") whose head is a glowing camera lens holding the light of the
/// moment, with a sparkle for beauty. Mirrors `assets/logo.svg` (the app-icon
/// source) so brand and app stay consistent.
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
    const head = Offset(50, 41);

    // Pin body (teardrop).
    final pin = Path()
      ..moveTo(50, 90)
      ..cubicTo(50, 90, 22, 60, 22, 41)
      ..arcToPoint(
        const Offset(78, 41),
        radius: const Radius.circular(28),
        clockwise: true,
      )
      ..cubicTo(78, 60, 50, 90, 50, 90)
      ..close();
    canvas.drawPath(pin, Paint()..color = AppColors.terracotta);

    // Lens: paper frame, warm glowing glass, teal rim.
    canvas.drawCircle(head, 20.5, Paint()..color = AppColors.paperRaised);
    canvas.drawCircle(
      head,
      16,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.2, -0.3),
          colors: [Color(0xFFF6D58A), Color(0xFFE0A33A), Color(0xFFBE5230)],
          stops: [0, 0.42, 1],
        ).createShader(Rect.fromCircle(center: head, radius: 16)),
    );
    canvas.drawCircle(
      head,
      20.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..color = AppColors.contour,
    );

    // Glassy highlight on the lens.
    canvas.drawArc(
      Rect.fromCircle(center: head, radius: 10),
      3.7,
      1.4,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = AppColors.paperRaised.withValues(alpha: 0.85),
    );

    // Sparkle: the beautiful moment.
    const c = Offset(63, 29);
    const r = 5.0;
    final sparkle = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.18, c.dy - r * 0.18, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.18, c.dy + r * 0.18, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.18, c.dy + r * 0.18, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.18, c.dy - r * 0.18, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(sparkle, Paint()..color = AppColors.paperRaised);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
