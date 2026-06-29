import 'dart:math' as math;

import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('l2Normalize', () {
    test('scales a vector to unit length', () {
      final n = l2Normalize([3, 4]);
      // Float32List storage, so use a float-precision tolerance.
      expect(n[0], closeTo(0.6, 1e-6));
      expect(n[1], closeTo(0.8, 1e-6));
      final mag = math.sqrt(n[0] * n[0] + n[1] * n[1]);
      expect(mag, closeTo(1.0, 1e-6));
    });

    test('a zero vector stays zero (no direction)', () {
      expect(l2Normalize([0, 0, 0]), [0, 0, 0]);
    });

    test('an empty vector yields an empty result', () {
      expect(l2Normalize(const []), isEmpty);
    });
  });

  group('cosineSimilarity', () {
    test('identical direction → 1', () {
      expect(cosineSimilarity([1, 2, 3], [2, 4, 6]), closeTo(1.0, 1e-9));
    });

    test('opposite direction → -1', () {
      expect(cosineSimilarity([1, 0], [-1, 0]), closeTo(-1.0, 1e-9));
    });

    test('orthogonal → 0', () {
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0.0, 1e-9));
    });

    test('empty, length-mismatch, or zero-magnitude → 0', () {
      expect(cosineSimilarity(const [], const []), 0);
      expect(cosineSimilarity([1, 2], [1, 2, 3]), 0);
      expect(cosineSimilarity([0, 0], [1, 1]), 0);
      expect(cosineSimilarity([1, 1], [0, 0]), 0);
    });
  });

  group('cosineToSimilarity', () {
    test('maps -1..1 to 0..1', () {
      expect(cosineToSimilarity(1), 1.0);
      expect(cosineToSimilarity(0), 0.5);
      expect(cosineToSimilarity(-1), 0.0);
    });

    test('clamps out-of-range cosines', () {
      expect(cosineToSimilarity(2), 1.0);
      expect(cosineToSimilarity(-2), 0.0);
    });
  });
}
