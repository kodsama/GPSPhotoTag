/// Pure vector math behind the Smart (embedding) duplicate metric.
///
/// The embedder turns each image into a feature vector; two images are alike
/// when their vectors point the same way. This file holds the L2-normalization
/// (so a vector becomes a direction) and the cosine-to-similarity mapping. Every
/// function is pure so the metric's maths is unit-testable without a model or
/// native runtime.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Returns [vector] L2-normalized to unit length, as a [Float32List].
///
/// A zero (or empty) vector is returned unchanged - it has no direction, so the
/// cosine against anything is 0 (a neutral, never-grouping similarity).
Float32List l2Normalize(List<double> vector) {
  var sumSq = 0.0;
  for (final v in vector) {
    sumSq += v * v;
  }
  final norm = math.sqrt(sumSq);
  final out = Float32List(vector.length);
  if (norm == 0) return out;
  for (var i = 0; i < vector.length; i++) {
    out[i] = vector[i] / norm;
  }
  return out;
}

/// The cosine similarity of two vectors: the dot product over the product of
/// their magnitudes, in `-1..1`. Returns 0 when either vector is empty, has a
/// zero magnitude, or the lengths differ (no meaningful angle).
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
  var dot = 0.0;
  var magA = 0.0;
  var magB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    magA += a[i] * a[i];
    magB += b[i] * b[i];
  }
  if (magA == 0 || magB == 0) return 0;
  return dot / (math.sqrt(magA) * math.sqrt(magB));
}

/// Maps a raw cosine similarity in `-1..1` to a 0..1 duplicate-similarity score:
/// `(cosine + 1) / 2`, clamped. 1 means identical direction (the same image),
/// 0.5 means orthogonal, 0 means opposite.
double cosineToSimilarity(double cosine) => ((cosine + 1) / 2).clamp(0.0, 1.0);
