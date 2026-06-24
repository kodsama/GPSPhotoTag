import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/main.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/input_summary.dart';
import 'package:gpsphototag_gui/src/state/wizard_step.dart';
import 'package:gpsphototag_gui/src/steps/input_step.dart';
import 'package:gpsphototag_gui/src/steps/options_step.dart';
import 'package:gpsphototag_gui/src/steps/output_step.dart';
import 'package:gpsphototag_gui/src/steps/result_step.dart';
import 'package:gpsphototag_gui/src/steps/run_step.dart';
import 'package:gpsphototag_gui/src/widgets/status_pill.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true}) => ToolStatus(
  id: id,
  name: id,
  present: present,
  purpose: 'test',
  required: false,
);

InputSummary _summaryWith(Directory dir, List<String> photos) =>
    InputSummary.from(
      folder: dir.path,
      photos: photos,
      gpxFiles: const [],
      googleFiles: const [],
    );

Future<void> _pump(WidgetTester tester, AppController controller) async {
  // A tall viewport so the whole active step is laid out and hit-testable
  // (the real app scrolls; the default 800x600 surface clips it).
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(GpsPhotoTagApp(controller: controller));
  await tester.pump();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('gui_steps'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('input step', () {
    testWidgets('choosing a folder scans it and shows the summary', (
      tester,
    ) async {
      final jpg = await writeJpegWithDate(tmp, 'a.jpg');
      final controller = AppController(
        runner: FakeEngineRunner(),
        pickFolder: () async => tmp.path,
      )..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetStep(
        WizardStep.input,
        completed: {WizardStep.toolkit},
      );
      await _pump(tester, controller);

      expect(find.byType(InputStep), findsOneWidget);
      expect(find.text('Choose photos folder'), findsOneWidget);

      await tester.tap(find.text('Choose photos folder'));
      await tester.pumpAndSettle();

      expect(controller.summary.folder, tmp.path);
      expect(controller.includedPhotos, contains(jpg));
      expect(find.textContaining('photo(s) found'), findsOneWidget);
    });
  });

  group('options step', () {
    Future<AppController> optionsController(
      WidgetTester tester, {
      bool exiftool = true,
    }) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool', present: exiftool)]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.options,
        completed: {WizardStep.toolkit, WizardStep.input, WizardStep.review},
      );
      await _pump(tester, controller);
      return controller;
    }

    testWidgets(
      'toggles, raw mode, time-diff and timezone drive the controller',
      (tester) async {
        final controller = await optionsController(tester);
        expect(find.byType(OptionsStep), findsOneWidget);

        // Toggle the three switches (copy-to-folder, replace, dry-run).
        final switches = find.byType(Switch);
        expect(switches, findsNWidgets(3));
        await tester.tap(switches.at(0)); // copy to folder
        await tester.pump();
        expect(controller.copyToFolder, isTrue);
        await tester.tap(switches.at(1)); // replace
        await tester.pump();
        expect(controller.replace, isTrue);
        await tester.tap(switches.at(2)); // dry run
        await tester.pump();
        expect(controller.dryRun, isTrue);

        // RAW mode: pick Sidecar.
        await tester.tap(find.text('Sidecar'));
        await tester.pump();
        expect(controller.rawMode, RawMode.sidecar);

        // Max time diff + timezone fields.
        await tester.enterText(find.byType(TextFormField).at(0), '45');
        await tester.pump();
        expect(controller.maxTimeDiffSeconds, 45);
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Europe/Paris',
        );
        await tester.pump();
        expect(controller.timezone, 'Europe/Paris');
      },
    );

    testWidgets('embed RAW mode is disabled and noted without exiftool', (
      tester,
    ) async {
      final controller = await optionsController(tester, exiftool: false);
      expect(find.textContaining('Embed needs ExifTool'), findsOneWidget);

      // Tapping the disabled Embed segment is a no-op.
      await tester.tap(find.text('Embed'), warnIfMissed: false);
      await tester.pump();
      expect(controller.rawMode, RawMode.auto);
    });
  });

  group('output step', () {
    testWidgets('in-place mode shows the warning banner', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetStep(
        WizardStep.output,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
        },
      );
      await _pump(tester, controller);

      expect(find.byType(OutputStep), findsOneWidget);
      expect(
        find.textContaining('Originals will be modified in place'),
        findsOneWidget,
      );
    });

    testWidgets('copy mode prompts for a destination, then shows it', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      controller.setCopyToFolder(true);
      controller.debugSetStep(
        WizardStep.output,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
        },
      );
      await _pump(tester, controller);

      expect(find.text('Choose destination folder'), findsOneWidget);
      expect(find.textContaining('Pick a folder to continue'), findsOneWidget);

      // Drive the controller directly (real folder picker can't run headless).
      controller.setOutDir('/out');
      await tester.pump();
      expect(find.text('/out'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('tapping "Choose destination folder" runs the picker', (
      tester,
    ) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        pickFolder: () async => '/picked/out',
      )..debugSetToolkit([_tool('exiftool')]);
      controller.setCopyToFolder(true);
      controller.debugSetStep(
        WizardStep.output,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
        },
      );
      await _pump(tester, controller);

      await tester.tap(find.text('Choose destination folder'));
      await tester.pumpAndSettle();

      expect(controller.outDir, '/picked/out');
      expect(find.text('/picked/out'), findsOneWidget);
    });
  });

  group('run step', () {
    testWidgets('Start streams progress, items and pills, then advances', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.run,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
        },
      );
      await _pump(tester, controller);

      expect(find.byType(RunStep), findsOneWidget);
      await tester.tap(find.textContaining('Tag 1 photo(s)'));
      await tester.pumpAndSettle();

      // The fake emitted a done summary -> the step auto-advanced to result.
      expect(controller.lastSummary, {'tagged': 1});
      expect(controller.step, WizardStep.result);
    });

    testWidgets('progress UI, item rows and a status pill render mid-run', (
      tester,
    ) async {
      // A fake that emits progress + an item then holds the stream open, so the
      // live run UI (still `running`) stays on screen for assertions.
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [
          ProgressEvent(done: 1, total: 2),
          ItemEvent(
            PhotoRow(
              path: '/photos/a.jpg',
              status: PhotoStatus.tagged,
              location: LocationResult(
                latitude: 42.5,
                longitude: 18.1,
                source: GpsSource.gpx,
                method: GpsMethod.exact,
              ),
            ),
          ),
        ],
      );
      addTearDown(fake.release);
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(
        _summaryWith(tmp, ['${tmp.path}/a.jpg', '${tmp.path}/b.jpg']),
      );
      controller.debugSetStep(
        WizardStep.run,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
        },
      );
      await _pump(tester, controller);

      await tester.tap(find.textContaining('Tag 2 photo(s)'));
      await tester
          .pump(); // let the scripted events fold in (stream stays open)
      await tester.pump();

      expect(controller.running, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('Recent results'), findsOneWidget);
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.byType(StatusPill), findsOneWidget);
      expect(find.text('tagged'), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('an error event surfaces in the run UI', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(
          events: const [ErrorEvent('boom while tagging')],
        ),
      )..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.run,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
        },
      );
      await _pump(tester, controller);

      await tester.tap(find.textContaining('Tag 1 photo(s)'));
      await tester.pumpAndSettle();

      expect(controller.errorMessage, 'boom while tagging');
      // Surfaced in the run-step banner (and mirrored into the activity log).
      expect(
        find.descendant(
          of: find.byType(RunStep),
          matching: find.text('boom while tagging'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('result step', () {
    AppController resultController() {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugAddLog('seed'); // touch log path
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      return controller;
    }

    testWidgets('renders the summary table and follow-up actions', (
      tester,
    ) async {
      final controller = resultController();
      // Seed a done summary via a no-op run.
      await controller.runTag();
      await _pump(tester, controller);

      expect(find.byType(ResultStep), findsOneWidget);
      expect(find.text('total'), findsOneWidget);
      expect(find.text('Follow-up tools'), findsOneWidget);
      expect(find.text('Render heatmap'), findsOneWidget);
      expect(find.text('Tag another'), findsOneWidget);
    });

    testWidgets('Render heatmap calls the runner and shows the image', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      await controller.runTag();
      await _pump(tester, controller);

      // renderMap awaits the engine stream; let real async work settle so the
      // controller completes the op and the step's setState fires, then pump
      // the resulting frame.
      await tester.runAsync(() async {
        await tester.tap(find.text('Render heatmap'));
        while (!controller.running &&
            !File('${tmp.path}/gpsphototag-heatmap.png').existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // Then wait for the op to finish (running flips back to false).
        while (controller.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      // Tapping ran the map operation through the runner, which wrote the PNG
      // into the picked folder, and the step set _heatmapPath -> the preview
      // (Heatmap heading + an Image widget) now renders.
      expect(fake.calls, contains('map'));
      expect(controller.errorMessage, isNull);
      expect(File('${tmp.path}/gpsphototag-heatmap.png').existsSync(), isTrue);
      expect(find.text('Heatmap'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('cancelling the prune dialog does not run the runner', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      await controller.runTag();
      await _pump(tester, controller);
      fake.calls.clear();

      await tester.tap(find.text('Prune orphan RAWs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
    });

    testWidgets('Fix dates "from file date" option runs the runner', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      await controller.runTag();
      await _pump(tester, controller);

      await tester.tap(find.text('Fix dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set EXIF capture time from file date'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('fixDates'));
    });

    testWidgets('Prune confirm dialog runs the runner', (tester) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      await controller.runTag();
      await _pump(tester, controller);

      await tester.tap(find.text('Prune orphan RAWs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Prune'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('prune'));
    });

    testWidgets('Fix dates dialog runs the runner', (tester) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')]);
      controller.debugSetSummary(_summaryWith(tmp, ['${tmp.path}/a.jpg']));
      controller.debugSetStep(
        WizardStep.result,
        completed: {
          WizardStep.toolkit,
          WizardStep.input,
          WizardStep.review,
          WizardStep.options,
          WizardStep.output,
          WizardStep.run,
        },
      );
      await controller.runTag();
      await _pump(tester, controller);

      await tester.tap(find.text('Fix dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set file date from EXIF capture time'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('fixDates'));
    });

    testWidgets('Tag another resets to the input step', (tester) async {
      final controller = resultController();
      await controller.runTag();
      await _pump(tester, controller);

      await tester.tap(find.text('Tag another'));
      await tester.pumpAndSettle();

      expect(controller.step, WizardStep.input);
      expect(controller.lastSummary, isNull);
    });
  });
}
