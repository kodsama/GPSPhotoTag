import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/duplicates_model.dart';

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

/// A [Random] that always returns a fixed value, for deterministic word picks.
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value % max;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

void main() {
  group('similarityToThreshold', () {
    test('maps Exact (0) to threshold 0 and Loose to the max steps', () {
      expect(similarityToThreshold(0), 0);
      expect(similarityToThreshold(similaritySteps), similaritySteps);
    });

    test('is monotonic and clamps out-of-range', () {
      expect(similarityToThreshold(3), lessThan(similarityToThreshold(5)));
      expect(similarityToThreshold(-1), 0);
      expect(similarityToThreshold(999), similaritySteps);
    });
  });

  group('sceneVariance', () {
    test('is 0 at Exact and 1 at Loose', () {
      expect(sceneVariance(0), 0);
      expect(sceneVariance(similaritySteps), 1);
    });

    test('is monotonic across the range', () {
      expect(sceneVariance(2), lessThan(sceneVariance(5)));
      expect(sceneVariance(5), lessThan(sceneVariance(9)));
    });

    test('clamps out-of-range inputs to 0..1', () {
      expect(sceneVariance(-5), 0);
      expect(sceneVariance(999), 1);
    });
  });

  group('similarityExampleKey', () {
    String label(int v) => enTr(similarityExampleKey(v));

    test('Exact (0) reads as identical copies', () {
      expect(similarityExampleKey(0), 'sim_identical');
      expect(label(0), 'Identical copies');
    });

    test('the low band reads as a re-save/resize', () {
      expect(label(1), 'Re-saved or resized');
      expect(label(3), 'Re-saved or resized');
    });

    test('the mid band reads as minor edits', () {
      expect(label(4), 'Minor edits (crop, exposure)');
      expect(label(7), 'Minor edits (crop, exposure)');
    });

    test('the high band reads as a different shot of the same scene', () {
      expect(label(8), 'Same scene, a different shot');
      expect(label(10), 'Same scene, a different shot');
    });

    test('the loosest band reads as loosely-similar scenes', () {
      expect(label(11), 'Loosely similar scenes');
      expect(label(similaritySteps), 'Loosely similar scenes');
    });

    test('clamps out-of-range inputs to the end buckets', () {
      expect(label(-1), 'Identical copies');
      expect(label(999), 'Loosely similar scenes');
    });
  });

  group('qualityDegradation', () {
    test('decreases as the threshold gets stricter', () {
      // A stricter (higher) threshold flags milder cases, so the illustrative
      // flagged sample should look LESS degraded.
      expect(qualityDegradation(0.0), 1.0);
      expect(qualityDegradation(1.0), 0.0);
      expect(qualityDegradation(0.7), lessThan(qualityDegradation(0.3)));
    });

    test('is 1 - threshold across the range', () {
      expect(qualityDegradation(0.35), closeTo(0.65, 1e-9));
    });

    test('clamps out-of-range inputs to 0..1', () {
      expect(qualityDegradation(-0.5), 1.0);
      expect(qualityDegradation(1.5), 0.0);
    });
  });

  group('qualityExampleKey', () {
    String label(double v) => enTr(qualityExampleKey(v));

    test('lenient thresholds flag only clearly blurry/flat photos', () {
      expect(qualityExampleKey(0.0), 'lowq_only_blurry');
      expect(qualityExampleKey(0.25), 'lowq_only_blurry');
      expect(label(0.1), 'Flags only clearly blurry or flat photos.');
    });

    test('mid thresholds also flag so-so shots', () {
      expect(qualityExampleKey(0.26), 'lowq_soso');
      expect(qualityExampleKey(0.55), 'lowq_soso');
      expect(label(0.4), 'Flags so-so shots too, not just the worst.');
    });

    test('strict thresholds flag even slightly soft photos', () {
      expect(qualityExampleKey(0.56), 'lowq_strict');
      expect(qualityExampleKey(1.0), 'lowq_strict');
      expect(label(0.8), 'Strict — flags even slightly soft or flat photos.');
    });

    test('clamps out-of-range inputs to the end buckets', () {
      expect(qualityExampleKey(-1), 'lowq_only_blurry');
      expect(qualityExampleKey(2), 'lowq_strict');
    });
  });

  group('qualityPickedLabel', () {
    test('formats the threshold as a whole percent', () {
      expect(qualityPickedLabel(0.35, enTr), 'Lenient ↔ Strict · 35%');
      expect(qualityPickedLabel(0.0, enTr), 'Lenient ↔ Strict · 0%');
      expect(qualityPickedLabel(1.0, enTr), 'Lenient ↔ Strict · 100%');
    });

    test('clamps out-of-range thresholds before formatting', () {
      expect(qualityPickedLabel(-0.2, enTr), 'Lenient ↔ Strict · 0%');
      expect(qualityPickedLabel(1.4, enTr), 'Lenient ↔ Strict · 100%');
    });
  });

  group('pairsFromGroups', () {
    test('yields N-1 pairs per group, best on the left', () {
      final group = DuplicateGroup(
        best: _hf('/best.jpg', width: 200, height: 200),
        duplicates: [_hf('/d1.jpg'), _hf('/d2.jpg')],
      );
      final pairs = pairsFromGroups([group]);
      expect(pairs, hasLength(2));
      expect(pairs.every((p) => p.kept.path == '/best.jpg'), isTrue);
      expect(pairs.map((p) => p.other.path), ['/d1.jpg', '/d2.jpg']);
      expect(pairs.every((p) => p.removeSelected), isTrue);
    });

    test('empty groups yield no pairs', () {
      expect(pairsFromGroups(const []), isEmpty);
    });

    test('a pipeline re-decides the keeper (left side) per group', () {
      // The engine grouped with the big file as best; a quality-first pipeline
      // re-decides and keeps the crisp (smaller) one instead.
      final group = DuplicateGroup(
        best: HashedFile(
          path: '/big.jpg',
          hash: 0,
          width: 300,
          height: 300,
          fileSize: 10,
          basename: 'big',
          isRaw: false,
          quality: const ImageQuality(
            sharpness: 0.1,
            contrast: 0.1,
            colorfulness: 0.1,
            composite: 0.1,
          ),
        ),
        duplicates: [
          HashedFile(
            path: '/crisp.jpg',
            hash: 0,
            width: 100,
            height: 100,
            fileSize: 10,
            basename: 'crisp',
            isRaw: false,
            quality: const ImageQuality(
              sharpness: 0.9,
              contrast: 0.9,
              colorfulness: 0.9,
              composite: 0.9,
            ),
          ),
        ],
      );
      final pairs = pairsFromGroups([
        group,
      ], pipeline: const KeepPipeline([KeepStep(KeepRule.quality)]));
      expect(pairs.single.kept.path, '/crisp.jpg');
      expect(pairs.single.other.path, '/big.jpg');
    });
  });

  group('DuplicatePair', () {
    final pair = DuplicatePair(kept: _hf('/keep.jpg'), other: _hf('/dup.jpg'));

    test('swap flips kept/other', () {
      final swapped = pair.swap();
      expect(swapped.kept.path, '/dup.jpg');
      expect(swapped.other.path, '/keep.jpg');
      // Swapping twice returns to the original.
      expect(swapped.swap().kept.path, '/keep.jpg');
    });

    test('swap preserves the removal selection', () {
      final off = pair.withSelected(false).swap();
      expect(off.removeSelected, isFalse);
    });

    test('withSelected toggles the removal flag without swapping', () {
      final off = pair.withSelected(false);
      expect(off.removeSelected, isFalse);
      expect(off.kept.path, '/keep.jpg');
    });
  });

  group('selectedRemovalPaths', () {
    test(
      'collects only selected right-side files, de-duplicated, in order',
      () {
        final pairs = [
          DuplicatePair(kept: _hf('/a'), other: _hf('/b')),
          DuplicatePair(
            kept: _hf('/a'),
            other: _hf('/c'),
            removeSelected: false,
          ),
          // Duplicate target /b again — must appear once.
          DuplicatePair(kept: _hf('/d'), other: _hf('/b')),
        ];
        expect(selectedRemovalPaths(pairs), ['/b']);
      },
    );

    test('empty when nothing is selected', () {
      final pairs = [
        DuplicatePair(kept: _hf('/a'), other: _hf('/b'), removeSelected: false),
      ];
      expect(selectedRemovalPaths(pairs), isEmpty);
    });
  });

  group('silly word gate', () {
    test('pickSillyWord is deterministic given a seeded Random', () {
      expect(pickSillyWord(_FixedRandom(0)), sillyWords.first);
      expect(pickSillyWord(_FixedRandom(2)), sillyWords[2]);
    });

    test('matches case-insensitively and trims whitespace', () {
      expect(sillyWordMatches('  BananaPhone ', 'bananaphone'), isTrue);
      expect(sillyWordMatches('nope', 'bananaphone'), isFalse);
    });
  });

  group('HashProgress', () {
    test('ticks accumulate into the done count', () {
      var p = HashProgress(total: 5);
      expect(p.done, 0);
      p = p.tick(1);
      expect(p.done, 1);
      p = p.tick(2);
      expect(p.done, 3);
    });

    test('fraction is done/total, and null when total is 0', () {
      expect(HashProgress(done: 2, total: 8).fraction, closeTo(0.25, 1e-9));
      expect(HashProgress().fraction, isNull);
      expect(HashProgress(total: 4).fraction, 0);
    });

    test('clamps done into 0..total so the bar never overshoots', () {
      expect(HashProgress(done: 9, total: 4).done, 4);
      expect(HashProgress(done: -3, total: 4).done, 0);
    });

    test('groups thousands for the hashing label', () {
      String label(HashProgress p) => enTr('hashing_progress', {
        'done': p.groupedDone,
        'total': p.groupedTotal,
      });
      expect(
        label(HashProgress(done: 1234, total: 5000)),
        'Hashing 1,234 / 5,000',
      );
      expect(label(HashProgress(done: 7, total: 9)), 'Hashing 7 / 9');
      expect(
        label(HashProgress(done: 1000000, total: 1000000)),
        'Hashing 1,000,000 / 1,000,000',
      );
    });
  });
}
