import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/heatmap.dart';

ExplorePhoto _photo(double lat, double lon, [int i = 0]) =>
    ExplorePhoto(path: '/p$lat$lon$i.jpg', latitude: lat, longitude: lon);

void main() {
  const size = Size(400, 300);

  group('computeHeatBlobs', () {
    test('empty input yields no blobs', () {
      expect(computeHeatBlobs(offsets: const [], size: size), isEmpty);
    });

    test('one in-view photo becomes one splat at its offset', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(100, 100)],
        size: size,
      );
      expect(blobs, hasLength(1));
      expect(blobs.single.offset, const Offset(100, 100));
      expect(blobs.single.weight, kHeatPointAlpha);
    });

    test('every photo splats with the same low peak weight', () {
      // Heat builds from OVERLAP, not from a per-photo weight: both splats are
      // identical low-alpha blobs regardless of position.
      final blobs = computeHeatBlobs(
        offsets: const [Offset(50, 50), Offset(200, 200)],
        size: size,
      );
      expect(blobs, hasLength(2));
      expect(blobs[0].weight, kHeatPointAlpha);
      expect(blobs[1].weight, kHeatPointAlpha);
    });

    test('the per-point peak alpha is faint so a lone photo is a glow', () {
      expect(kHeatPointAlpha, lessThan(0.3));
    });

    test('many coincident photos each contribute a splat (overlap)', () {
      // Three photos at the EXACT same coordinate => three overlapping splats
      // (the field is fed individual photos, never pre-grouped points).
      final blobs = computeHeatBlobs(
        offsets: const [Offset(150, 150), Offset(150, 150), Offset(150, 150)],
        size: size,
      );
      expect(blobs, hasLength(3));
    });

    test('photos well outside the viewport are culled', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(-500, -500), Offset(2000, 2000)],
        size: size,
      );
      expect(blobs, isEmpty);
    });

    test('a photo just off-screen within the radius margin is kept', () {
      final blobs = computeHeatBlobs(
        offsets: const [Offset(-10, 150)],
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

  group('gaussianFalloff', () {
    test('is 1.0 at the centre', () {
      expect(gaussianFalloff(0), closeTo(1.0, 1e-9));
    });

    test('decays monotonically from centre to rim', () {
      var prev = double.infinity;
      for (var i = 0; i <= 10; i++) {
        final v = gaussianFalloff(i / 10);
        expect(v, lessThan(prev));
        prev = v;
      }
    });

    test('is nearly zero (not a hard plateau) at the rim', () {
      // A soft fade, not a near-opaque disc that cuts off abruptly.
      expect(gaussianFalloff(1), lessThan(0.05));
    });

    test('clamps t outside 0..1', () {
      expect(gaussianFalloff(-1), gaussianFalloff(0));
      expect(gaussianFalloff(2), gaussianFalloff(1));
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

    test('has a long transparent cold tail (low density shows the map)', () {
      // Sparse/lone-photo density (the bottom of the ramp) stays see-through.
      final (_, _, _, a) = colorizeIntensity(palette, 0.18);
      expect(a, 0);
    });

    test('density is hot (opaque) only near the top of the ramp', () {
      // Just past the transparent tail it is faint, not already red.
      final (rLow, _, bLow, aLow) = colorizeIntensity(palette, 0.4);
      expect(aLow, greaterThan(0));
      expect(aLow, lessThan(150)); // still translucent
      expect(bLow, greaterThan(rLow)); // blue-ish, not red

      final (_, _, _, aHot) = colorizeIntensity(palette, 1.0);
      expect(aHot, 255); // opaque only at full density
    });

    test('mid density is green-ish', () {
      final (r, g, b, _) = colorizeIntensity(palette, 0.65);
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
      // Many coincident faint splats vs one: the piled-up density must read
      // hotter (a higher palette index / more opaque alpha) — overlap drives
      // heat, not a single splat.
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

      const one = [HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha)];
      const many = [
        HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
        HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
        HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
        HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
        HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
      ];
      expect(await coreAlpha(many), greaterThan(await coreAlpha(one)));
    });

    test('a single faint splat stays in the transparent cold tail', () async {
      // One lone photo => its centre alpha must be (near) fully transparent,
      // i.e. it reads as a faint glow, not a solid coloured disc.
      final image = (await renderHeatmapImage(
        blobs: const [
          HeatBlob(offset: Offset(200, 150), weight: kHeatPointAlpha),
        ],
        size: size,
        palette: palette,
      ))!;
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      const x = 200, y = 150;
      final coreAlpha = bytes[(y * 400 + x) * 4 + 3];
      expect(coreAlpha, lessThan(60)); // faint, not opaque
    });
  });

  group('HeatmapLayer widget', () {
    Future<void> pumpLayer(
      WidgetTester tester,
      List<ExplorePhoto> photos,
    ) async {
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
              children: [HeatmapLayer(photos: photos)],
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
          // Several individual photos, some coincident (overlap → heat).
          _photo(42.5, 18.1, 0),
          _photo(42.5, 18.1, 1),
          _photo(42.5, 18.1, 2),
          _photo(42.6, 18.2),
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
        await pumpLayer(tester, [_photo(42.5, 18.1)]);
        // Rebuild with different photos before the first render resolves, so
        // the in-flight render becomes stale and its image is discarded.
        await pumpLayer(tester, [_photo(42.7, 18.3), _photo(42.7, 18.3, 1)]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      });
      expect(tester.takeException(), isNull);
      expect(find.byType(HeatmapLayer), findsOneWidget);
    });

    testWidgets('an empty photo list paints nothing without error', (
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
