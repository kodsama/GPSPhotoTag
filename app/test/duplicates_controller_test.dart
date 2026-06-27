import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/duplicates_model.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

HashedFile _hf(
  String path, {
  int width = 100,
  int height = 100,
  int size = 10,
  double quality = 0.5,
}) => HashedFile(
  path: path,
  hash: 0,
  width: width,
  height: height,
  fileSize: size,
  basename: path,
  isRaw: false,
  quality: ImageQuality(
    sharpness: quality,
    contrast: quality,
    colorfulness: quality,
    composite: quality,
  ),
);

void main() {
  group('runFindDuplicates', () {
    test(
      'hashes included photos at the mapped threshold and builds pairs',
      () async {
        final fake = FakeEngineRunner()
          ..duplicateGroups = [
            DuplicateGroup(
              best: _hf('/best.jpg', width: 200, height: 200),
              duplicates: [_hf('/dup.jpg')],
            ),
          ];
        final c = AppController(runner: fake)
          ..debugSetScan(
            fakeScan(photos: const ['/best.jpg', '/dup.jpg', '/x.jpg']),
          );
        c.openAction(LibraryAction.duplicates);
        c.setSimilarity(4);
        c.setFileIncluded('/x.jpg', false); // exclude one

        await c.runFindDuplicates();

        expect(fake.lastDuplicateThreshold, similarityToThreshold(4));
        expect(fake.lastDuplicatePaths, ['/best.jpg', '/dup.jpg']);
        expect(c.duplicatePairs, hasLength(1));
        expect(c.duplicatePairs!.single.kept.path, '/best.jpg');
        expect(c.duplicateRemovalCount, 1);
        expect(c.findingDuplicates, isFalse);
      },
    );

    test('a thrown engine error surfaces and leaves an empty result', () async {
      final c = AppController(runner: ThrowingEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/a.jpg', '/b.jpg']));
      c.openAction(LibraryAction.duplicates);

      await c.runFindDuplicates();

      expect(c.errorMessage, isNotNull);
      expect(c.duplicatePairs, isEmpty);
      expect(c.findingDuplicates, isFalse);
    });

    test('is a no-op without a scan', () async {
      final c = AppController(runner: FakeEngineRunner());
      await c.runFindDuplicates();
      expect(c.duplicatePairs, isNull);
    });

    test('folds worker progress ticks into live hashed/total state', () async {
      final fake = FakeEngineRunner()..duplicatesGate = Completer<void>();
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/a.jpg', '/b.jpg', '/c.jpg']));
      c.openAction(LibraryAction.duplicates);

      final run = c.runFindDuplicates();
      // Total is known immediately once a run starts; nothing hashed yet.
      expect(c.duplicatesTotal, 3);
      expect(c.duplicatesHashed, 0);
      expect(c.hashProgress.fraction, 0);

      // Ticks accumulate into the done count and the fraction.
      fake.lastOnProgress!(1, 3);
      expect(c.duplicatesHashed, 1);
      fake.lastOnProgress!(2, 3);
      expect(c.duplicatesHashed, 2);
      expect(c.hashProgress.fraction, closeTo(2 / 3, 1e-9));
      expect(
        enTr('hashing_progress', {
          'done': c.hashProgress.groupedDone,
          'total': c.hashProgress.groupedTotal,
        }),
        'Hashing 2 / 3',
      );

      fake.duplicatesGate!.complete();
      await run;
      // Reset when the run finishes.
      expect(c.duplicatesTotal, 0);
      expect(c.duplicatesHashed, 0);
    });
  });

  group('similarity slider', () {
    test('clamps and notifies only on change', () {
      final c = AppController(runner: FakeEngineRunner());
      var notifies = 0;
      c.addListener(() => notifies++);
      c.setSimilarity(3);
      c.setSimilarity(3); // no change → no notify
      c.setSimilarity(999); // clamps to max
      expect(c.similarity, similaritySteps);
      expect(notifies, 2);
    });
  });

  group('review interactions', () {
    test('deselect drops a pair from the removal set', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetDuplicatePairs([
          DuplicatePair(kept: _hf('/k'), other: _hf('/r')),
        ]);
      expect(c.duplicateRemovalCount, 1);
      c.setDuplicateRemoval(0, false);
      expect(c.duplicateRemovalPaths, isEmpty);
    });

    test('swap flips which side is kept', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetDuplicatePairs([
          DuplicatePair(kept: _hf('/k'), other: _hf('/r')),
        ]);
      c.swapDuplicatePair(0);
      final pair = c.duplicatePairs!.single;
      expect(pair.kept.path, '/r');
      expect(pair.other.path, '/k');
      // The removal target follows to the new right side.
      expect(c.duplicateRemovalPaths, ['/k']);
    });

    test('out-of-range index is ignored', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetDuplicatePairs([
          DuplicatePair(kept: _hf('/k'), other: _hf('/r')),
        ]);
      c.setDuplicateRemoval(5, false);
      c.swapDuplicatePair(-1);
      expect(c.duplicateRemovalCount, 1); // unchanged
    });

    test('interactions before a run are safe no-ops', () {
      final c = AppController(runner: FakeEngineRunner());
      c.setDuplicateRemoval(0, false);
      c.swapDuplicatePair(0);
      expect(c.duplicateRemovalPaths, isEmpty);
    });
  });

  group('keep pipeline', () {
    test('defaults to the standard pipeline', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.keepPipeline.steps.map((s) => s.rule), [
        KeepRule.resolution,
        KeepRule.quality,
        KeepRule.people,
      ]);
    });

    test('toggling a rule disables it and notifies', () {
      final c = AppController(runner: FakeEngineRunner());
      var notifies = 0;
      c.addListener(() => notifies++);
      c.setKeepRuleEnabled(KeepRule.resolution, false);
      final resolution = c.keepPipeline.steps.firstWhere(
        (s) => s.rule == KeepRule.resolution,
      );
      expect(resolution.enabled, isFalse);
      expect(notifies, 1);
    });

    test('reordering moves a rule to a new priority', () {
      final c = AppController(runner: FakeEngineRunner());
      // Move quality (index 1) to the front (index 0).
      c.reorderKeepRule(1, 0);
      expect(c.keepPipeline.steps.first.rule, KeepRule.quality);
    });

    test('reorder ignores an out-of-range source and a no-op move', () {
      final c = AppController(runner: FakeEngineRunner());
      final before = c.keepPipeline.steps.map((s) => s.rule).toList();
      c.reorderKeepRule(99, 0); // out of range
      c.reorderKeepRule(0, 0); // no-op
      expect(c.keepPipeline.steps.map((s) => s.rule), before);
    });

    test('the kept (left) side follows the pipeline on a fresh run', () async {
      // Equal resolution; the right-hand file is crisper. Resolution can't
      // decide, so quality keeps the crisp one as the keeper.
      final fake = FakeEngineRunner()
        ..duplicateGroups = [
          DuplicateGroup(
            best: _hf('/dull.jpg', quality: 0.1, size: 50),
            duplicates: [_hf('/crisp.jpg', quality: 0.9, size: 50)],
          ),
        ];
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/dull.jpg', '/crisp.jpg']));
      c.openAction(LibraryAction.duplicates);

      await c.runFindDuplicates();

      expect(c.duplicatePairs!.single.kept.path, '/crisp.jpg');
      expect(c.duplicateRemovalPaths, ['/dull.jpg']);
    });

    test('toggling the pipeline re-decides reviewed pairs live', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetDuplicatePairs([
          DuplicatePair(
            kept: _hf('/big.jpg', width: 300, height: 300, quality: 0.1),
            other: _hf('/crisp.jpg', width: 100, height: 100, quality: 0.9),
          ),
        ]);
      // Initially resolution decides → big kept. Disable resolution so quality
      // takes over and the crisp file becomes the keeper.
      expect(c.duplicatePairs!.single.kept.path, '/big.jpg');
      c.setKeepRuleEnabled(KeepRule.resolution, false);
      expect(c.duplicatePairs!.single.kept.path, '/crisp.jpg');
    });

    test('re-deciding preserves a deselected pair', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetDuplicatePairs([
          DuplicatePair(
            kept: _hf('/big.jpg', width: 300, height: 300, quality: 0.1),
            other: _hf('/crisp.jpg', width: 100, height: 100, quality: 0.9),
            removeSelected: false,
          ),
        ]);
      c.setKeepRuleEnabled(KeepRule.resolution, false);
      // The pair flips its keeper but stays deselected (keep both).
      expect(c.duplicatePairs!.single.removeSelected, isFalse);
    });

    test('re-decide is a safe no-op before any run', () {
      final c = AppController(runner: FakeEngineRunner());
      c.setKeepRuleEnabled(KeepRule.quality, false);
      expect(c.duplicatePairs, isNull);
    });
  });

  group('runTrashDuplicates', () {
    test('trashes the selected right-side files', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetDuplicatePairs([
          DuplicatePair(kept: _hf('/k'), other: _hf('/r1')),
          DuplicatePair(
            kept: _hf('/k2'),
            other: _hf('/r2'),
            removeSelected: false,
          ),
        ]);
      await c.runTrashDuplicates();
      expect(fake.lastTrashedPaths, ['/r1']);
      expect(fake.calls, contains('trashPaths'));
    });

    test('is a no-op when nothing is selected', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetDuplicatePairs([
          DuplicatePair(
            kept: _hf('/k'),
            other: _hf('/r'),
            removeSelected: false,
          ),
        ]);
      await c.runTrashDuplicates();
      expect(fake.calls, isNot(contains('trashPaths')));
    });
  });
}
