import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/state/shrink_model.dart';

import 'support/fakes.dart';

HashedFile _hf(
  String path, {
  int size = 1000,
  bool isRaw = false,
  double quality = 0.9,
}) => HashedFile(
  path: path,
  hash: 0,
  width: 10,
  height: 10,
  fileSize: size,
  basename: path,
  isRaw: isRaw,
  quality: ImageQuality(
    sharpness: quality,
    contrast: quality,
    colorfulness: quality,
    composite: quality,
  ),
);

void main() {
  test('opening the wizard idle resets to an empty cumulative set', () {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit(const [])
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
    c.openAction(LibraryAction.shrink);
    expect(c.screen, AppScreen.action);
    expect(c.action, LibraryAction.shrink);
    expect(c.shrinkStaged, isEmpty);
    expect(c.shrinkTotal.count, 0);
    for (final s in ShrinkStage.values) {
      expect(c.isShrinkStageIncluded(s), isTrue);
    }
  });

  test(
    'duplicates stage hashes, groups, and stages non-kept members',
    () async {
      final fake = FakeEngineRunner()
        ..duplicateGroups = [
          DuplicateGroup(
            best: _hf('/library/a.jpg', size: 3000),
            duplicates: [_hf('/library/b.jpg', size: 1500)],
          ),
        ];
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
        )
        ..openAction(LibraryAction.shrink);

      await c.runShrinkDuplicates();

      expect(fake.calls, contains('findDuplicates'));
      final outcome = c.shrinkOutcome(ShrinkStage.duplicates)!;
      expect(outcome.added.map((e) => e.path), ['/library/b.jpg']);
      expect(outcome.stageTally.count, 1);
      expect(outcome.stageTally.bytes, 1500);
      expect(c.shrinkTotal.count, 1);
      expect(c.shrinkSelectedPaths, ['/library/b.jpg']);
      expect(c.shrinkBusy, isFalse);
    },
  );

  test(
    'a stage hashing failure surfaces an error and stays not-busy',
    () async {
      final c = AppController(runner: ThrowingEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..openAction(LibraryAction.shrink);

      await c.runShrinkDuplicates();
      expect(c.errorMessage, isNotNull);
      expect(c.shrinkBusy, isFalse);
      expect(c.shrinkStaged, isEmpty);
    },
  );

  test('a low-quality hashing failure surfaces an error', () async {
    final c = AppController(runner: ThrowingEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);

    await c.runShrinkLowQuality();
    expect(c.errorMessage, isNotNull);
    expect(c.shrinkBusy, isFalse);
  });

  test(
    'the duplicates stage forwards hashing progress to the run state',
    () async {
      final gate = Completer<void>();
      final fake = FakeEngineRunner()
        ..duplicatesGate = gate
        ..duplicateGroups = const [];
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
        )
        ..openAction(LibraryAction.shrink);

      final future = c.runShrinkDuplicates();
      // Drive a progress tick while the run is gated.
      fake.lastOnProgress!(1, 2);
      expect(c.hashProgress.done, 1);
      expect(c.hashProgress.total, 2);
      expect(c.runStateFor(LibraryAction.shrink).progress, closeTo(0.5, 1e-9));
      gate.complete();
      await future;
    },
  );

  test(
    'the low-quality stage forwards hashing progress to the run state',
    () async {
      final gate = Completer<void>();
      final fake = FakeEngineRunner()
        ..duplicatesGate = gate
        ..hashedFiles = const [];
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
        )
        ..openAction(LibraryAction.shrink);

      final future = c.runShrinkLowQuality();
      fake.lastOnProgress!(2, 2);
      expect(c.hashProgress.done, 2);
      expect(c.runStateFor(LibraryAction.shrink).progress, closeTo(1.0, 1e-9));
      gate.complete();
      await future;
    },
  );

  test('a cancelled run ignores late progress ticks', () async {
    final gate = Completer<void>();
    final fake = FakeEngineRunner()
      ..duplicatesGate = gate
      ..duplicateGroups = const [];
    final c = AppController(runner: fake)
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);

    final future = c.runShrinkDuplicates();
    c.cancelAction(LibraryAction.shrink);
    // A tick arriving after cancel is ignored (no progress recorded).
    fake.lastOnProgress!(1, 1);
    expect(c.hashProgress.done, 0);
    gate.complete();
    await future;
    expect(c.shrinkStaged, isEmpty);
  });

  test('cancelling a busy hashing stage discards its result', () async {
    final gate = Completer<void>();
    final fake = FakeEngineRunner()
      ..duplicatesGate = gate
      ..duplicateGroups = [
        DuplicateGroup(
          best: _hf('/library/a.jpg'),
          duplicates: [_hf('/library/b.jpg')],
        ),
      ];
    final c = AppController(runner: fake)
      ..debugSetScan(
        fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
      )
      ..openAction(LibraryAction.shrink);

    final future = c.runShrinkDuplicates();
    expect(c.shrinkBusy, isTrue);
    c.cancelAction(LibraryAction.shrink);
    expect(c.shrinkBusy, isFalse);
    gate.complete();
    await future;
    // The cancelled run never folded its groups into the set.
    expect(c.shrinkStaged, isEmpty);
  });

  test(
    'orphans and pairs stages classify on disk and dedup cumulatively',
    () async {
      final dir = await Directory.systemTemp.createTemp('shrink_orph');
      addTearDown(() => dir.deleteSync(recursive: true));
      final onlyRaw = File('${dir.path}/only.raf')..writeAsBytesSync([1, 2, 3]);
      final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1]);
      final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([1, 2]);
      final solo = File('${dir.path}/solo.jpg')..writeAsBytesSync([9]);

      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(
            photos: [onlyRaw.path, pairRaw.path, pairJpg.path, solo.path],
          ),
        )
        ..openAction(LibraryAction.shrink)
        ..setShrinkOrphanRaws(true)
        ..setShrinkOrphanImages(true);

      c.runShrinkOrphans();
      final orph = c.shrinkOutcome(ShrinkStage.orphans)!;
      expect(orph.added.map((e) => e.path).toSet(), {onlyRaw.path, solo.path});
      // Sizes come from disk.
      expect(orph.stageTally.bytes, 3 + 1);

      // Drop the RAW side of the pair.
      c.setShrinkPairDrop(PairDropSide.dropRaw);
      c.runShrinkPairs();
      final pairs = c.shrinkOutcome(ShrinkStage.pairs)!;
      expect(pairs.added.map((e) => e.path), [pairRaw.path]);
      expect(c.shrinkTotal.count, 3);
    },
  );

  test(
    'low-quality stage reuses hashed composite quality below threshold',
    () async {
      final fake = FakeEngineRunner()
        ..hashedFiles = [
          _hf('/library/sharp.jpg', quality: 0.8),
          _hf('/library/blur.jpg', size: 2222, quality: 0.1),
        ];
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/sharp.jpg', '/library/blur.jpg']),
        )
        ..openAction(LibraryAction.shrink)
        ..setShrinkQualityThreshold(0.35);

      await c.runShrinkLowQuality();
      expect(fake.calls, contains('hashFiles'));
      final out = c.shrinkOutcome(ShrinkStage.lowQuality)!;
      expect(out.added.map((e) => e.path), ['/library/blur.jpg']);
      expect(out.stageTally.bytes, 2222);
    },
  );

  test('toggling a stage off rolls its candidates back out of the set', () {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(const [
        ShrinkCandidate(
          path: '/a.jpg',
          reason: ShrinkReason.duplicate,
          sizeBytes: 100,
          hasGps: false,
        ),
        ShrinkCandidate(
          path: '/o.raf',
          reason: ShrinkReason.orphanRaw,
          sizeBytes: 50,
          hasGps: false,
        ),
      ]);
    expect(c.shrinkTotal.count, 2);

    c.setShrinkStageIncluded(ShrinkStage.orphans, false);
    expect(c.shrinkStaged.map((e) => e.path), ['/a.jpg']);
    expect(c.shrinkOutcome(ShrinkStage.orphans), isNull);
    expect(c.shrinkTotal.count, 1);

    // Toggling it back on does not re-add until re-run.
    c.setShrinkStageIncluded(ShrinkStage.orphans, true);
    expect(c.shrinkStaged.map((e) => e.path), ['/a.jpg']);
  });

  test('deselecting a staged file removes it from the trash set', () {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(const [
        ShrinkCandidate(
          path: '/a.jpg',
          reason: ShrinkReason.duplicate,
          sizeBytes: 100,
          hasGps: false,
        ),
      ]);
    expect(c.shrinkSelectedCount, 1);
    c.setShrinkSelected('/a.jpg', false);
    expect(c.isShrinkSelected('/a.jpg'), isFalse);
    expect(c.shrinkSelectedCount, 0);
  });

  test('runTrashShrink trashes exactly the selected paths', () async {
    final fake = FakeEngineRunner(
      events: const [
        DoneEvent({'trashed': 1}),
      ],
    );
    final c = AppController(runner: fake)
      ..debugSeedShrink(const [
        ShrinkCandidate(
          path: '/a.jpg',
          reason: ShrinkReason.duplicate,
          sizeBytes: 1,
          hasGps: false,
        ),
        ShrinkCandidate(
          path: '/b.jpg',
          reason: ShrinkReason.orphanRaw,
          sizeBytes: 1,
          hasGps: false,
        ),
      ]);
    c.setShrinkSelected('/b.jpg', false);

    await c.runTrashShrink();
    expect(fake.calls, contains('trashPaths'));
    expect(fake.lastTrashedPaths, ['/a.jpg']);
    expect(c.lastSummary, {'trashed': 1});
  });

  test('runTrashShrink is a no-op with nothing selected', () async {
    final fake = FakeEngineRunner();
    final c = AppController(runner: fake)
      ..debugSeedShrink(const [
        ShrinkCandidate(
          path: '/a.jpg',
          reason: ShrinkReason.duplicate,
          sizeBytes: 1,
          hasGps: false,
        ),
      ]);
    c.setShrinkSelected('/a.jpg', false);
    await c.runTrashShrink();
    expect(fake.calls, isNot(contains('trashPaths')));
  });

  test('stage runners are no-ops without a scan', () async {
    final c = AppController(runner: FakeEngineRunner());
    await c.runShrinkDuplicates();
    c.runShrinkOrphans();
    c.runShrinkPairs();
    await c.runShrinkLowQuality();
    expect(c.shrinkStaged, isEmpty);
  });
}
