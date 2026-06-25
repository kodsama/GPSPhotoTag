import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/explore/heatmap.dart';

void main() {
  const size = Size(400, 300);

  group('computeHeatBlobs', () {
    test('empty input yields no blobs', () {
      expect(
        computeHeatBlobs(offsets: const [], counts: const [], size: size),
        isEmpty,
      );
    });

    test('one in-view point becomes one blob at its offset', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(100, 100)],
        counts: const [1],
        size: size,
      );
      expect(blobs, hasLength(1));
      expect(blobs.single.offset, const Offset(100, 100));
      expect(blobs.single.radius, greaterThan(0));
      expect(blobs.single.intensity, inInclusiveRange(0.0, 1.0));
    });

    test('a denser point glows hotter and larger than a sparse one', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(50, 50), Offset(200, 200)],
        counts: const [1, 10],
        size: size,
      );
      expect(blobs, hasLength(2));
      final sparse = blobs[0], dense = blobs[1];
      expect(dense.intensity, greaterThan(sparse.intensity));
      expect(dense.radius, greaterThan(sparse.radius));
      // The busiest point saturates to full intensity.
      expect(dense.intensity, closeTo(1.0, 1e-9));
    });

    test('points well outside the viewport are culled', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(-500, -500), Offset(2000, 2000)],
        counts: const [3, 3],
        size: size,
      );
      expect(blobs, isEmpty);
    });

    test('a point just off-screen within the radius margin is kept', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(-10, 150)],
        counts: const [1],
        size: size,
        radius: 42,
      );
      expect(blobs, hasLength(1));
    });

    test('HeatBlob equality compares offset/radius/intensity', () {
      const a = HeatBlob(offset: Offset(1, 2), radius: 3, intensity: 0.5);
      const b = HeatBlob(offset: Offset(1, 2), radius: 3, intensity: 0.5);
      const c = HeatBlob(offset: Offset(1, 2), radius: 3, intensity: 0.6);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
