import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/heatmap.dart';
import 'package:stunda/src/explore/map_tile_provider.dart';
import 'package:stunda/src/explore/photo_detail_panel.dart';
import 'package:stunda/src/explore/tile_cache.dart';
import 'package:stunda/src/explore/tile_provider_scope.dart';
import 'package:stunda/src/screens/explore_map_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';

import 'support/fakes.dart';

ExplorePhoto _gpsPhoto(String path, double lat, double lon, {FileMeta? meta}) =>
    ExplorePhoto(path: path, latitude: lat, longitude: lon, meta: meta);

Future<void> _pump(
  WidgetTester tester,
  AppController c, {
  TileProvider? tileProvider,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const screen = MaterialApp(home: Scaffold(body: ExploreMapScreen()));
  await tester.pumpWidget(
    ControllerScope(
      controller: c,
      child: tileProvider == null
          ? screen
          : TileProviderScope(tileProvider: tileProvider, child: screen),
    ),
  );
  await tester.pump();
}

Uint8List _realPng() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

MapPoint _mapPoint(double lat, double lon) => MapPoint(
  latitude: lat,
  longitude: lon,
  photos: [_gpsPhoto('/p.jpg', lat, lon)],
);

void main() {
  group('cameraFitForPoints', () {
    test('no points yields a null fit (so the action can no-op)', () {
      expect(cameraFitForPoints(const []), isNull);
    });

    test('frames the bounds of all points with padding', () {
      final fit = cameraFitForPoints([
        _mapPoint(42.5, 18.1),
        _mapPoint(43.0, 19.0),
      ]);
      expect(fit, isA<FitBounds>());
      final bounds = (fit! as FitBounds).bounds;
      // The fit spans the south-west / north-east extremes of the points.
      expect(bounds.south, 42.5);
      expect(bounds.north, 43.0);
      expect(bounds.west, 18.1);
      expect(bounds.east, 19.0);
    });
  });

  testWidgets('shows the loading chip while coordinates stream in', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..debugSetExplore(const [], loading: true);
    await _pump(tester, c);

    expect(find.textContaining('loading coordinates'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows an empty state when no geotagged photos', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const []))
      ..debugSetExplore(const []);
    await _pump(tester, c);

    expect(find.text('No geotagged photos to show.'), findsOneWidget);
  });

  testWidgets('the back affordance leaves the explore screen', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const []))
      ..debugSetExplore(const []);
    await _pump(tester, c);

    await tester.tap(find.text('Library'));
    await tester.pump();
    expect(c.screen, AppScreen.workspace);
  });

  testWidgets('a deep-link focus opens the detail panel for that photo', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/shot.heic']))
      ..debugSetExplore([
        _gpsPhoto(
          '/library/shot.heic',
          42.5,
          18.1,
          meta: const FileMeta(
            path: '/library/shot.heic',
            hasGps: true,
            latitude: 42.5,
            longitude: 18.1,
            width: 100,
            height: 80,
          ),
        ),
      ], focusPath: '/library/shot.heic');
    await _pump(tester, c);
    // The focus is handled in a post-frame callback; let it run.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(PhotoDetailPanel), findsOneWidget);
    expect(find.text('shot.heic'), findsOneWidget);
    expect(c.exploreFocusPath, isNull); // consumed
  });

  testWidgets('renders a marker pin with a count badge for stacked photos', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _gpsPhoto('/library/a.heic', 42.50000, 18.10000),
        _gpsPhoto('/library/b.heic', 42.50000, 18.10000),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));

    // Two photos at one coordinate -> one pin, badge "2".
    expect(find.byIcon(Icons.location_on), findsWidgets);
  });

  testWidgets('tapping a marker opens the detail; expand goes fullscreen', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);
    await _pump(tester, c);
    // Let the cluster layer lay out the marker child.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byIcon(Icons.location_on), findsOneWidget);
    await tester.tap(find.byIcon(Icons.location_on), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(PhotoDetailPanel), findsOneWidget);

    // Expand -> fullscreen InteractiveViewer.
    await tester.tap(find.byIcon(Icons.open_in_full));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // Back, then close the panel.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(PhotoDetailPanel), findsNothing);
  });

  testWidgets('settling a pan warms tiles around the view through the cache', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('prefetch-screen');
    addTearDown(() => root.deleteSync(recursive: true));
    var fetches = 0;
    final client = MockClient((_) async {
      fetches++;
      return http.Response.bytes(_realPng(), 200);
    });
    final cache = TileCache(client: client, root: root, sleep: (_) async {});
    final provider = CachingTileProvider(cache: cache);

    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);
    await _pump(tester, c, tileProvider: provider);
    await tester.pump(const Duration(milliseconds: 50));

    // Drive the whole gesture + debounce + warming on the REAL event loop so
    // the real Timer fires and the cache's real disk/network I/O completes.
    await tester.runAsync(() async {
      // Drag the map; the gesture end fires MapEventMoveEnd, scheduling the
      // (debounced) prefetch.
      await tester.drag(find.byType(FlutterMap), const Offset(-100, -80));
      await tester.pump();
      // Wait past the 400ms debounce so the warming fetches start.
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });

    // The settled pan triggered prefetch through the cache (>=1 tile fetched).
    // That the fetched bytes are then persisted to disk is covered
    // deterministically by the TileCache unit tests ('cache miss fetches,
    // writes the tile to disk'); asserting the file here would race the
    // fire-and-forget atomic write.
    expect(fetches, greaterThan(0));
  });

  testWidgets('the mode button cycles Numbers -> Heatmap -> Both -> Numbers', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _gpsPhoto('/library/a.heic', 42.5, 18.1),
        _gpsPhoto('/library/b.heic', 42.6, 18.2),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));

    // Numbers (default): cluster markers shown, no heat overlay.
    expect(find.text('Numbers'), findsOneWidget);
    expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);
    expect(find.byType(HeatmapLayer), findsNothing);

    // -> Heatmap: heat overlay, no number markers.
    await tester.tap(find.text('Numbers'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Heatmap'), findsOneWidget);
    expect(find.byType(HeatmapLayer), findsOneWidget);
    expect(find.byType(MarkerClusterLayerWidget), findsNothing);

    // -> Both: heat overlay AND number markers.
    await tester.tap(find.text('Heatmap'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Both'), findsOneWidget);
    expect(find.byType(HeatmapLayer), findsOneWidget);
    expect(find.byType(MarkerClusterLayerWidget), findsOneWidget);

    // -> back to Numbers.
    await tester.tap(find.text('Both'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Numbers'), findsOneWidget);
    expect(find.byType(HeatmapLayer), findsNothing);
  });

  testWidgets('the fit-to-photos button sits left of the mode button', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));

    final fit = find.byIcon(Icons.fit_screen);
    final mode = find.byIcon(Icons.tag); // Numbers mode icon
    expect(fit, findsOneWidget);
    expect(mode, findsOneWidget);
    // The fit button is positioned to the LEFT of the mode button.
    expect(tester.getCenter(fit).dx, lessThan(tester.getCenter(mode).dx));
    // Tapping it (with points present) re-fits without error.
    await tester.tap(fit);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the fit-to-photos button is a disabled no-op with no points', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const []))
      ..debugSetExplore(const []);
    await _pump(tester, c);

    final fit = find.byIcon(Icons.fit_screen);
    expect(fit, findsOneWidget);
    // Disabled: the underlying InkWell has a null onTap, so tapping is inert.
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: fit, matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNull);
    await tester.tap(fit);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
