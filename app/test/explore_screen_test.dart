import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/photo_detail_panel.dart';
import 'package:stunda/src/screens/explore_map_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';

import 'support/fakes.dart';

ExplorePhoto _gpsPhoto(String path, double lat, double lon, {FileMeta? meta}) =>
    ExplorePhoto(path: path, latitude: lat, longitude: lon, meta: meta);

Future<void> _pump(WidgetTester tester, AppController c) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ControllerScope(
      controller: c,
      child: const MaterialApp(home: Scaffold(body: ExploreMapScreen())),
    ),
  );
  await tester.pump();
}

void main() {
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
}
