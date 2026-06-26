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
}) => HashedFile(
  path: path,
  hash: 0,
  width: width,
  height: height,
  fileSize: size,
  basename: path,
  isRaw: false,
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
