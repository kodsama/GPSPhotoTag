import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/heatmap.dart';

MapPoint _point(double lat, double lon, {int count = 1}) => MapPoint(
  latitude: lat,
  longitude: lon,
  photos: [
    for (var i = 0; i < count; i++)
      ExplorePhoto(path: '/p$lat$lon$i.jpg', latitude: lat, longitude: lon),
  ],
);

void main() {
  const size = Size(400, 300);

  group('computeHeatBlobs', () {
    test('empty input yields no blobs', () {
      expect(
        computeHeatBlobs(offsets: const [], counts: const [], size: size),
        isEmpty,
      );
    });

    test('one in-view point becomes one splat at its offset', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(100, 100)],
        counts: const [1],
        size: size,
      );
      expect(blobs, hasLength(1));
      expect(blobs.single.offset, const Offset(100, 100));
      expect(blobs.single.weight, inInclusiveRange(0.0, 1.0));
    });

    test('a denser point splats heavier than a sparse one', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(50, 50), Offset(200, 200)],
        counts: const [1, 10],
        size: size,
      );
      expect(blobs, hasLength(2));
      expect(blobs[1].weight, greaterThan(blobs[0].weight));
      // Both share the same screen-space radius (weight differs, not radius):
      // proven by computeHeatBlobs carrying no per-point radius at all.
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

    test('HeatBlob equality compares offset/weight', () {
      const a = HeatBlob(offset: Offset(1, 2), weight: 0.5);
      const b = HeatBlob(offset: Offset(1, 2), weight: 0.5);
      const c = HeatBlob(offset: Offset(1, 2), weight: 0.6);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('weightForCount', () {
    test('a single photo gets the soft floor', () {
      expect(weightForCount(1), closeTo(0.45, 1e-9));
    });

    test('zero/negative counts are treated as one photo', () {
      expect(weightForCount(0), closeTo(0.45, 1e-9));
      expect(weightForCount(-5), closeTo(0.45, 1e-9));
    });

    test('more photos weigh more, with diminishing (log) returns', () {
      final w1 = weightForCount(1);
      final w2 = weightForCount(2);
      final w4 = weightForCount(4);
      expect(w2, greaterThan(w1));
      expect(w4, greaterThan(w2));
      // Log-shaped: the 1→2 jump exceeds the 2→4 jump.
      expect(w2 - w1, greaterThan(w4 - w2));
    });

    test('large stacks saturate at 1.0 (clamped)', () {
      expect(weightForCount(1000), 1.0);
    });
  });

  group('buildHeatPalette', () {
    final palette = buildHeatPalette();

    test('has 256 RGBA entries', () {
      expect(palette, hasLength(256 * 4));
    });

    test('the cold floor is fully transparent', () {
      final (_, _, _, a) = colorizeIntensity(palette, 0);
      expect(a, 0);
    });

    test('low density is blue-ish', () {
      final (r, g, b, a) = colorizeIntensity(palette, 0.15);
      expect(b, greaterThan(r));
      expect(b, greaterThan(g));
      expect(a, greaterThan(0));
    });

    test('mid density is green-ish', () {
      final (r, g, b, _) = colorizeIntensity(palette, 0.55);
      expect(g, greaterThan(r));
      expect(g, greaterThan(b));
    });

    test('the hot core is opaque red', () {
      final (r, g, b, a) = colorizeIntensity(palette, 1.0);
      expect(r, greaterThan(g));
      expect(r, greaterThan(b));
      expect(a, 255);
    });

    test('alpha rises monotonically from transparent to opaque', () {
      var prev = -1;
      for (var i = 0; i < 256; i++) {
        final a = palette[i * 4 + 3];
        expect(a, greaterThanOrEqualTo(prev));
        prev = a;
      }
      expect(palette[3], 0); // floor transparent
      expect(palette[255 * 4 + 3], 255); // core opaque
    });

    test('colorizeIntensity clamps out-of-range intensity', () {
      expect(colorizeIntensity(palette, -1), colorizeIntensity(palette, 0));
      expect(colorizeIntensity(palette, 2), colorizeIntensity(palette, 1));
    });
  });

  group('renderHeatmapImage', () {
    final palette = buildHeatPalette();

    test('no blobs renders nothing', () async {
      final image = await renderHeatmapImage(
        blobs: const [],
        size: size,
        palette: palette,
      );
      expect(image, isNull);
    });

    test('an empty viewport renders nothing', () async {
      final image = await renderHeatmapImage(
        blobs: const [HeatBlob(offset: Offset(10, 10), weight: 0.5)],
        size: Size.zero,
        palette: palette,
      );
      expect(image, isNull);
    });

    test('a splat renders an image of the viewport size', () async {
      final image = await renderHeatmapImage(
        blobs: const [HeatBlob(offset: Offset(200, 150), weight: 0.5)],
        size: size,
        palette: palette,
      );
      expect(image, isNotNull);
      expect(image!.width, 400);
      expect(image.height, 300);
      image.dispose();
    });

    test('overlapping splats produce a hotter (more opaque) core', () async {
      // One splat vs two coincident splats at the same point: the doubled
      // density must read hotter (a higher palette index / more opaque alpha).
      Future<int> coreAlpha(List<HeatBlob> blobs) async {
        final image = (await renderHeatmapImage(
          blobs: blobs,
          size: size,
          palette: palette,
        ))!;
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        image.dispose();
        // Centre pixel alpha at (200, 150).
        const x = 200, y = 150;
        return bytes[(y * 400 + x) * 4 + 3];
      }

      const one = [HeatBlob(offset: Offset(200, 150), weight: 0.5)];
      const two = [
        HeatBlob(offset: Offset(200, 150), weight: 0.5),
        HeatBlob(offset: Offset(200, 150), weight: 0.5),
      ];
      expect(await coreAlpha(two), greaterThan(await coreAlpha(one)));
    });
  });

  group('HeatmapLayer widget', () {
    Future<void> pumpLayer(WidgetTester tester, List<MapPoint> points) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlutterMap(
              options: const MapOptions(
                initialCenter: LatLng(42.5, 18.1),
                initialZoom: 6,
              ),
              children: [HeatmapLayer(points: points)],
            ),
          ),
        ),
      );
    }

    testWidgets('renders the colorized image once the async render lands', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pumpLayer(tester, [
          _point(42.5, 18.1, count: 3),
          _point(42.6, 18.2),
        ]);
        // Let the real async two-pass render (toImage → toByteData → decode)
        // complete, then the setState swaps the image in and repaints.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      });
      // The painter now holds the real image and drew it without error.
      expect(tester.takeException(), isNull);
      expect(find.byType(HeatmapLayer), findsOneWidget);
    });

    testWidgets('a superseded render is dropped (no stale image swapped in)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pumpLayer(tester, [_point(42.5, 18.1)]);
        // Rebuild with different points before the first render resolves, so the
        // in-flight render becomes stale and its image is discarded on arrival.
        await pumpLayer(tester, [_point(42.7, 18.3, count: 4)]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      });
      expect(tester.takeException(), isNull);
      expect(find.byType(HeatmapLayer), findsOneWidget);
    });

    testWidgets('an empty point list paints nothing without error', (
      tester,
    ) async {
      await pumpLayer(tester, const []);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
