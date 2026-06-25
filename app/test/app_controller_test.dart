import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/input_summary.dart';
import 'package:gpsphototag_gui/src/state/wizard_step.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true}) => ToolStatus(
  id: id,
  name: id,
  present: present,
  purpose: 'test',
  required: false,
);

InputSummary _summaryWith(List<String> photos) => InputSummary.from(
  folder: '/photos',
  photos: photos,
  gpxFiles: const [],
  googleFiles: const [],
);

void main() {
  group('step-advance logic', () {
    test('the walkthrough starts at the input step', () {
      final c = AppController();
      expect(c.step, WizardStep.input);
      expect(WizardStep.values.first, WizardStep.input);
    });

    test(
      'input is unsatisfied until photos arrive, then advances to review',
      () {
        final c = AppController();
        expect(c.isStepSatisfied(WizardStep.input), isFalse);

        c.debugSetSummary(_summaryWith(['/photos/a.jpg', '/photos/b.jpg']));
        expect(c.isStepSatisfied(WizardStep.input), isTrue);
        expect(c.includedCount, 2);

        c.completeAndAdvance();
        expect(c.isCompleted(WizardStep.input), isTrue);
        expect(c.step, WizardStep.review);
      },
    );

    test('completeAndAdvance is a no-op when the step is unsatisfied', () {
      final c = AppController();
      c.completeAndAdvance();
      expect(c.step, WizardStep.input);
      expect(c.isCompleted(WizardStep.input), isFalse);
    });

    test('review reflects include/exclude toggles', () {
      final c = AppController()
        ..debugSetSummary(_summaryWith(['/photos/a.jpg', '/photos/b.jpg']));
      c.setIncluded('/photos/a.jpg', false);
      expect(c.includedCount, 1);
      expect(c.includedPhotos, ['/photos/b.jpg']);
    });

    test('goTo only revisits completed or earlier steps', () {
      final c = AppController()
        ..debugSetStep(WizardStep.review, completed: {WizardStep.input});
      c.goTo(WizardStep.run); // not completed, later -> ignored
      expect(c.step, WizardStep.review);
      c.goTo(WizardStep.input); // completed -> allowed
      expect(c.step, WizardStep.input);
    });
  });

  group('options', () {
    test('embed RAW mode is rejected without exiftool', () {
      final c = AppController();
      c.setRawMode(RawMode.embed);
      expect(c.rawMode, RawMode.auto);

      c.debugSetToolkit([_tool('exiftool')]);
      c.setRawMode(RawMode.embed);
      expect(c.rawMode, RawMode.embed);
    });

    test('in-place run sets overwrite; copy run sets outDir', () {
      final c = AppController();
      expect(c.buildTagOptions().overwrite, isTrue);
      expect(c.buildTagOptions().outDir, isNull);

      c.setCopyToFolder(true);
      c.setOutDir('/out');
      final opts = c.buildTagOptions();
      expect(opts.overwrite, isFalse);
      expect(opts.outDir, '/out');
    });

    test('output step needs a destination only when copying', () {
      final c = AppController()..debugSetStep(WizardStep.output);
      expect(c.isStepSatisfied(WizardStep.output), isTrue);
      c.setCopyToFolder(true);
      expect(c.isStepSatisfied(WizardStep.output), isFalse);
      c.setOutDir('/out');
      expect(c.isStepSatisfied(WizardStep.output), isTrue);
    });
  });

  group('activity log', () {
    test(
      'debug log entries raise the unread count and markLogRead clears it',
      () {
        final c = AppController();
        c.debugAddLog('hello');
        c.debugAddLog('world', level: LogLevel.error);
        expect(c.unreadCount, 2);
        expect(c.logEntries.length, 2);
        c.markLogRead();
        expect(c.unreadCount, 0);
      },
    );
  });

  group('operations', () {
    test('runTag folds events into state and tallies the summary', () async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetSummary(_summaryWith(['/photos/a.jpg']));
      await c.runTag();

      expect(c.running, isFalse);
      expect(c.lastSummary, {'tagged': 1});
      expect(c.rows, isNotEmpty);
      expect(c.errorMessage, isNull);
    });

    test('an ErrorEvent surfaces as errorMessage and stops the run', () async {
      final c = AppController(
        runner: FakeEngineRunner(events: const [ErrorEvent('nope')]),
      )..debugSetSummary(_summaryWith(['/photos/a.jpg']));
      await c.runTag();

      expect(c.errorMessage, 'nope');
      expect(c.running, isFalse);
    });

    test('renderMap returns null when no folder is picked', () async {
      final c = AppController(runner: FakeEngineRunner());
      expect(await c.renderMap(), isNull);
    });

    test('renderMap runs the map op and returns the output path', () async {
      final tmp = Directory.systemTemp.createTempSync('rendermap');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetSummary(
          InputSummary.from(
            folder: tmp.path,
            photos: ['${tmp.path}/a.jpg'],
            gpxFiles: const [],
            googleFiles: const [],
          ),
        );
      final path = await c.renderMap();
      expect(fake.calls, contains('map'));
      expect(path, endsWith('gpsphototag-heatmap.png'));
    });

    test('runPrune is a no-op without a folder, runs with one', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.runPrune(); // no folder -> no call
      expect(fake.calls, isEmpty);

      c.debugSetSummary(_summaryWith(['/photos/a.jpg']));
      await c.runPrune(dryRun: true);
      expect(fake.calls, contains('prune'));
    });

    test('runFixDates streams through the runner', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetSummary(_summaryWith(['/photos/a.jpg']));
      await c.runFixDates(FixDatesMode.exif, dryRun: true);
      expect(fake.calls, contains('fixDates'));
    });

    test(
      'a stream-level error surfaces as errorMessage and ends the run',
      () async {
        final c = AppController(runner: ThrowingEngineRunner())
          ..debugSetSummary(_summaryWith(['/photos/a.jpg']));
        await c.runTag();

        expect(c.errorMessage, contains('stream blew up'));
        expect(c.running, isFalse);
        // The error was mirrored into the activity log at error level.
        expect(c.logEntries.any((e) => e.level == LogLevel.error), isTrue);
      },
    );
  });

  group('theme', () {
    test('setDark flips relative to the displayed brightness', () {
      final c = AppController();
      expect(c.themeMode, ThemeMode.system);
      // Header passes the currently-shown brightness; from system-dark the user
      // taps "switch to light" -> setDark(false) -> explicit light (a visible
      // change, unlike a naive toggle that would pick dark and do nothing).
      c.setDark(false);
      expect(c.themeMode, ThemeMode.light);
      c.setDark(true);
      expect(c.themeMode, ThemeMode.dark);
      // Setting the same mode is a no-op.
      c.setDark(true);
      expect(c.themeMode, ThemeMode.dark);
    });
  });

  group('options branches', () {
    test('turning copy-to-folder off clears the chosen outDir', () {
      final c = AppController();
      c.setCopyToFolder(true);
      c.setOutDir('/out');
      expect(c.outDir, '/out');
      c.setCopyToFolder(false);
      expect(c.outDir, isNull);
    });

    test('maxTimeDiff clamps negatives to zero', () {
      final c = AppController();
      c.setMaxTimeDiff(120);
      expect(c.maxTimeDiffSeconds, 120);
      expect(c.buildTagOptions().maxTimeDiff, const Duration(seconds: 120));
      c.setMaxTimeDiff(-5);
      expect(c.maxTimeDiffSeconds, 0);
    });

    test('setTimezone trims and treats blank as cleared', () {
      final c = AppController();
      c.setTimezone('  Europe/Paris  ');
      expect(c.timezone, 'Europe/Paris');
      c.setTimezone('   ');
      expect(c.timezone, isNull);
    });

    test('pickOutDir sets the dir when one is chosen', () async {
      final c = AppController(pickFolder: () async => '/picked');
      await c.pickOutDir();
      expect(c.outDir, '/picked');
    });

    test('pickOutDir is a no-op when the picker is cancelled', () async {
      final c = AppController(pickFolder: () async => null);
      await c.pickOutDir();
      expect(c.outDir, isNull);
    });
  });

  group('input branches', () {
    test('setFormatIncluded toggles every photo of one extension', () {
      final c = AppController()
        ..debugSetSummary(_summaryWith(['/p/a.jpg', '/p/b.jpg', '/p/c.png']));
      c.setFormatIncluded('jpg', false);
      expect(c.isIncluded('/p/a.jpg'), isFalse);
      expect(c.isIncluded('/p/b.jpg'), isFalse);
      expect(c.isIncluded('/p/c.png'), isTrue);
      expect(c.includedPhotos, ['/p/c.png']);

      c.setFormatIncluded('jpg', true);
      expect(c.includedCount, 3);
    });
  });

  group('checkEnvironment', () {
    test(
      'exiftool failure sets a warning and exiftoolAvailable false',
      () async {
        final c = AppController(
          probeToolkit: () async => [_tool('exiftool', present: false)],
        );
        expect(c.environmentWarning, isNull);

        await c.checkEnvironment();

        expect(c.exiftoolAvailable, isFalse);
        expect(c.environmentWarning, isNotNull);
        expect(c.environmentWarning, contains("ExifTool couldn't start"));
        // A calm note is logged at warning level.
        expect(c.logEntries.any((e) => e.level == LogLevel.warning), isTrue);
      },
    );

    test('exiftool success leaves the warning null', () async {
      final c = AppController(probeToolkit: () async => [_tool('exiftool')]);

      await c.checkEnvironment();

      expect(c.exiftoolAvailable, isTrue);
      expect(c.environmentWarning, isNull);
    });

    test('is idempotent — the probe runs at most once', () async {
      var probes = 0;
      final c = AppController(
        probeToolkit: () async {
          probes++;
          return [_tool('exiftool')];
        },
      );
      await c.checkEnvironment();
      await c.checkEnvironment();
      expect(probes, 1);
    });

    test('dismissWarning hides the banner state', () async {
      final c = AppController(
        probeToolkit: () async => [_tool('exiftool', present: false)],
      );
      await c.checkEnvironment();
      expect(c.warningDismissed, isFalse);

      c.dismissWarning();
      expect(c.warningDismissed, isTrue);
      // The message itself is unchanged; the banner uses the flag to hide.
      expect(c.environmentWarning, isNotNull);
    });

    test('hasBundledExiftool reflects the injected bundle dir', () {
      expect(AppController().hasBundledExiftool, isFalse);
      expect(AppController(exiftoolBundleDir: '/x').hasBundledExiftool, isTrue);
    });
  });

  group('lifecycle', () {
    test('dispose tears down the controller and its mcp service', () {
      final c = AppController(runner: FakeEngineRunner());
      // Should not throw: cancels any subscription and disposes the mcp.
      expect(c.dispose, returnsNormally);
    });
  });
}
