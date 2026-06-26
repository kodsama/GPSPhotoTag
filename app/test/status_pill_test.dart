import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/theme/app_colors.dart';
import 'package:stunda/src/widgets/status_pill.dart';

Future<Color> _pillTextColor(WidgetTester tester, PhotoStatus status) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: StatusPill(status))),
    ),
  );
  final text = tester.widget<Text>(find.byType(Text));
  return text.style!.color!;
}

void main() {
  testWidgets('every status renders with its outcome colour', (tester) async {
    // Success family.
    for (final s in [
      PhotoStatus.tagged,
      PhotoStatus.interpolated,
      PhotoStatus.datesFixed,
      PhotoStatus.prunedTrashed,
    ]) {
      expect(await _pillTextColor(tester, s), AppColors.success, reason: '$s');
    }

    // Neutral / contour family.
    for (final s in [PhotoStatus.alreadyTagged, PhotoStatus.dryRun]) {
      expect(await _pillTextColor(tester, s), AppColors.contour, reason: '$s');
    }

    // Warning family.
    for (final s in [PhotoStatus.noGps, PhotoStatus.noTimestamp]) {
      expect(await _pillTextColor(tester, s), AppColors.warning, reason: '$s');
    }

    expect(
      await _pillTextColor(tester, PhotoStatus.prunedDeleted),
      AppColors.terracottaDark,
    );
    expect(await _pillTextColor(tester, PhotoStatus.error), AppColors.danger);
  });

  testWidgets('the wire name is shown with underscores spaced', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: StatusPill(PhotoStatus.alreadyTagged)),
        ),
      ),
    );
    expect(find.text('already tagged'), findsOneWidget);
  });
}
