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
  width: 10,
  height: 10,
  fileSize: size,
  basename: path,
  isRaw: isRaw,
  quality: ImageQuality(
    sharpness: quality,
    contrast: quality,
    colorfulness: quality,
    exposure: quality,
    composite: quality,
  ),
);

/// A hashed file with EXPLICIT per-component quality, for exercising the
/// per-parameter low-quality filter (where the components must differ).
HashedFile _hfQ(
  String path, {
  int size = 1000,
  double sharpness = 0.9,
  double contrast = 0.9,
  double color = 0.9,
  double exposure = 0.9,
}) => HashedFile(
  path: path,
  width: 10,
  height: 10,
  fileSize: size,
  basename: path,
  isRaw: false,
  quality: ImageQuality(
    sharpness: sharpness,
    contrast: contrast,
    colorfulness: color,
    exposure: exposure,
    composite: (sharpness + contrast + color) / 3,
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

    test(
      'toggling a quality parameter re-filters candidates WITHOUT re-hashing',
      () async {
        // soft.jpg is sharp-bad only; the rest are fine on every component.
        final fake = FakeEngineRunner()
          ..hashedFiles = [
            _hfQ('/library/soft.jpg', sharpness: 0.05),
            _hfQ('/library/good.jpg'),
          ];
        final c = AppController(runner: fake)
          ..debugSetScan(
            fakeScan(photos: const ['/library/soft.jpg', '/library/good.jpg']),
          )
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.lowQuality);
        c.setShrinkQualityThreshold(0.35);
        await c.runShrinkLowQualityHash();
        final hashCalls = fake.calls.where((e) => e == 'hashFiles').length;
        expect(hashCalls, 1);

        // With all params on, the soft photo scores ~ (0.05+0.9+0.9+0.9)/4 ≈ 0.69
        // → above threshold → NOT flagged.
        expect(c.shrinkLowQCandidates, isEmpty);

        // Turn OFF every param except sharpness: now the soft photo is scored on
        // sharpness alone (0.05) → below threshold → flagged. No re-hash.
        c.setLowQParamEnabled(QualityParam.contrast, false);
        c.setLowQParamEnabled(QualityParam.color, false);
        c.setLowQParamEnabled(QualityParam.exposure, false);
        expect(c.shrinkLowQCandidates.map((h) => h.path), [
          '/library/soft.jpg',
        ]);
        // The selection re-syncs to the new candidate set.
        expect(c.isShrinkLowQSelected('/library/soft.jpg'), isTrue);
        // Critically: still only one hash call.
        expect(fake.calls.where((e) => e == 'hashFiles').length, hashCalls);
      },
    );

    test('enabling/disabling reflects in lowQParams + isLowQParamEnabled', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.lowQParams, QualityParam.values.toSet());
      expect(c.isLowQParamEnabled(QualityParam.exposure), isTrue);
      c.setLowQParamEnabled(QualityParam.exposure, false);
      expect(c.isLowQParamEnabled(QualityParam.exposure), isFalse);
      expect(c.lowQParams.contains(QualityParam.exposure), isFalse);
      // A redundant toggle is a no-op (already disabled).
      c.setLowQParamEnabled(QualityParam.exposure, false);
      expect(c.isLowQParamEnabled(QualityParam.exposure), isFalse);
      // Re-enabling it adds it back.
      c.setLowQParamEnabled(QualityParam.exposure, true);
      expect(c.isLowQParamEnabled(QualityParam.exposure), isTrue);
    });

    test(
      'with every parameter off nothing is flagged (safe default)',
      () async {
        final fake = FakeEngineRunner()
          ..hashedFiles = [_hfQ('/library/bad.jpg', sharpness: 0, contrast: 0)];
        final c = AppController(runner: fake)
          ..debugSetScan(fakeScan(photos: const ['/library/bad.jpg']))
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.lowQuality);
        await c.runShrinkLowQualityHash();
        for (final p in QualityParam.values) {
          c.setLowQParamEnabled(p, false);
        }
        expect(c.lowQParams, isEmpty);
        // compositeFrom returns 1.0 for the empty set → above any threshold.
        expect(c.shrinkLowQCandidates, isEmpty);
      },
    );
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

  group('back-target resolution', () {
    test('a standalone action routes back to the library', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..openAction(LibraryAction.duplicates);
      expect(c.backTarget, ShrinkBackTarget.library);
      c.goBackFromAction();
      expect(c.screen, AppScreen.workspace);
      expect(c.action, isNull);
    });

    test('a wizard stage page routes back to the shrink wizard', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.duplicates);
      expect(c.backTarget, ShrinkBackTarget.shrinkWizard);
      c.goBackFromAction();
      // Back lands on the wizard hub, NOT the library.
      expect(c.screen, AppScreen.action);
      expect(c.action, LibraryAction.shrink);
      expect(c.shrinkActiveStage, isNull);
      expect(c.inShrinkSession, isFalse);
      expect(c.backTarget, ShrinkBackTarget.library);
    });
  });

  group('per-stage state cache survives navigation', () {
    test('re-opening duplicates restores pairs without re-running', () async {
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
      await c.runFindDuplicates();
      expect(c.duplicatePairs, isNotNull);
      expect(c.duplicatePairs!.length, 1);
      // Deselect the only pair, then leave to the wizard.
      c.setDuplicateRemoval(0, false);
      c.returnToShrinkWizard();

      final callsBefore = fake.calls.where((e) => e == 'findDuplicates').length;
      // Re-open: the found pairs AND the deselection are restored — no re-hash.
      c.openShrinkStage(ShrinkStage.duplicates);
      expect(c.duplicatePairs, isNotNull);
      expect(c.duplicatePairs!.length, 1);
      expect(c.duplicatePairs!.single.removeSelected, isFalse);
      expect(
        fake.calls.where((e) => e == 'findDuplicates').length,
        callsBefore,
      );
    });

    test(
      're-opening low-quality restores hashed results without re-hashing',
      () async {
        final fake = FakeEngineRunner()
          ..hashedFiles = [_hf('/library/blur.jpg', size: 2222, quality: 0.1)];
        final c = AppController(runner: fake)
          ..debugSetScan(fakeScan(photos: const ['/library/blur.jpg']))
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.lowQuality);
        await c.runShrinkLowQualityHash();
        expect(c.shrinkLowQReviewed, isTrue);
        c.setShrinkLowQSelected('/library/blur.jpg', false);
        c.returnToShrinkWizard();

        final hashCalls = fake.calls.where((e) => e == 'hashFiles').length;
        c.openShrinkStage(ShrinkStage.lowQuality);
        // Reviewed flag, the candidate, and the deselection all survive.
        expect(c.shrinkLowQReviewed, isTrue);
        expect(c.shrinkLowQCandidates.map((h) => h.path), [
          '/library/blur.jpg',
        ]);
        expect(c.isShrinkLowQSelected('/library/blur.jpg'), isFalse);
        expect(fake.calls.where((e) => e == 'hashFiles').length, hashCalls);
      },
    );

    test('re-opening orphans restores the direction and selection', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_cache_orph');
      addTearDown(() => dir.deleteSync(recursive: true));
      final onlyRaw = File('${dir.path}/only.raf')..writeAsBytesSync([1, 2, 3]);
      final solo = File('${dir.path}/solo.jpg')..writeAsBytesSync([9]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [onlyRaw.path, solo.path]))
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.orphans);
      c.setPruneDirection(PruneDirection.removeOrphanImages);
      c.toggleSelected(solo.path, false);
      c.returnToShrinkWizard();

      c.openShrinkStage(ShrinkStage.orphans);
      expect(c.pruneDirection, PruneDirection.removeOrphanImages);
      expect(c.selectedPaths, isEmpty);
    });

    test('re-opening pairs restores the drop side and selection', () async {
      final dir = await Directory.systemTemp.createTemp('shrink_cache_pairs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pairRaw = File('${dir.path}/pair.raf')..writeAsBytesSync([1, 2]);
      final pairJpg = File('${dir.path}/pair.jpg')..writeAsBytesSync([3]);
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: [pairRaw.path, pairJpg.path]))
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.pairs);
      c.setShrinkPairDrop(PairDropSide.dropPhoto);
      c.setShrinkPairSelected(pairJpg.path, false);
      c.returnToShrinkWizard();

      c.openShrinkStage(ShrinkStage.pairs);
      expect(c.shrinkPairDrop, PairDropSide.dropPhoto);
      expect(c.shrinkPairCandidates.map((f) => f.path), [pairJpg.path]);
      expect(c.isShrinkPairSelected(pairJpg.path), isFalse);
    });

    test(
      'adding a stage then re-opening still shows the prior selection',
      () async {
        final fake = FakeEngineRunner()
          ..duplicateGroups = [
            DuplicateGroup(
              best: _hf('/library/a.jpg', size: 3000),
              duplicates: [
                _hf('/library/b.jpg', size: 1500),
                _hf('/library/c.jpg', size: 1200),
              ],
            ),
          ];
        final c = AppController(runner: fake)
          ..debugSetScan(
            fakeScan(
              photos: const [
                '/library/a.jpg',
                '/library/b.jpg',
                '/library/c.jpg',
              ],
            ),
          )
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.duplicates);
        await c.runFindDuplicates();
        // Deselect one of the two pairs, then commit to the shrink list.
        c.setDuplicateRemoval(1, false);
        c.addActiveStageToShrinkList();
        expect(c.shrinkActiveStage, isNull);

        // Re-open after adding: the pairs and the deselection are restored.
        c.openShrinkStage(ShrinkStage.duplicates);
        expect(c.duplicatePairs!.length, 2);
        expect(c.duplicatePairs![1].removeSelected, isFalse);
      },
    );
  });

  group('per-stage Clear', () {
    test('clears only that stage from the staged set and total', () {
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
      expect(c.shrinkOutcome(ShrinkStage.duplicates), isNotNull);

      c.clearShrinkStage(ShrinkStage.orphans);
      // Only the orphan stage's file leaves; the duplicate stays.
      expect(c.shrinkStaged.map((e) => e.path), ['/a.jpg']);
      expect(c.shrinkOutcome(ShrinkStage.orphans), isNull);
      expect(c.shrinkOutcome(ShrinkStage.duplicates), isNotNull);
      expect(c.shrinkTotal.count, 1);
      expect(c.shrinkTotal.bytes, 100);
    });

    test(
      'Clear resets the cleared stage cache so re-open primes fresh',
      () async {
        final dir = await Directory.systemTemp.createTemp('shrink_clear_cache');
        addTearDown(() => dir.deleteSync(recursive: true));
        final onlyRaw = File('${dir.path}/only.raf')
          ..writeAsBytesSync([1, 2, 3]);
        final c = AppController(runner: FakeEngineRunner())
          ..debugSetScan(fakeScan(photos: [onlyRaw.path]))
          ..openAction(LibraryAction.shrink);
        c.openShrinkStage(ShrinkStage.orphans);
        // Deselect everything, then add (an empty contribution) so a cache exists.
        c.toggleSelected(onlyRaw.path, false);
        c.addActiveStageToShrinkList();
        expect(c.selectedPaths, isEmpty);

        c.clearShrinkStage(ShrinkStage.orphans);
        // Re-opening primes fresh: the orphan RAW is selected again by default.
        c.openShrinkStage(ShrinkStage.orphans);
        expect(c.selectedPaths, contains(onlyRaw.path));
      },
    );
  });
}
