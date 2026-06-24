import 'dart:async';

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

    // Tapping the scrim (top-left, away from the panel) closes the panel via
    // the AppShell.onClose callback; the FAB comes back.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('toolkit step shows a spinner while the first probe runs', (
    tester,
  ) async {
    // Empty toolkit -> the post-frame callback kicks off a probe. A gated fake
    // probe lets us observe the in-flight spinner, then resolve deterministically.
    final gate = Completer<List<ToolStatus>>();
    final controller = AppController(probeToolkit: () => gate.future);
    await _pumpApp(tester, controller);
    await tester.pump(); // run the post-frame callback (sets toolkitLoading)

    expect(controller.toolkitLoading, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete([_tool('exiftool', 'ExifTool')]);
    await tester.pumpAndSettle();

    expect(controller.toolkitLoading, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('ExifTool'), findsOneWidget);
  });

  testWidgets('toolkit warning banner shows when exiftool is missing', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool', present: false)]);
    await _pumpApp(tester, controller);

    expect(controller.exiftoolAvailable, isFalse);
    expect(find.textContaining('ExifTool is missing'), findsOneWidget);
  });

  testWidgets('toolkit success banner shows when exiftool is present', (
    tester,
  ) async {
    final controller = AppController()
      ..debugSetToolkit([_tool('exiftool', 'ExifTool')]);
    await _pumpApp(tester, controller);

    expect(find.textContaining('All capabilities available'), findsOneWidget);
  });

  testWidgets('tapping Install runs the install flow and re-probes', (
    tester,
  ) async {
    var probes = 0;
    // After install, the re-probe returns libheif now present.
    final controller =
        AppController(
          probeToolkit: () async {
            probes++;
            return [_tool('libheif', 'libheif')];
          },
        )..debugSetToolkit([
          _tool(
            'libheif',
            'libheif',
            present: false,
            // A harmless no-op command so the install attempt is fast and does
            // not change the host; the flow then re-probes via runToolkitCheck.
            installCommand: 'true',
          ),
        ]);
    await _pumpApp(tester, controller);

    // The install flow runs a real (fast) subprocess then re-probes; let real
    // async work run to completion via runAsync, then pump to flush the rebuild.
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Install'));
      while (probes == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    // The re-probe ran and the seeded "missing" libheif is now reported present.
    expect(probes, 1);
    expect(controller.toolkit.single.present, isTrue);
    expect(find.widgetWithText(OutlinedButton, 'Install'), findsNothing);
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
