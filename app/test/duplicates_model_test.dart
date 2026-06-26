import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/duplicates_model.dart';

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
}
