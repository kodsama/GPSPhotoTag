import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

FileMeta _gps(String path, double lat, double lon) =>
    FileMeta(path: path, hasGps: true, latitude: lat, longitude: lon);

void main() {
  group('readiness for Explore', () {
    test('enabled when the library has photos', () {
      final r = LibraryAction.explore.readiness(
        fakeScan(photos: const ['/library/a.jpg']),
      );
      expect(r.enabled, isTrue);
      expect(r.label, '1 photos');
    });

    test('blocked when there are no photos', () {
      final r = LibraryAction.explore.readiness(fakeScan(photos: const []));
      expect(r.enabled, isFalse);
      expect(r.label, 'No photos found');
    });
  });

  group('openExplore', () {
    test(
      'routes to the explore screen and loads only geotagged photos',
      () async {
        final fake = FakeEngineRunner(
          imageMeta: {
            '/library/a.jpg': _gps('/library/a.jpg', 42.5, 18.1),
            // b.jpg has no GPS -> excluded from the markers.
            '/library/b.jpg': const FileMeta(path: '/library/b.jpg'),
          },
        );
        final c = AppController(runner: fake)
          ..debugSetScan(
            fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
          );

        c.openAction(LibraryAction.explore); // routes via openExplore
        expect(c.screen, AppScreen.explore);
        // Streams in off the (fake) engine; let microtasks settle.
        await Future<void>.delayed(Duration.zero);

        expect(fake.calls, contains('readImageMeta'));
        expect(c.exploreLoaded, 2);
        expect(c.exploreTotal, 2);
        expect(c.exploreLoading, isFalse);
        expect(c.explorePhotos.map((p) => p.path), ['/library/a.jpg']);
      },
    );

    test('with no photos finishes immediately and shows nothing to plot', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const []));
      c.openExplore();
      expect(c.screen, AppScreen.explore);
      expect(c.exploreLoading, isFalse);
      expect(c.explorePhotos, isEmpty);
    });

    test('reuses already-cached coordinates without re-reading', () async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..debugSeedMeta(_gps('/library/a.jpg', 1, 2));

      c.openExplore();
      await Future<void>.delayed(Duration.zero);

      // Everything was cached: no engine read, photo plotted, not loading.
      expect(fake.calls, isNot(contains('readImageMeta')));
      expect(c.exploreLoading, isFalse);
      expect(c.explorePhotos.single.path, '/library/a.jpg');
    });

    test('a stream error while loading clears the loading flag', () async {
      final c = AppController(runner: ThrowingEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      c.openExplore();
      expect(c.exploreLoading, isTrue); // kicked off, one pending read
      await Future<void>.delayed(Duration.zero);

      // readImageMeta erred -> onError stops the spinner, nothing plotted.
      expect(c.exploreLoading, isFalse);
      expect(c.explorePhotos, isEmpty);
    });

    test('closeExplore returns to the workspace', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const []));
      c.openExplore();
      c.closeExplore();
      expect(c.screen, AppScreen.workspace);
      expect(c.exploreLoading, isFalse);
    });
  });

  group('openExploreAt (deep link)', () {
    test('sets the explore screen and remembers the focus path', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..debugSeedMeta(_gps('/library/a.jpg', 1, 2));

      c.openExploreAt('/library/a.jpg');
      expect(c.screen, AppScreen.explore);
      expect(c.exploreFocusPath, '/library/a.jpg');

      c.clearExploreFocus();
      expect(c.exploreFocusPath, isNull);
    });
  });

  group('changeLibrary clears explore state', () {
    test('drops loaded photos and returns to welcome', () {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..debugSeedMeta(_gps('/library/a.jpg', 1, 2));
      c.openExplore();
      c.changeLibrary();
      expect(c.screen, AppScreen.welcome);
      expect(c.explorePhotos, isEmpty);
    });
  });
}
