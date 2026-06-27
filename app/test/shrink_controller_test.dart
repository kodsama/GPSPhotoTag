import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/state/prune_direction.dart';
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
    expect(c.shrinkActiveStage, isNull);
    expect(c.inShrinkSession, isFalse);
    for (final s in ShrinkStage.values) {
      expect(c.isShrinkStageIncluded(s), isTrue);
    }
  });

  group('shrink-session navigation', () {
    AppController seeded({List<String>? photos}) =>
        AppController(runner: FakeEngineRunner())
          ..debugSetScan(fakeScan(photos: photos ?? const ['/library/a.jpg']))
          ..openAction(LibraryAction.shrink);

    test('opening a stage enters shrink session for that stage', () {
      final c = seeded();
      c.openShrinkStage(ShrinkStage.duplicates);
      expect(c.shrinkActiveStage, ShrinkStage.duplicates);
      expect(c.inShrinkSession, isTrue);
    });

    test('returning to the wizard leaves the session without adding', () {
      final c = seeded();
      c.openShrinkStage(ShrinkStage.pairs);
      c.returnToShrinkWizard();
      expect(c.shrinkActiveStage, isNull);
      expect(c.inShrinkSession, isFalse);
      expect(c.shrinkStaged, isEmpty);
      expect(c.shrinkOutcome(ShrinkStage.pairs), isNull);
    });

    test('inShrinkSession is false on the standalone duplicates page', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..openAction(LibraryAction.duplicates);
      expect(c.inShrinkSession, isFalse);
    });

    test(
      'adding the duplicates stage folds the selected right-side files',
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
        c.openShrinkStage(ShrinkStage.duplicates);
        // The duplicates page hashes via the shared standalone finder.
        await c.runFindDuplicates();
        expect(fake.calls, contains('findDuplicates'));

        c.addActiveStageToShrinkList();
        expect(c.shrinkActiveStage, isNull);
        final outcome = c.shrinkOutcome(ShrinkStage.duplicates)!;
        expect(outcome.added.map((e) => e.path), ['/library/b.jpg']);
        expect(outcome.stageTally.bytes, 1500);
        expect(c.shrinkSelectedPaths, ['/library/b.jpg']);
      },
    );

    test('adding the duplicates stage with no run adds nothing', () {
      final c = seeded();
      c.openShrinkStage(ShrinkStage.duplicates);
      c.addActiveStageToShrinkList();
      expect(c.shrinkOutcome(ShrinkStage.duplicates)!.added, isEmpty);
      expect(c.shrinkStaged, isEmpty);
    });

    test('opening the orphans stage primes the prune review', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_orph');
      addTearDown(() => dir.deleteSync(recursive: true));
      final onlyRaw = File('${dir.path}/only.raf')..writeAsBytesSync([1, 2, 3]);
      final solo = File('${dir.path}/solo.jpg')..writeAsBytesSync([9]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [onlyRaw.path, solo.path]))
        ..openAction(LibraryAction.shrink);

      c.openShrinkStage(ShrinkStage.orphans);
      // Direction A (orphan RAWs) is pre-selected by the prune review.
      expect(c.pruneDirection, PruneDirection.removeOrphanRaws);
      expect(c.selectedPaths, contains(onlyRaw.path));

      c.addActiveStageToShrinkList();
      final out = c.shrinkOutcome(ShrinkStage.orphans)!;
      expect(out.added.map((e) => e.path), [onlyRaw.path]);
      expect(out.stageTally.bytes, 3);

      // Switching to direction B then opening adds the orphan image instead.
      c.openShrinkStage(ShrinkStage.orphans);
      c.setPruneDirection(PruneDirection.removeOrphanImages);
      c.addActiveStageToShrinkList();
      expect(c.shrinkStaged.map((e) => e.path).toSet(), {
        onlyRaw.path,
        solo.path,
      });
    });

    test('redundant-pairs review selects the drop side and adds it', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_pairs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1, 2]);
      final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([3]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [pairRaw.path, pairJpg.path]))
        ..openAction(LibraryAction.shrink);

      c.openShrinkStage(ShrinkStage.pairs);
      // Default drops the RAW side; the candidate is pre-selected.
      expect(c.shrinkPairCandidates.map((f) => f.path), [pairRaw.path]);
      expect(c.shrinkPairSelectedCount, 1);
      expect(c.isShrinkPairSelected(pairRaw.path), isTrue);

      // Flip to keep the RAW → the photo becomes the candidate.
      c.setShrinkPairDrop(PairDropSide.dropPhoto);
      expect(c.shrinkPairCandidates.map((f) => f.path), [pairJpg.path]);
      expect(c.isShrinkPairSelected(pairJpg.path), isTrue);
      // A redundant set to the same side is a no-op.
      c.setShrinkPairDrop(PairDropSide.dropPhoto);
      expect(c.shrinkPairSelectedCount, 1);

      // Deselect-all then re-select-all.
      c.selectAllShrinkPairs(false);
      expect(c.shrinkPairSelectedCount, 0);
      c.selectAllShrinkPairs(true);
      expect(c.shrinkPairSelectedCount, 1);

      c.addActiveStageToShrinkList();
      final out = c.shrinkOutcome(ShrinkStage.pairs)!;
      expect(out.added.map((e) => e.path), [pairJpg.path]);
      expect(out.added.single.reason, ShrinkReason.redundantJpg);
      expect(out.stageTally.bytes, 1);
    });

    test('shrinkPairPartner resolves the opposite side of a pair', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_partner');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1]);
      final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([2]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [pairRaw.path, pairJpg.path]))
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.pairs);

      // Default drops the RAW → its partner is the kept photo.
      expect(c.shrinkPairPartner(pairRaw.path), pairJpg.path);
      // Flip the drop side → the photo's partner is the kept RAW.
      c.setShrinkPairDrop(PairDropSide.dropPhoto);
      expect(c.shrinkPairPartner(pairJpg.path), pairRaw.path);
      // An unknown path has no partner.
      expect(c.shrinkPairPartner('/library/nope.jpg'), isNull);
    });

    test('shrinkPairPartner is null before a pairing is built', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.shrinkPairPartner('/library/a.jpg'), isNull);
    });

    test('toggling a pair candidate off excludes it on add', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_pairs2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1, 2]);
      final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([3]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [pairRaw.path, pairJpg.path]))
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.pairs);
      c.setShrinkPairSelected(pairRaw.path, false);
      expect(c.isShrinkPairSelected(pairRaw.path), isFalse);
      c.addActiveStageToShrinkList();
      expect(c.shrinkStaged, isEmpty);
    });

    test(
      'low-quality review hashes, filters, and adds below threshold',
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
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.lowQuality);
        c.setShrinkQualityThreshold(0.35);
        await c.runShrinkLowQualityHash();

        expect(fake.calls, contains('hashFiles'));
        expect(c.shrinkLowQReviewed, isTrue);
        expect(c.shrinkLowQCandidates.map((h) => h.path), [
          '/library/blur.jpg',
        ]);
        expect(c.shrinkLowQSelectedCount, 1);

        c.selectAllShrinkLowQ(false);
        expect(c.shrinkLowQSelectedCount, 0);
        c.selectAllShrinkLowQ(true);
        c.setShrinkLowQSelected('/library/blur.jpg', false);
        expect(c.isShrinkLowQSelected('/library/blur.jpg'), isFalse);
        c.setShrinkLowQSelected('/library/blur.jpg', true);

        c.addActiveStageToShrinkList();
        final out = c.shrinkOutcome(ShrinkStage.lowQuality)!;
        expect(out.added.map((e) => e.path), ['/library/blur.jpg']);
        expect(out.stageTally.bytes, 2222);
      },
    );

    test('addActiveStageToShrinkList is a no-op on the wizard hub', () {
      final c = seeded();
      c.addActiveStageToShrinkList();
      expect(c.shrinkStaged, isEmpty);
    });
  });

  test('cross-stage dedup: a path added earlier is not re-added', () async {
    final dir = await Directory.systemTemp.createTemp('shrink_dedup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final raw = File('${dir.path}/only.raf')..writeAsBytesSync([1, 2, 3, 4]);
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: [raw.path]))
      ..openAction(LibraryAction.shrink);

    c.openShrinkStage(ShrinkStage.orphans);
    c.addActiveStageToShrinkList();
    expect(c.shrinkTotal.count, 1);

    // Re-opening orphans and adding again does not double-count the path.
    c.openShrinkStage(ShrinkStage.orphans);
    c.addActiveStageToShrinkList();
    expect(c.shrinkTotal.count, 1);
  });

  test('the running total reflects each stage contribution', () async {
    final dir = await Directory.systemTemp.createTemp('shrink_total');
    addTearDown(() => dir.deleteSync(recursive: true));
    final raw = File('${dir.path}/only.raf')..writeAsBytesSync([1, 2, 3]);
    final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1]);
    final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([1, 2]);
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: [raw.path, pairRaw.path, pairJpg.path]))
      ..openAction(LibraryAction.shrink);

    c.openShrinkStage(ShrinkStage.orphans);
    c.addActiveStageToShrinkList();
    final afterOrphans = c.shrinkTotal;
    expect(afterOrphans.count, 1);
    expect(afterOrphans.bytes, 3);

    c.openShrinkStage(ShrinkStage.pairs);
    c.addActiveStageToShrinkList();
    expect(c.shrinkTotal.count, 2);
    expect(c.shrinkTotal.bytes, 3 + 1);
  });

  test('a low-quality hashing failure surfaces an error', () async {
    final c = AppController(runner: ThrowingEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.lowQuality);
    await c.runShrinkLowQualityHash();
    expect(c.errorMessage, isNotNull);
    expect(c.shrinkBusy, isFalse);
    expect(c.shrinkStaged, isEmpty);
  });

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
      c.openShrinkStage(ShrinkStage.lowQuality);

      final future = c.runShrinkLowQualityHash();
      fake.lastOnProgress!(2, 2);
      expect(c.hashProgress.done, 2);
      expect(c.runStateFor(LibraryAction.shrink).progress, closeTo(1.0, 1e-9));
      gate.complete();
      await future;
    },
  );

  test('cancelling a busy low-quality hash discards its result', () async {
    final gate = Completer<void>();
    final fake = FakeEngineRunner()
      ..duplicatesGate = gate
      ..hashedFiles = [_hf('/library/blur.jpg', quality: 0.1)];
    final c = AppController(runner: fake)
      ..debugSetScan(fakeScan(photos: const ['/library/blur.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.lowQuality);

    final future = c.runShrinkLowQualityHash();
    expect(c.shrinkBusy, isTrue);
    c.cancelAction(LibraryAction.shrink);
    expect(c.shrinkBusy, isFalse);
    // A late tick after cancel is ignored.
    fake.lastOnProgress!(1, 1);
    expect(c.hashProgress.done, 0);
    gate.complete();
    await future;
    expect(c.shrinkLowQReviewed, isFalse);
  });

  test('toggling a stage off rolls its contribution back out', () {
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

    // Toggling it back on does not re-add until re-reviewed.
    c.setShrinkStageIncluded(ShrinkStage.orphans, true);
    expect(c.shrinkStaged.map((e) => e.path), ['/a.jpg']);
    // A redundant toggle to the same value is a no-op.
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

  test('stage runners and navigation are no-ops without a scan', () async {
    final c = AppController(runner: FakeEngineRunner());
    c.openShrinkStage(ShrinkStage.pairs);
    expect(c.shrinkPairCandidates, isEmpty);
    c.openShrinkStage(ShrinkStage.lowQuality);
    await c.runShrinkLowQualityHash();
    expect(c.shrinkStaged, isEmpty);
  });

  test('shrinkSizeOf returns 0 for an unreadable path', () {
    final c = AppController(runner: FakeEngineRunner());
    expect(c.shrinkSizeOf('/no/such/file.jpg'), 0);
  });
}
