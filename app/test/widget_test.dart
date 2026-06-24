import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/main.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/input_summary.dart';
import 'package:gpsphototag_gui/src/state/wizard_step.dart';
import 'package:gpsphototag_gui/src/steps/toolkit_step.dart';
import 'package:gpsphototag_gui/src/widgets/activity_log_panel.dart';
import 'package:gpsphototag_gui/src/widgets/step_card.dart';

ToolStatus _tool(
  String id,
  String name, {
  bool present = true,
  String? version,
  String? installCommand,
}) => ToolStatus(
  id: id,
  name: name,
  present: present,
  version: version,
  purpose: 'unlocks $name',
  required: false,
  installCommand: installCommand,
);

/// Pumps the app with [controller] already seeded so no real isolate or
/// subprocess runs during the test.
Future<void> _pumpApp(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(GpsPhotoTagApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('AppShell renders the header and the first step', (tester) async {
    // Seed toolkit so the toolkit step does not probe the host.
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool', version: '12.0')]);
    await _pumpApp(tester, controller);

    expect(find.text('GPSPhotoTag'), findsOneWidget);
    expect(find.text('Toolkit'), findsOneWidget);
    // The toolkit step body shows the seeded tool row.
    expect(find.text('ExifTool'), findsOneWidget);
  });

  testWidgets('exactly one step card is expanded (shows Continue)', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool')]);
    await _pumpApp(tester, controller);

    // Seven cards, one Continue button (only the active card expands).
    expect(find.byType(StepCard), findsNWidgets(WizardStep.values.length));
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });

  testWidgets('toolkit step lists multiple tool rows from seeded results', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([
        _tool('exiftool', 'ExifTool', version: '12.0'),
        _tool(
          'libheif',
          'libheif',
          present: false,
          installCommand: 'brew install libheif',
        ),
      ]);
    await _pumpApp(tester, controller);

    expect(find.byType(ToolkitStep), findsOneWidget);
    expect(find.text('ExifTool'), findsOneWidget);
    expect(find.text('libheif'), findsOneWidget);
    // Missing + installable tool gets an Install button.
    expect(find.widgetWithText(OutlinedButton, 'Install'), findsOneWidget);
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
      ..debugSetStep(
        WizardStep.review,
        completed: {WizardStep.toolkit, WizardStep.input},
      );
    await _pumpApp(tester, controller);

    // Completed earlier steps show an 'Edit' affordance.
    expect(find.text('Edit'), findsNWidgets(2));
    // The active review step exposes its tag count.
    expect(find.textContaining('photo(s) will be tagged'), findsOneWidget);
  });
}
