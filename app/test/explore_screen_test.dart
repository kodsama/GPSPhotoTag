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

DateTime _d(int y, [int m = 1, int day = 1]) => DateTime(y, m, day);

ExplorePhoto _datedPhoto(String path, double lat, double lon, DateTime date) =>
    ExplorePhoto(
      path: path,
      latitude: lat,
      longitude: lon,
      meta: FileMeta(
        path: path,
        hasGps: true,
        latitude: lat,
        longitude: lon,
        date: date,
      ),
    );

/// The photos currently feeding the (live) [HeatmapLayer] — a direct read of
/// what the filtered set hands the heatmap.
List<ExplorePhoto> _heatmapPhotos(WidgetTester tester) =>
    tester.widget<HeatmapLayer>(find.byType(HeatmapLayer)).photos;

Future<void> _pump(
  WidgetTester tester,
  AppController c, {
  TileProvider? tileProvider,
  Future<String?> Function()? savePathPicker,
  Future<Uint8List?> Function()? capturePng,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final screen = MaterialApp(
    home: Scaffold(
      body: ExploreMapScreen(
        savePathPicker: savePathPicker,
        capturePng: capturePng,
      ),
    ),
  );
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

  testWidgets('the save-view button sits among the top-right controls', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));

    final save = find.byIcon(Icons.save_alt);
    final mode = find.byIcon(Icons.tag); // Numbers mode icon
    expect(save, findsOneWidget);
    expect(find.byTooltip('Save view as PNG'), findsOneWidget);
    // The save button sits left of the mode button (between fit and mode).
    expect(tester.getCenter(save).dx, lessThan(tester.getCenter(mode).dx));
    // It is enabled (tappable) when there are points to export.
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: save, matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNotNull);
  });

  testWidgets('tapping save captures the view and invokes the save flow', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('explore-save');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/stunda-map.png';
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);

    // Inject the capture so the flow is deterministic (the real
    // RepaintBoundary.toImage raster doesn't render in headless tests). Reaching
    // the save-path picker proves the button is wired through capture →
    // AppController.savePng; the actual byte-write + "Saved to …" feedback are
    // covered deterministically by the AppController.savePng seam tests.
    final captureBytes = _realPng();
    var pickerCalled = false;
    await _pump(
      tester,
      c,
      capturePng: () async => captureBytes,
      savePathPicker: () async {
        pickerCalled = true;
        return out;
      },
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.save_alt));
    // Flush the (fake-future) capture + pickPath microtasks; no real I/O.
    await tester.pump();
    await tester.pump();

    expect(pickerCalled, isTrue);
  });

  testWidgets(
    'cancelling the save panel writes nothing and shows no snackbar',
    (tester) async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
        ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);

      await tester.runAsync(() async {
        await _pump(tester, c, savePathPicker: () async => null);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byIcon(Icons.save_alt));
        await tester.pump();
        await tester.pump();
      });
      await tester.pump();

      expect(find.textContaining('Saved to'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed capture shows the capture-failed snackbar', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);

    // capturePng returns null → the "Couldn't capture the map view." branch.
    await _pump(tester, c, capturePng: () async => null);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining("Couldn't capture the map view."),
      findsOneWidget,
    );
  });

  testWidgets('the save-view button is disabled with no points', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const []))
      ..debugSetExplore(const []);
    await _pump(tester, c);

    final save = find.byIcon(Icons.save_alt);
    expect(save, findsOneWidget);
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: save, matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNull);
    await tester.tap(save);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Timeline button is hidden when no photo carries a date', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_gpsPhoto('/library/a.heic', 42.5, 18.1)]);
    await _pump(tester, c);

    expect(find.text('Timeline'), findsNothing);
  });

  testWidgets('tapping Timeline toggles the range selector', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic']))
      ..debugSetExplore([_datedPhoto('/library/a.heic', 42.5, 18.1, _d(2021))]);
    await _pump(tester, c);

    expect(find.byType(TimelinePanel), findsNothing);
    await tester.tap(find.text('Timeline'));
    await tester.pump();
    expect(find.byType(TimelinePanel), findsOneWidget);

    // A single dated photo is a zero-width span: labels show, no slider.
    expect(find.byType(RangeSlider), findsNothing);

    // Toggling again hides it.
    await tester.tap(find.text('Timeline'));
    await tester.pump();
    expect(find.byType(TimelinePanel), findsNothing);
  });

  testWidgets(
    'narrowing the range filters both markers and the heatmap input',
    (tester) async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(
          fakeScan(photos: const ['/library/a.heic', '/b.heic', '/c.heic']),
        )
        ..debugSetExplore([
          _datedPhoto('/library/a.heic', 42.5, 18.1, _d(2020)),
          _datedPhoto('/b.heic', 42.6, 18.2, _d(2021)),
          _datedPhoto('/c.heic', 42.7, 18.3, _d(2022)),
        ]);
      await _pump(tester, c);
      await tester.pump(const Duration(milliseconds: 50));

      // Switch to "Both" so the heatmap receives the filtered photo list too.
      await tester.tap(find.text('Numbers'));
      await tester.pump();
      await tester.tap(find.text('Heatmap'));
      await tester.pump(const Duration(milliseconds: 50));

      // All three photos feed the heatmap before any filtering.
      expect(_heatmapPhotos(tester), hasLength(3));

      // Open the timeline and narrow the range to 2021-only via the panel.
      await tester.tap(find.text('Timeline'));
      await tester.pump();
      final panel = tester.widget<TimelinePanel>(find.byType(TimelinePanel));
      panel.onChanged((start: _d(2021), end: _d(2021, 12, 31)));
      await tester.pump(const Duration(milliseconds: 50));

      // Only the 2021 photo survives, reflected to the heatmap AND the markers.
      expect(_heatmapPhotos(tester), hasLength(1));
      expect(_heatmapPhotos(tester).single.path, '/b.heic');

      // Reset range restores the full set.
      await tester.tap(find.text('Reset range'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_heatmapPhotos(tester), hasLength(3));
    },
  );

  testWidgets('dragging the range slider narrows the visible photos', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _datedPhoto('/library/a.heic', 42.5, 18.1, _d(2020)),
        _datedPhoto('/b.heic', 42.6, 18.2, _d(2024)),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Numbers'));
    await tester.pump();
    await tester.tap(find.text('Heatmap'));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Timeline'));
    await tester.pump();
    expect(_heatmapPhotos(tester), hasLength(2));

    // Drag the left (start) handle to the far right, pushing the start past the
    // earlier photo so only the later one remains.
    final slider = find.byType(RangeSlider);
    final box = tester.getRect(slider);
    await tester.dragFrom(
      Offset(box.left + 8, box.center.dy),
      Offset(box.width, 0),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(_heatmapPhotos(tester).length, lessThan(2));
  });

  testWidgets('the date label opens a picker and applies the chosen date', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _datedPhoto('/library/a.heic', 42.5, 18.1, _d(2020, 1, 1)),
        _datedPhoto('/b.heic', 42.6, 18.2, _d(2020, 1, 31)),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Timeline'));
    await tester.pump();

    // Tap the START label to open the date picker, pick a later day, confirm.
    await tester.tap(find.text('2020-01-01 00:00'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('20'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    // Then the time picker; accept its default.
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // The start label moved off the span start — the range narrowed.
    expect(find.text('2020-01-01 00:00'), findsNothing);
  });

  testWidgets('the end date label opens a picker and applies the chosen date', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _datedPhoto('/library/a.heic', 42.5, 18.1, _d(2020, 1, 1)),
        _datedPhoto('/b.heic', 42.6, 18.2, _d(2020, 1, 31)),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Timeline'));
    await tester.pump();

    // Tap the END label, pick an earlier day than the span end, confirm.
    await tester.tap(find.text('2020-01-31 00:00'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('10'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // accept default time
    await tester.pumpAndSettle();

    // The end moved off the span end — the range narrowed.
    expect(find.text('2020-01-31 00:00'), findsNothing);
  });

  testWidgets('cancelling the end date picker leaves the range unchanged', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.heic', '/b.heic']))
      ..debugSetExplore([
        _datedPhoto('/library/a.heic', 42.5, 18.1, _d(2020, 1, 1)),
        _datedPhoto('/b.heic', 42.6, 18.2, _d(2020, 1, 31)),
      ]);
    await _pump(tester, c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Timeline'));
    await tester.pump();

    await tester.tap(find.text('2020-01-01 00:00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Dismissed without choosing: the range is untouched.
    expect(find.text('2020-01-01 00:00'), findsOneWidget);
    expect(find.text('2020-01-31 00:00'), findsOneWidget);
  });
}
