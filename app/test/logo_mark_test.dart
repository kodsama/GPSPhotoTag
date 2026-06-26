import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/branding/logo_mark.dart';

void main() {
  testWidgets('LogoMark paints a CustomPaint sized to its edge length', (
    tester,
  ) async {
    // Non-const so the LogoMark constructor body is exercised at runtime.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: LogoMark(size: 40, key: UniqueKey())),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LogoMark),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.size, const Size.square(40));
  });

  testWidgets('rebuilding with a new size re-paints (shouldRepaint path)', (
    tester,
  ) async {
    // First build paints the mark.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: LogoMark(size: 40))),
      ),
    );
    // Rebuild at a different size: CustomPaint gets a fresh painter and Flutter
    // consults _LogoPainter.shouldRepaint to decide whether to repaint.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: LogoMark(size: 64))),
      ),
    );
    await tester.pump();

    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LogoMark),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.size, const Size.square(64));
  });
}
