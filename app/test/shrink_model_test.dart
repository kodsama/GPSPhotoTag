import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/duplicates_model.dart';
import 'package:stunda/src/state/shrink_model.dart';

import 'support/fakes.dart';

HashedFile _hf(String path, {int size = 1000, bool isRaw = false}) =>
    HashedFile(
      path: path,
      hash: 0,
      width: 10,
      height: 10,
      fileSize: size,
      basename: path,
      isRaw: isRaw,
    );

void main() {
  group('reason mapping', () {
    test('every reason resolves to a non-key English label', () {
      for (final reason in ShrinkReason.values) {
        final label = reason.label(enTr);
        expect(label, isNotEmpty);
        expect(label, isNot(equals(reason.labelKey)));
      }
    });

    test('reasonsForStage covers exactly the stage-owned reasons', () {
      expect(reasonsForStage(ShrinkStage.duplicates), {ShrinkReason.duplicate});
      expect(reasonsForStage(ShrinkStage.orphans), {
        ShrinkReason.orphanRaw,
        ShrinkReason.orphanImage,
      });
      expect(reasonsForStage(ShrinkStage.pairs), {
        ShrinkReason.redundantRaw,
        ShrinkReason.redundantJpg,
      });
      expect(reasonsForStage(ShrinkStage.lowQuality), {
        ShrinkReason.lowQuality,
      });
    });
  });

  group('duplicateCandidates', () {
    test('flags only selected right-side files, deduped, with sizes', () {
      final pairs = [
        DuplicatePair(kept: _hf('/a.jpg'), other: _hf('/b.jpg', size: 500)),
        DuplicatePair(
          kept: _hf('/a.jpg'),
          other: _hf('/c.jpg', size: 700),
          removeSelected: false,
        ),
        // Same target as the first pair → emitted once.
        DuplicatePair(kept: _hf('/d.jpg'), other: _hf('/b.jpg', size: 500)),
      ];
      final out = duplicateCandidates(pairs, gpsOf: (p) => p == '/b.jpg');
      expect(out.map((c) => c.path), ['/b.jpg']);
      expect(out.single.reason, ShrinkReason.duplicate);
      expect(out.single.sizeBytes, 500);
      expect(out.single.hasGps, isTrue);
    });
  });

  group('orphanCandidates', () {
    RawPairing pairing() => classifyPairing([
      '/photos/only.raf', // orphanRaw
      '/photos/solo.jpg', // photoWithoutRaw (orphan image)
      '/photos/pair.raf', // pairedRaw
      '/photos/pair.jpg', // photoWithRaw
    ]);

    test('includes the chosen orphan side(s) with reasons', () {
      final raws = orphanCandidates(
        pairing(),
        includeOrphanRaws: true,
        includeOrphanImages: false,
        sizeOf: (_) => 42,
      );
      expect(raws.map((c) => c.path), ['/photos/only.raf']);
      expect(raws.single.reason, ShrinkReason.orphanRaw);
      expect(raws.single.sizeBytes, 42);

      final images = orphanCandidates(
        pairing(),
        includeOrphanRaws: false,
        includeOrphanImages: true,
      );
      expect(images.map((c) => c.path), ['/photos/solo.jpg']);
      expect(images.single.reason, ShrinkReason.orphanImage);
      expect(images.single.sizeBytes, 0); // no sizeOf → 0

      final none = orphanCandidates(
        pairing(),
        includeOrphanRaws: false,
        includeOrphanImages: false,
      );
      expect(none, isEmpty);
    });
  });

  group('redundantPairCandidates', () {
    RawPairing pairing() => classifyPairing([
      '/photos/pair.raf', // pairedRaw
      '/photos/pair.jpg', // photoWithRaw
      '/photos/only.raf', // orphanRaw (ignored)
    ]);

    test('dropRaw flags the pairedRaw side', () {
      final out = redundantPairCandidates(
        pairing(),
        side: PairDropSide.dropRaw,
        sizeOf: (_) => 9,
        gpsOf: (_) => false,
      );
      expect(out.map((c) => c.path), ['/photos/pair.raf']);
      expect(out.single.reason, ShrinkReason.redundantRaw);
      expect(out.single.sizeBytes, 9);
    });

    test('dropPhoto flags the photoWithRaw side', () {
      final out = redundantPairCandidates(
        pairing(),
        side: PairDropSide.dropPhoto,
      );
      expect(out.map((c) => c.path), ['/photos/pair.jpg']);
      expect(out.single.reason, ShrinkReason.redundantJpg);
    });
  });

  group('lowQualityCandidates', () {
    test('flags only scores strictly below the threshold', () {
      final out = lowQualityCandidates(
        {'/a.jpg': 0.1, '/b.jpg': 0.5, '/c.jpg': 0.35},
        threshold: 0.35,
        sizeOf: (_) => 3,
        gpsOf: (p) => p == '/a.jpg',
      );
      expect(out.map((c) => c.path), ['/a.jpg']); // 0.35 is NOT below 0.35
      expect(out.single.reason, ShrinkReason.lowQuality);
      expect(out.single.sizeBytes, 3);
      expect(out.single.hasGps, isTrue);
    });
  });

  group('StagedSet cumulative dedup + tallies', () {
    ShrinkCandidate c(String path, ShrinkReason r, int size) =>
        ShrinkCandidate(path: path, reason: r, sizeBytes: size, hasGps: false);

    test('first reason wins: a later stage never re-counts a staged path', () {
      final set = StagedSet();
      final dup = set.addStage(ShrinkStage.duplicates, [
        c('/a.jpg', ShrinkReason.duplicate, 100),
        c('/b.jpg', ShrinkReason.duplicate, 200),
      ]);
      expect(dup.added.length, 2);
      expect(dup.stageTally.count, 2);
      expect(dup.stageTally.bytes, 300);
      expect(dup.runningTotal.count, 2);
      expect(dup.runningTotal.bytes, 300);

      // The orphans stage proposes /b.jpg again (already staged) plus a new one.
      final orph = set.addStage(ShrinkStage.orphans, [
        c('/b.jpg', ShrinkReason.orphanImage, 999),
        c('/x.jpg', ShrinkReason.orphanImage, 50),
      ]);
      expect(orph.added.map((e) => e.path), ['/x.jpg']);
      expect(orph.stageTally.count, 1);
      expect(orph.stageTally.bytes, 50);
      // Running total spans both stages, /b.jpg counted once at its first size.
      expect(orph.runningTotal.count, 3);
      expect(orph.runningTotal.bytes, 350);
      expect(set.all.length, 3);
    });

    test(
      'deselecting drops a path from the selected total but keeps it staged',
      () {
        final set = StagedSet()
          ..addStage(ShrinkStage.duplicates, [
            c('/a.jpg', ShrinkReason.duplicate, 100),
            c('/b.jpg', ShrinkReason.duplicate, 200),
          ]);
        expect(set.selectedTally.count, 2);
        expect(set.selectedTally.bytes, 300);

        set.setSelected('/a.jpg', false);
        expect(set.isSelected('/a.jpg'), isFalse);
        expect(set.contains('/a.jpg'), isTrue); // still staged
        expect(set.selectedPaths, ['/b.jpg']);
        expect(set.selectedTally.count, 1);
        expect(set.selectedTally.bytes, 200);

        // Re-selecting restores it; setSelected on an unstaged path is a no-op.
        set.setSelected('/a.jpg', true);
        set.setSelected('/ghost.jpg', false);
        expect(set.selectedPaths, ['/a.jpg', '/b.jpg']);
      },
    );

    test('removeStage rolls back only that stage\'s contributions', () {
      final set = StagedSet()
        ..addStage(ShrinkStage.duplicates, [
          c('/a.jpg', ShrinkReason.duplicate, 100),
        ])
        ..addStage(ShrinkStage.orphans, [
          c('/o.raf', ShrinkReason.orphanRaw, 10),
          c('/o.jpg', ShrinkReason.orphanImage, 20),
        ]);
      expect(set.all.length, 3);

      set.removeStage(ShrinkStage.orphans);
      expect(set.all.map((c) => c.path), ['/a.jpg']);
      expect(set.contains('/o.raf'), isFalse);
    });
  });
}
