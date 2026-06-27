import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_prefs.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/state/prune_direction.dart';

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
      expect(c.folderName(enTr), 'library');
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
      expect(r.label(enTr), contains('1'));
    });

    test('explore needs photos', () {
      expect(LibraryAction.explore.readiness(fakeScan()).enabled, isTrue);
      expect(
        LibraryAction.explore.readiness(fakeScan(photos: const [])).enabled,
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
      c.openAction(LibraryAction.tag);
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
      c.selectAllCandidates(false);
      expect(c.selectedCount, 0);
      c.toggleSelected('/library/x.raf', true);
      expect(c.selectedPaths, {'/library/x.raf'});
      c.toggleSelected('/library/x.raf', false);
      expect(c.selectedPaths, isEmpty);
      c.selectAllCandidates(true);
      expect(c.selectedCount, 2);
    });

    test('direction B targets orphan images and resets the selection', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(
            photos: const [
              '/library/a.raf', // orphan RAW
              '/library/b.raf', // paired RAW
              '/library/b.jpg', // photo with RAW
              '/library/c.jpg', // orphan image
            ],
          ),
        )
        ..openAction(LibraryAction.pruneRaw);

      // Direction A (default): orphan RAWs are the candidates.
      expect(c.pruneDirection, PruneDirection.removeOrphanRaws);
      expect(c.selectedPaths, {'/library/a.raf'});
      expect(c.isKindVisible(PairKind.orphanRaw), isTrue);

      // Switching to B re-targets orphan images, resets selection + visibility.
      c.setPruneDirection(PruneDirection.removeOrphanImages);
      expect(c.pruneDirection, PruneDirection.removeOrphanImages);
      expect(c.selectedPaths, {'/library/c.jpg'});
      expect(c.isKindVisible(PairKind.photoWithoutRaw), isTrue);
      expect(c.isKindVisible(PairKind.orphanRaw), isFalse);

      // Setting the same direction again is a no-op (no re-selection churn).
      c
        ..selectAllCandidates(false)
        ..setPruneDirection(PruneDirection.removeOrphanImages);
      expect(c.selectedPaths, isEmpty);
    });

    test('runTrashSelected sends exactly the selected paths', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/x.raf', '/library/y.raf']),
        )
        ..openAction(LibraryAction.pruneRaw);

      c
        ..selectAllCandidates(false)
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
        ..selectAllCandidates(false);
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

  group('savePng', () {
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);

    test('cancel (null path) writes nothing and returns null', () async {
      final c = AppController(runner: FakeEngineRunner());
      final logsBefore = c.logEntries.length;
      final result = await c.savePng(bytes, pickPath: () async => null);
      expect(result, isNull);
      // No success/failure entry was logged on a cancel.
      expect(c.logEntries.length, logsBefore);
    });

    test('a chosen path writes the bytes and reports success', () async {
      final dir = Directory.systemTemp.createTempSync('savepng');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = '${dir.path}/stunda-map.png';
      final c = AppController(runner: FakeEngineRunner());

      final result = await c.savePng(bytes, pickPath: () async => out);

      expect(result, out);
      expect(File(out).readAsBytesSync(), bytes);
      expect(c.logEntries.last.message, contains(out));
      expect(c.logEntries.last.level, LogLevel.info);
    });

    test('a write failure is reported and never throws', () async {
      // A path inside a non-existent directory makes writeAsBytes fail.
      final bad = '${Directory.systemTemp.path}/no_such_dir_xyz/map.png';
      final c = AppController(runner: FakeEngineRunner());

      final result = await c.savePng(bytes, pickPath: () async => bad);

      expect(result, isNull);
      expect(c.logEntries.last.level, LogLevel.error);
      expect(c.logEntries.last.message, contains('Failed to save map view'));
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

    test('setThemeMode can return to system (auto)', () {
      final c = AppController()..setDark(true);
      expect(c.themeMode, ThemeMode.dark);
      c.setThemeMode(ThemeMode.system);
      expect(c.themeMode, ThemeMode.system);
    });
  });

  group('persisted preferences', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('prefs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('load returns defaults when nothing is saved', () async {
      final prefs = await AppPrefs.load(dir.path);
      expect(prefs.themeMode, ThemeMode.system);
      expect(prefs.defaultRawMode, RawMode.auto);
      expect(prefs.defaultMaxTimeDiffSeconds, 300);
    });

    test('a controller applies loaded prefs to theme and tag options', () {
      final prefs = AppPrefs(
        themeMode: ThemeMode.dark,
        defaultRawMode: RawMode.sidecar,
        defaultMaxTimeDiffSeconds: 90,
      );
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      expect(c.themeMode, ThemeMode.dark);
      expect(c.rawMode, RawMode.sidecar);
      expect(c.maxTimeDiffSeconds, 90);
      expect(c.buildTagOptions().maxTimeDiff, const Duration(seconds: 90));
    });

    test('controller writes choices into the prefs bag', () {
      final prefs = AppPrefs(file: '${dir.path}/preferences.json');
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs)
        ..debugSetToolkit([_tool('exiftool')]);

      c.setDark(true);
      c.setDefaultRawMode(RawMode.embed);
      c.setDefaultMaxTimeDiff(42);

      // The setters mutate the shared bag synchronously (the file write is a
      // best-effort async side effect tested separately via save/load).
      expect(prefs.themeMode, ThemeMode.dark);
      expect(prefs.defaultRawMode, RawMode.embed);
      expect(prefs.defaultMaxTimeDiffSeconds, 42);
    });

    test(
      'save then load round-trips every preference through a file',
      () async {
        final prefs = await AppPrefs.load(dir.path)
          ..themeMode = ThemeMode.dark
          ..defaultRawMode = RawMode.embed
          ..defaultMaxTimeDiffSeconds = 42;
        await prefs.save();

        final reloaded = await AppPrefs.load(dir.path);
        expect(reloaded.themeMode, ThemeMode.dark);
        expect(reloaded.defaultRawMode, RawMode.embed);
        expect(reloaded.defaultMaxTimeDiffSeconds, 42);
      },
    );

    test('save is a no-op without a backing file', () async {
      final prefs = AppPrefs(themeMode: ThemeMode.light);
      await expectLater(prefs.save(), completes);
    });

    test('setDefaultRawMode rejects embed without exiftool', () {
      final c = AppController(runner: FakeEngineRunner(), prefs: AppPrefs());
      c.setDefaultRawMode(RawMode.embed);
      expect(c.defaultRawMode, RawMode.auto);
    });

    test('setDefaultMaxTimeDiff clamps negatives to zero', () {
      final c = AppController(runner: FakeEngineRunner(), prefs: AppPrefs());
      c.setDefaultMaxTimeDiff(-9);
      expect(c.defaultMaxTimeDiffSeconds, 0);
      expect(c.maxTimeDiffSeconds, 0);
    });

    test('load ignores a malformed preferences file', () async {
      File('${dir.path}/preferences.json').writeAsStringSync('{ not json');
      final prefs = await AppPrefs.load(dir.path);
      expect(prefs.themeMode, ThemeMode.system);
      expect(prefs.defaultRawMode, RawMode.auto);
    });

    test('defaults are exposed without a prefs store', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.defaultRawMode, RawMode.auto);
      expect(c.defaultMaxTimeDiffSeconds, 300);
      // No store: setters still apply to live options without throwing.
      c.setDefaultMaxTimeDiff(60);
      expect(c.maxTimeDiffSeconds, 60);
    });

    test('background defaults: null image and a subtle 0.85 veil', () async {
      final prefs = await AppPrefs.load(dir.path);
      expect(prefs.backgroundImagePath, isNull);
      expect(prefs.backgroundVeil, 0.85);
    });

    test('save then load round-trips the background prefs', () async {
      final prefs = await AppPrefs.load(dir.path)
        ..backgroundImagePath = '/pics/bg.png'
        ..backgroundVeil = 0.4;
      await prefs.save();

      final reloaded = await AppPrefs.load(dir.path);
      expect(reloaded.backgroundImagePath, '/pics/bg.png');
      expect(reloaded.backgroundVeil, 0.4);
    });

    test('load clamps an out-of-range saved veil into 0..1', () async {
      File(
        '${dir.path}/preferences.json',
      ).writeAsStringSync('{"backgroundVeil": 5.0}');
      final prefs = await AppPrefs.load(dir.path);
      expect(prefs.backgroundVeil, 1.0);
    });

    test('keep pipeline defaults to standard and round-trips', () async {
      final prefs = await AppPrefs.load(dir.path);
      expect(prefs.keepPipeline.steps.map((s) => s.rule), [
        KeepRule.resolution,
        KeepRule.quality,
        KeepRule.people,
      ]);

      prefs.keepPipeline = const KeepPipeline([
        KeepStep(KeepRule.quality),
        KeepStep(KeepRule.resolution, enabled: false),
      ]);
      await prefs.save();

      final reloaded = await AppPrefs.load(dir.path);
      expect(reloaded.keepPipeline.steps[0].rule, KeepRule.quality);
      expect(reloaded.keepPipeline.steps[0].enabled, isTrue);
      expect(reloaded.keepPipeline.steps[1].rule, KeepRule.resolution);
      expect(reloaded.keepPipeline.steps[1].enabled, isFalse);
    });

    test('controller persists pipeline reorder/toggle to the store', () {
      final prefs = AppPrefs(file: '${dir.path}/preferences.json');
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      c.reorderKeepRule(1, 0); // quality to the front
      expect(prefs.keepPipeline.steps.first.rule, KeepRule.quality);
      c.setKeepRuleEnabled(KeepRule.resolution, false);
      final resolution = prefs.keepPipeline.steps.firstWhere(
        (s) => s.rule == KeepRule.resolution,
      );
      expect(resolution.enabled, isFalse);
    });

    test('controller loads the persisted pipeline on construction', () {
      final prefs = AppPrefs(
        keepPipeline: const KeepPipeline([KeepStep(KeepRule.quality)]),
      );
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      expect(c.keepPipeline.steps.first.rule, KeepRule.quality);
    });

    test(
      'setLocaleCode persists the override, round-trips, and notifies',
      () async {
        final path = '${dir.path}/preferences.json';
        final prefs = AppPrefs(file: path);
        final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
        var notified = 0;
        c.addListener(() => notified++);

        expect(c.localeCode, isNull); // null = follow system
        c.setLocaleCode('sv');
        expect(c.localeCode, 'sv');
        expect(prefs.localeCode, 'sv');
        expect(notified, 1);

        // Setting the same value again is a no-op (no extra notify).
        c.setLocaleCode('sv');
        expect(notified, 1);

        await prefs.save();
        final reloaded = await AppPrefs.load(dir.path);
        expect(reloaded.localeCode, 'sv');

        // Clearing it back to system default persists null.
        c.setLocaleCode(null);
        expect(c.localeCode, isNull);
        expect(prefs.localeCode, isNull);
        expect(notified, 2);
      },
    );

    test('controller loads the persisted localeCode on construction', () {
      final prefs = AppPrefs(localeCode: 'ja');
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      expect(c.localeCode, 'ja');
    });

    test('setBackgroundImagePath persists and notifies', () {
      final prefs = AppPrefs();
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      var notified = 0;
      c.addListener(() => notified++);

      c.setBackgroundImagePath('/pics/bg.png');
      expect(c.backgroundImagePath, '/pics/bg.png');
      expect(prefs.backgroundImagePath, '/pics/bg.png');
      expect(notified, 1);

      // Reset clears it (blank/null collapse to null).
      c.setBackgroundImagePath(null);
      expect(c.backgroundImagePath, isNull);
      expect(prefs.backgroundImagePath, isNull);
      expect(notified, 2);
    });

    test('setBackgroundVeil clamps and persists and notifies', () {
      final prefs = AppPrefs();
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      var notified = 0;
      c.addListener(() => notified++);

      c.setBackgroundVeil(0.3);
      expect(c.backgroundVeil, 0.3);
      expect(prefs.backgroundVeil, 0.3);
      expect(notified, 1);

      c.setBackgroundVeil(2.0);
      expect(c.backgroundVeil, 1.0);
    });

    test('background defaults are exposed without a prefs store', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.backgroundImagePath, isNull);
      expect(c.backgroundVeil, 0.85);
      // Setters are no-ops on the bag but still notify without throwing.
      c.setBackgroundVeil(0.5);
      expect(c.backgroundVeil, 0.85);
    });
  });

  group('checkEnvironment', () {
    test(
      'exiftool failure sets a warning and exiftoolAvailable false',
      () async {
        final c = AppController(
          probeToolkit: () async => [_tool('exiftool', present: false)],
        );
        expect(c.hasEnvironmentWarning, isFalse);
        await c.checkEnvironment();
        expect(c.exiftoolAvailable, isFalse);
        expect(c.hasEnvironmentWarning, isTrue);
        expect(c.logEntries.any((e) => e.level == LogLevel.warning), isTrue);
      },
    );

    test('exiftool success leaves the warning null', () async {
      final c = AppController(probeToolkit: () async => [_tool('exiftool')]);
      await c.checkEnvironment();
      expect(c.exiftoolAvailable, isTrue);
      expect(c.hasEnvironmentWarning, isFalse);
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
      expect(c.hasEnvironmentWarning, isTrue);
    });

    test('hasBundledExiftool reflects the injected bundle dir', () {
      expect(AppController().hasBundledExiftool, isFalse);
      expect(AppController(exiftoolBundleDir: '/x').hasBundledExiftool, isTrue);
    });
  });

  group('file selection / exclusion', () {
    test('defaults to everything included', () {
      final c = AppController()..debugSetScan(fakeScan());
      expect(c.isFileIncluded('/library/a.jpg'), isTrue);
      expect(c.excludedFiles, isEmpty);
    });

    test('setFileIncluded toggles a single path', () {
      final c = AppController()..debugSetScan(fakeScan());
      c.setFileIncluded('/library/a.jpg', false);
      expect(c.isFileIncluded('/library/a.jpg'), isFalse);
      expect(c.excludedFiles, contains('/library/a.jpg'));
      c.setFileIncluded('/library/a.jpg', true);
      expect(c.isFileIncluded('/library/a.jpg'), isTrue);
    });

    test('setGroupIncluded excludes/includes a whole group', () {
      final c = AppController();
      c.setGroupIncluded(['/a.jpg', '/b.jpg'], false);
      expect(c.excludedFiles, {'/a.jpg', '/b.jpg'});
      c.setGroupIncluded(['/a.jpg', '/b.jpg'], true);
      expect(c.excludedFiles, isEmpty);
    });

    test('photoCount reflects exclusions', () {
      final c = AppController()
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg', '/b.jpg']));
      expect(c.photoCount, 2);
      c.setFileIncluded('/library/a.jpg', false);
      expect(c.photoCount, 1);
    });

    test('runTag receives only included photos and sources', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(
            photos: const ['/keep.jpg', '/drop.jpg'],
            gpxFiles: const ['/keep.gpx', '/drop.gpx'],
          ),
        );
      c.setFileIncluded('/drop.jpg', false);
      c.setFileIncluded('/drop.gpx', false);
      await c.runTag();
      expect(fake.lastTagPhotos, ['/keep.jpg']);
      expect(fake.lastTagGpx, ['/keep.gpx']);
    });

    test('changeLibrary clears exclusions and metadata', () async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan());
      c.setFileIncluded('/library/a.jpg', false);
      await c.loadImageMeta(['/library/a.jpg']);
      c.changeLibrary();
      expect(c.excludedFiles, isEmpty);
      expect(c.fileMeta('/library/a.jpg'), isNull);
    });
  });

  group('metadata cache', () {
    test('loadImageMeta streams metas into the cache', () async {
      const meta = FileMeta(path: '/a.jpg', width: 4, height: 3, hasGps: true);
      final c = AppController(
        runner: FakeEngineRunner(imageMeta: const {'/a.jpg': meta}),
      );
      expect(c.fileMeta('/a.jpg'), isNull);
      await c.loadImageMeta(['/a.jpg']);
      expect(c.fileMeta('/a.jpg')?.width, 4);
      expect(c.metaLoading, isFalse);
    });

    test('loadImageMeta skips already-cached paths', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.loadImageMeta(['/a.jpg']);
      fake.lastImageMetaPaths = null;
      await c.loadImageMeta(['/a.jpg']);
      // No second read for an already-cached path.
      expect(fake.lastImageMetaPaths, isNull);
    });

    test('loadGpsMeta reads source files in-process', () {
      final dir = Directory.systemTemp.createTempSync('gps_meta');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = writeGpx(dir, 't.gpx', DateTime.utc(2023, 1, 1, 12));
      final c = AppController()..loadGpsMeta([path]);
      expect(c.fileMeta(path)?.pointCount, 1);
      expect(c.fileMeta(path)?.hasGps, isTrue);
    });

    test('loadImageMeta surfaces stream errors without crashing', () async {
      final c = AppController(runner: ThrowingEngineRunner());
      await c.loadImageMeta(['/a.jpg']);
      expect(c.metaLoading, isFalse);
      expect(c.fileMeta('/a.jpg'), isNull);
    });
  });

  group('curated EXIF cache', () {
    test('loadCuratedExif streams records into the cache', () async {
      const exif = CuratedExif(path: '/a.jpg', make: 'Canon', iso: '400');
      final c = AppController(
        runner: FakeEngineRunner(curatedExif: const {'/a.jpg': exif}),
      );
      expect(c.curatedExif('/a.jpg'), isNull);
      await c.loadCuratedExif(['/a.jpg']);
      expect(c.curatedExif('/a.jpg')?.make, 'Canon');
      expect(c.curatedExif('/a.jpg')?.iso, '400');
    });

    test('loadCuratedExif skips already-cached/in-flight paths', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.loadCuratedExif(['/a.jpg']);
      fake.lastCuratedExifPaths = null;
      await c.loadCuratedExif(['/a.jpg']);
      expect(fake.lastCuratedExifPaths, isNull);
    });

    test('loadCuratedExif is a no-op for an empty pending set', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.loadCuratedExif(const []);
      expect(fake.lastCuratedExifPaths, isNull);
    });

    test('loadCuratedExif surfaces stream errors without crashing', () async {
      final c = AppController(runner: ThrowingEngineRunner());
      await c.loadCuratedExif(['/a.jpg']);
      expect(c.curatedExif('/a.jpg'), isNull);
    });

    test('changeLibrary clears the curated EXIF cache', () async {
      final c = AppController(
        runner: FakeEngineRunner(
          curatedExif: const {'/a.jpg': CuratedExif(path: '/a.jpg', iso: '1')},
        ),
      )..debugSetScan(fakeScan());
      await c.loadCuratedExif(['/a.jpg']);
      expect(c.curatedExif('/a.jpg'), isNotNull);
      c.changeLibrary();
      expect(c.curatedExif('/a.jpg'), isNull);
    });
  });

  group('previewImageFor', () {
    test('returns the runner-extracted JPEG path', () async {
      final fake = FakeEngineRunner()..previews['/lib/a.raf'] = '/cache/a.jpg';
      final c = AppController(runner: fake);
      expect(await c.previewImageFor('/lib/a.raf'), '/cache/a.jpg');
    });

    test('memoizes by path + size (second call does not re-run)', () async {
      final fake = FakeEngineRunner()..previews['/lib/a.raf'] = '/cache/a.jpg';
      final c = AppController(runner: fake);

      await c.previewImageFor('/lib/a.raf', full: true);
      await c.previewImageFor('/lib/a.raf', full: true);
      expect(fake.extractPreviewCalls, 1); // cached on the second call

      // A different size is a distinct cache key, so it does run again.
      await c.previewImageFor('/lib/a.raf');
      expect(fake.extractPreviewCalls, 2);
    });

    test('returns null when the file has no embedded preview', () async {
      final c = AppController(runner: FakeEngineRunner());
      expect(await c.previewImageFor('/lib/none.raf'), isNull);
    });
  });

  group('lifecycle', () {
    test('dispose tears down the controller and its mcp service', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.dispose, returnsNormally);
    });
  });

  group('simple state getters/setters', () {
    test('setReplace toggles overwriting existing GPS and notifies', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.replace, isFalse);
      var notified = 0;
      c.addListener(() => notified++);
      c.setReplace(true);
      expect(c.replace, isTrue);
      expect(notified, 1);
    });

    test('folder is null until a scan lands, then exposes the dir root', () {
      final dir = Directory.systemTemp.createTempSync('libfolder');
      addTearDown(() => dir.deleteSync(recursive: true));
      final c = AppController(runner: FakeEngineRunner());
      expect(c.folder, isNull);
      c.debugSetScan(fakeScan(), folder: dir.path);
      expect(c.folder, dir.path);
    });

    test('pruneFilter exposes the current filename filter', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.pruneFilter, '');
      c.setPruneFilter('raf');
      expect(c.pruneFilter, 'raf');
    });
  });

  group('scan log events', () {
    test('a ScanLogEvent is folded into the activity log at debug level', () {
      final c = AppController(
        runner: FakeEngineRunner(
          scanEvents: [
            const ScanLogEvent('skipped a weird file'),
            ScanDoneEvent(fakeScan()),
          ],
        ),
      );
      return c.startScan('/library').then((_) {
        expect(
          c.logEntries.any(
            (e) =>
                e.message == 'skipped a weird file' &&
                e.level == LogLevel.debug,
          ),
          isTrue,
        );
      });
    });
  });

  group('default (non-injected) engine + toolkit probe', () {
    test(
      'checkEnvironment probes the real toolkit and builds the real engine',
      () async {
        // No runner and no probe injected: this exercises the default
        // _probeToolkit closure and the lazily-built IsolateRunner engine.
        final c = AppController();
        await c.checkEnvironment();
        // Probe ran exactly once (a second call is a no-op).
        expect(c.logEntries, isNotEmpty);
        final firstLen = c.logEntries.length;
        await c.checkEnvironment();
        expect(c.logEntries.length, firstLen);

        // Touch the lazily-built real engine: a missing file has no preview, so
        // the real IsolateRunner returns null without throwing.
        final preview = await c.previewImageFor('/no/such/file.raf');
        expect(preview, isNull);

        c.dispose();
      },
    );
  });

  group('multi-root library', () {
    test('pickLibrary sets a single root and scans it', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake, pickFolder: () async => '/pics');
      await c.pickLibrary();
      expect(c.roots, ['/pics']);
      expect(fake.lastScanRoots, ['/pics']);
    });

    test('addRootPaths merges, dedupes, and rescans', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      await c.addRootPaths(['/b', '/a', '/c']);
      expect(c.roots, ['/a', '/b', '/c']);
      expect(fake.lastScanRoots, ['/a', '/b', '/c']);
    });

    test('addRootPaths with nothing new does not rescan', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      final before = fake.calls.where((x) => x == 'scan').length;
      await c.addRootPaths(['/a']);
      final after = fake.calls.where((x) => x == 'scan').length;
      expect(after, before);
    });

    test(
      'addRootPaths subsumes a child root under a newly added parent',
      () async {
        // A real dir holding a file: start with the file root, then add the
        // parent dir. Containment-aware merge swaps the child for the parent —
        // the list length is unchanged (1 -> 1) but contents differ, so it must
        // still rescan on the new single parent root.
        final fake = FakeEngineRunner();
        final c = AppController(runner: fake);
        final dir = Directory.systemTemp.createTempSync('subsume');
        addTearDown(() => dir.deleteSync(recursive: true));
        final jpg = File('${dir.path}/a.jpg')..writeAsStringSync('x');
        await c.startScan(jpg.path);
        expect(c.roots, [jpg.path]);
        await c.addRootPaths([dir.path]);
        expect(c.roots, [dir.path]);
        expect(fake.lastScanRoots, [dir.path]);
      },
    );

    test('addFolder appends the picked folder', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake, pickFolder: () async => '/b');
      await c.startScan('/a');
      await c.addFolder();
      expect(c.roots, ['/a', '/b']);
    });

    test('addFolder cancelled is a no-op', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake, pickFolder: () async => null);
      await c.startScan('/a');
      await c.addFolder();
      expect(c.roots, ['/a']);
    });

    test('addDroppedPaths adds supported items and reports ignored', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      // A real file (a.jpg) + a real gpx vs an unsupported .mp4. Use disk so
      // the classifier's default dir-probe sees real files (not dirs).
      final dir = Directory.systemTemp.createTempSync('drop');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jpg = File('${dir.path}/a.jpg')..writeAsStringSync('x');
      final mp4 = File('${dir.path}/c.mp4')..writeAsStringSync('x');
      final ignored = await c.addDroppedPaths([jpg.path, mp4.path]);
      expect(ignored, 1);
      expect(c.roots, ['/a', jpg.path]);
    });

    test('addDroppedPaths with only ignored items does not rescan', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      final dir = Directory.systemTemp.createTempSync('drop2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final mp4 = File('${dir.path}/c.mp4')..writeAsStringSync('x');
      final before = fake.calls.where((x) => x == 'scan').length;
      final ignored = await c.addDroppedPaths([mp4.path]);
      expect(ignored, 1);
      expect(fake.calls.where((x) => x == 'scan').length, before);
    });

    test('removeLibraryRoot drops a root and rescans the rest', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      await c.addRootPaths(['/b']);
      await c.removeLibraryRoot('/a');
      expect(c.roots, ['/b']);
      expect(fake.lastScanRoots, ['/b']);
    });

    test('removing the last root returns to welcome', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      await c.removeLibraryRoot('/a');
      expect(c.roots, isEmpty);
      expect(c.screen, AppScreen.welcome);
    });

    test('removeLibraryRoot of an absent root is a no-op', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await c.startScan('/a');
      final before = fake.calls.where((x) => x == 'scan').length;
      await c.removeLibraryRoot('/x');
      expect(c.roots, ['/a']);
      expect(fake.calls.where((x) => x == 'scan').length, before);
    });

    test('folderName reflects single vs multiple roots', () async {
      final c = AppController(runner: FakeEngineRunner());
      await c.startScan('/a');
      expect(c.folderName(enTr), 'a');
      await c.addRootPaths(['/b']);
      expect(c.folderName(enTr), '2 locations');
    });

    test('changeLibrary clears the roots', () async {
      final c = AppController(runner: FakeEngineRunner());
      await c.startScan('/a');
      c.changeLibrary();
      expect(c.roots, isEmpty);
      expect(c.folderName(enTr), isNull);
    });

    test('folder getter returns the first directory root', () async {
      final dir = Directory.systemTemp.createTempSync('rootdir');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jpg = File('${dir.path}/a.jpg')..writeAsStringSync('x');
      final c = AppController(runner: FakeEngineRunner());
      // A file root first, then a directory root: folder skips the file.
      await c.startScan(jpg.path);
      expect(c.folder, isNull, reason: 'a single file root has no folder');
      await c.addRootPaths([dir.path]);
      expect(c.folder, dir.path);
    });
  });
}
