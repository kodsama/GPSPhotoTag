import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true}) => ToolStatus(
  id: id,
  name: id,
  present: present,
  purpose: 'test',
  required: false,
);

void main() {
  group('screen navigation', () {
    test('starts on the welcome screen with no library', () {
      final c = AppController();
      expect(c.screen, AppScreen.welcome);
      expect(c.scan, isNull);
    });

    test('pickLibrary cancelled stays on welcome', () async {
      final c = AppController(
        runner: FakeEngineRunner(),
        pickFolder: () async => null,
      );
      await c.pickLibrary();
      expect(c.screen, AppScreen.welcome);
    });

    test('startScan folds progress then lands on the workspace', () async {
      final c = AppController(
        runner: FakeEngineRunner(
          scanEvents: [
            const ScanProgressEvent(ScanProgress(files: 3, photos: 2)),
            ScanDoneEvent(fakeScan(photos: const ['/library/a.jpg'])),
          ],
        ),
      );
      await c.startScan('/library');
      expect(c.screen, AppScreen.workspace);
      expect(c.scan, isNotNull);
      expect(c.folderName, 'library');
      expect(c.scanProgress, isNull);
    });

    test('openAction moves to the action screen; back returns', () {
      final c = AppController()..debugSetScan(fakeScan());
      c.openAction(LibraryAction.tag);
      expect(c.screen, AppScreen.action);
      expect(c.action, LibraryAction.tag);
      c.backToLibrary();
      expect(c.screen, AppScreen.workspace);
      expect(c.action, isNull);
    });

    test('changeLibrary clears the scan and returns to welcome', () {
      final c = AppController()..debugSetScan(fakeScan());
      c.changeLibrary();
      expect(c.screen, AppScreen.welcome);
      expect(c.scan, isNull);
    });
  });

  group('readiness', () {
    test('tag is blocked without GPS sources, ready with them', () {
      expect(LibraryAction.tag.readiness(fakeScan()).enabled, isFalse);
      final withGpx = fakeScan(gpxFiles: const ['/library/t.gpx']);
      final r = LibraryAction.tag.readiness(withGpx);
      expect(r.enabled, isTrue);
      expect(r.label, contains('1'));
    });

    test('map needs photos', () {
      expect(LibraryAction.map.readiness(fakeScan()).enabled, isTrue);
      expect(
        LibraryAction.map.readiness(fakeScan(photos: const [])).enabled,
        isFalse,
      );
    });

    test('prune-raw needs RAW files', () {
      expect(LibraryAction.pruneRaw.readiness(fakeScan()).enabled, isFalse);
      final raws = fakeScan(photos: const ['/library/x.raf']);
      expect(LibraryAction.pruneRaw.readiness(raws).enabled, isTrue);
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

    test('outputValid needs a destination only when copying', () {
      final c = AppController();
      expect(c.outputValid, isTrue);
      c.setCopyToFolder(true);
      expect(c.outputValid, isFalse);
      c.setOutDir('/out');
      expect(c.outputValid, isTrue);
    });

    test('turning copy-to-folder off clears the chosen outDir', () {
      final c = AppController()
        ..setCopyToFolder(true)
        ..setOutDir('/out');
      expect(c.outDir, '/out');
      c.setCopyToFolder(false);
      expect(c.outDir, isNull);
    });

    test('maxTimeDiff clamps negatives to zero', () {
      final c = AppController()..setMaxTimeDiff(120);
      expect(c.maxTimeDiffSeconds, 120);
      expect(c.buildTagOptions().maxTimeDiff, const Duration(seconds: 120));
      c.setMaxTimeDiff(-5);
      expect(c.maxTimeDiffSeconds, 0);
    });

    test('setTimezone trims and treats blank as cleared', () {
      final c = AppController()..setTimezone('  Europe/Paris  ');
      expect(c.timezone, 'Europe/Paris');
      c.setTimezone('   ');
      expect(c.timezone, isNull);
    });

    test(
      'pickOutDir sets the dir when one is chosen, no-op when cancelled',
      () async {
        final picked = AppController(pickFolder: () async => '/picked');
        await picked.pickOutDir();
        expect(picked.outDir, '/picked');
        final cancelled = AppController(pickFolder: () async => null);
        await cancelled.pickOutDir();
        expect(cancelled.outDir, isNull);
      },
    );
  });

  group('operations', () {
    test('runTag folds events into state and tallies the summary', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)..debugSetScan(fakeScan());
      await c.runTag();
      expect(c.running, isFalse);
      expect(c.lastSummary, {'tagged': 1});
      expect(c.rows, isNotEmpty);
      expect(c.errorMessage, isNull);
      expect(fake.calls, contains('tag'));
    });

    test(
      'runTag passes all scanned GPS source lists into the runner',
      () async {
        final fake = FakeEngineRunner();
        final c = AppController(runner: fake)
          ..debugSetScan(
            fakeScan(
              gpxFiles: const ['/library/a.gpx'],
              kmlFiles: const ['/library/b.kml'],
              googleFiles: const ['/library/Records.json'],
            ),
          );
        await c.runTag();
        expect(fake.calls, contains('tag'));
      },
    );

    test('runTag is a no-op without a scan', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.runTag();
      expect(fake.calls, isEmpty);
    });

    test('dry-run changes the start message', () async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan())
        ..setDryRun(true);
      await c.runTag();
      expect(c.logEntries.any((e) => e.message.contains('Previewing')), isTrue);
    });

    test('an ErrorEvent surfaces as errorMessage and stops the run', () async {
      final c = AppController(
        runner: FakeEngineRunner(events: const [ErrorEvent('nope')]),
      )..debugSetScan(fakeScan());
      await c.runTag();
      expect(c.errorMessage, 'nope');
      expect(c.running, isFalse);
    });

    test('renderMap returns null without a scan, runs with one', () async {
      final noLib = AppController(runner: FakeEngineRunner());
      expect(await noLib.renderMap(), isNull);

      final tmp = Directory.systemTemp.createTempSync('rendermap');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(), folder: tmp.path);
      final path = await c.renderMap(dpi: 300);
      expect(fake.calls, contains('map'));
      expect(path, endsWith('stunda-heatmap.png'));
    });

    test('opening prune classifies the library and pre-selects orphans', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(
            photos: const [
              '/library/a.raf', // orphan
              '/library/b.raf', // paired
              '/library/b.jpg',
              '/library/c.jpg', // photo without raw
            ],
          ),
        )
        ..openAction(LibraryAction.pruneRaw);

      final pairing = c.pairing!;
      expect(pairing.orphanCount, 1);
      expect(pairing.pairedRawCount, 1);
      expect(pairing.photoWithRawCount, 1);
      expect(pairing.photoWithoutRawCount, 1);
      // Orphan pre-selected; the paired RAW is not.
      expect(c.selectedPaths, {'/library/a.raf'});
      expect(c.selectedCount, 1);
    });

    test('opening a non-prune action clears the pairing', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.raf']))
        ..openAction(LibraryAction.pruneRaw);
      expect(c.pairing, isNotNull);
      c.openAction(LibraryAction.map);
      expect(c.pairing, isNull);
    });

    test('filter and kind toggles narrow the review list', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(
            photos: const [
              '/library/orphan.raf',
              '/library/keeper.raf',
              '/library/keeper.jpg',
            ],
          ),
        )
        ..openAction(LibraryAction.pruneRaw);

      // Only orphan RAWs visible by default.
      expect(c.filteredPairing.map((f) => f.path), ['/library/orphan.raf']);

      // Filename filter (case-insensitive) excludes the orphan.
      c.setPruneFilter('KEEP');
      expect(c.filteredPairing, isEmpty);
      c.setPruneFilter('');

      // Show paired RAWs too.
      c.setKindVisible(PairKind.pairedRaw, true);
      expect(
        c.filteredPairing.map((f) => f.path),
        containsAll(['/library/orphan.raf', '/library/keeper.raf']),
      );
      c.setKindVisible(PairKind.orphanRaw, false);
      expect(c.filteredPairing.map((f) => f.path), ['/library/keeper.raf']);
    });

    test('selection toggles and select-all/none', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(photos: const ['/library/x.raf', '/library/y.raf']),
        )
        ..openAction(LibraryAction.pruneRaw);

      expect(c.selectedCount, 2);
      c.selectAllOrphans(false);
      expect(c.selectedCount, 0);
      c.toggleSelected('/library/x.raf', true);
      expect(c.selectedPaths, {'/library/x.raf'});
      c.toggleSelected('/library/x.raf', false);
      expect(c.selectedPaths, isEmpty);
      c.selectAllOrphans(true);
      expect(c.selectedCount, 2);
    });

    test('runTrashSelected sends exactly the selected paths', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/x.raf', '/library/y.raf']),
        )
        ..openAction(LibraryAction.pruneRaw);

      c
        ..selectAllOrphans(false)
        ..toggleSelected('/library/x.raf', true);
      await c.runTrashSelected();

      expect(fake.calls, contains('trashPaths'));
      expect(fake.lastTrashedPaths, ['/library/x.raf']);
    });

    test('runTrashSelected with nothing selected is a no-op', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/library/x.raf']))
        ..openAction(LibraryAction.pruneRaw)
        ..selectAllOrphans(false);
      await c.runTrashSelected();
      expect(fake.calls, isEmpty);
    });

    test(
      'a stream-level error surfaces as errorMessage and ends the run',
      () async {
        final c = AppController(runner: ThrowingEngineRunner())
          ..debugSetScan(fakeScan());
        await c.runTag();
        expect(c.errorMessage, contains('stream blew up'));
        expect(c.running, isFalse);
        expect(c.logEntries.any((e) => e.level == LogLevel.error), isTrue);
      },
    );

    test('a scan stream error is logged and stays calm', () async {
      final c = AppController(runner: ThrowingEngineRunner());
      await c.startScan('/library');
      expect(c.logEntries.any((e) => e.level == LogLevel.error), isTrue);
    });
  });

  group('activity log', () {
    test('debug log entries raise the unread count; markLogRead clears it', () {
      final c = AppController()
        ..debugAddLog('hello')
        ..debugAddLog('world', level: LogLevel.error);
      expect(c.unreadCount, 2);
      expect(c.logEntries.length, 2);
      c.markLogRead();
      expect(c.unreadCount, 0);
    });
  });

  group('theme', () {
    test('setDark flips relative to the displayed brightness', () {
      final c = AppController();
      expect(c.themeMode, ThemeMode.system);
      c.setDark(false);
      expect(c.themeMode, ThemeMode.light);
      c.setDark(true);
      expect(c.themeMode, ThemeMode.dark);
      c.setDark(true);
      expect(c.themeMode, ThemeMode.dark);
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
        expect(c.environmentWarning, contains("ExifTool couldn't start"));
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
      expect(c.dispose, returnsNormally);
    });
  });
}
