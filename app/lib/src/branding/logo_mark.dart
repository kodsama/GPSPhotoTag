import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The Stunda logo drawn as a crisp vector — a map pin whose lens frames a
/// tiny landscape. Used in the in-app header; mirrors `assets/logo.svg` (the app
/// icon source) so brand and app stay consistent.
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
    canvas.scale(s / 100); // author at a 100x100 grid

    // Pin body (teardrop).
    final pin = Path()
      ..moveTo(50, 92)
      ..cubicTo(50, 92, 18, 60, 18, 40)
      ..arcToPoint(
        const Offset(82, 40),
        radius: const Radius.circular(32),
        clockwise: true,
      )
      ..cubicTo(82, 60, 50, 92, 50, 92)
      ..close();
    canvas.drawPath(pin, Paint()..color = AppColors.terracotta);

    // Lens disc.
    canvas.drawCircle(
      const Offset(50, 40),
      22,
      Paint()..color = AppColors.paperRaised,
    );

    // Tiny landscape clipped to the lens.
    canvas.save();
    canvas.clipPath(
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(50, 40), radius: 21)),
    );
    canvas.drawRect(
      const Rect.fromLTWH(29, 19, 42, 42),
      Paint()..color = const Color(0xFFCFE3DD),
    );
    canvas.drawRect(
      const Rect.fromLTWH(29, 42, 42, 19),
      Paint()..color = const Color(0xFFEAF0EC),
    );
    canvas.drawCircle(
      const Offset(42, 31),
      5,
      Paint()..color = const Color(0xFFE0A33A),
    );
    canvas.drawPath(
      Path()
        ..moveTo(29, 52)
        ..lineTo(45, 33)
        ..lineTo(57, 47)
        ..lineTo(64, 39)
        ..lineTo(71, 52)
        ..close(),
      Paint()..color = AppColors.contour,
    );
    canvas.restore();

    // Lens rim.
    canvas.drawCircle(
      const Offset(50, 40),
      22,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.terracottaDark,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
