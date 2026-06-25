import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/main.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/input_summary.dart';
import 'package:gpsphototag_gui/src/state/wizard_step.dart';
import 'package:gpsphototag_gui/src/steps/input_step.dart';
import 'package:gpsphototag_gui/src/widgets/activity_log_panel.dart';
import 'package:gpsphototag_gui/src/widgets/step_card.dart';
import 'package:gpsphototag_gui/src/widgets/warning_banner.dart';

ToolStatus _tool(
  String id,
  String name, {
  bool present = true,
  String? version,
}) => ToolStatus(
  id: id,
  name: name,
  present: present,
  version: version,
  purpose: 'unlocks $name',
  required: false,
);

/// Pumps the app with [controller] already seeded so no real isolate or
/// subprocess runs during the test.
Future<void> _pumpApp(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(GpsPhotoTagApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('AppShell renders the header and the first step', (tester) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool', version: '12.0')]);
    await _pumpApp(tester, controller);

    expect(find.text('GPSPhotoTag'), findsOneWidget);
    // The walkthrough now starts at the input step.
    expect(find.byType(InputStep), findsOneWidget);
    expect(controller.step, WizardStep.input);
  });

  testWidgets('exactly one step card is expanded (shows Continue)', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool')]);
    await _pumpApp(tester, controller);

    // One card per step, one Continue button (only the active card expands).
    expect(find.byType(StepCard), findsNWidgets(WizardStep.values.length));
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });

  group('warning banner', () {
    testWidgets('shows when an environment warning is set', (tester) async {
      final controller = AppController(
        probeToolkit: () async => [
          _tool('exiftool', 'ExifTool', present: false),
        ],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(find.byType(WarningBanner), findsOneWidget);
      expect(find.textContaining("ExifTool couldn't start"), findsOneWidget);
    });

    testWidgets('hides after the close button is tapped', (tester) async {
      final controller = AppController(
        probeToolkit: () async => [
          _tool('exiftool', 'ExifTool', present: false),
        ],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(find.textContaining("ExifTool couldn't start"), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();

      expect(controller.warningDismissed, isTrue);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });

    testWidgets('renders nothing when no warning is set', (tester) async {
      final controller = AppController(
        probeToolkit: () async => [_tool('exiftool', 'ExifTool')],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(controller.environmentWarning, isNull);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });
  });

  testWidgets('activity-log panel opens on FAB tap and shows entries', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool')])
      ..debugAddLog('first event')
      ..debugAddLog('second event');
    await _pumpApp(tester, controller);

    // Panel starts hidden behind an IgnorePointer (entries not tappable yet).
    expect(find.byType(ActivityLogPanel), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Activity log'), findsOneWidget);
    expect(find.text('first event'), findsOneWidget);
    expect(find.text('second event'), findsOneWidget);

    // Tapping the scrim (top-left, away from the panel) closes the panel via
    // the AppShell.onClose callback; the FAB comes back.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('completed steps collapse to a tappable row with Edit', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool')])
      ..debugSetSummary(
        InputSummary.from(
          folder: '/photos',
          photos: const ['/photos/a.jpg'],
          gpxFiles: const [],
          googleFiles: const [],
        ),
      )
      ..debugSetStep(WizardStep.review, completed: {WizardStep.input});
    await _pumpApp(tester, controller);

    // The completed input step shows an 'Edit' affordance.
    expect(find.text('Edit'), findsOneWidget);
    // The active review step exposes its tag count.
    expect(find.textContaining('photo(s) will be tagged'), findsOneWidget);
  });
}
