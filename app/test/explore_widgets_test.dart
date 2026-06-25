import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/explore/detail_selection.dart';
import 'package:stunda/src/explore/explore_markers.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/photo_detail_panel.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/widgets/content_panel.dart';

import 'support/fakes.dart';

ExplorePhoto _photo(String path, {FileMeta? meta}) => ExplorePhoto(
  path: path,
  latitude: 42.50000,
  longitude: 18.10000,
  meta: meta,
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('PhotoDetailPanel', () {
    testWidgets('single photo: metadata, placeholder for HEIC, no pager', (
      tester,
    ) async {
      final selection = DetailSelection(
        point: MapPoint(
          latitude: 42.5,
          longitude: 18.1,
          photos: [
            _photo(
              '/library/shot.heic',
              meta: const FileMeta(
                path: '/library/shot.heic',
                hasGps: true,
                latitude: 42.5,
                longitude: 18.1,
                width: 4032,
                height: 3024,
                date: null,
              ),
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        _wrap(
          PhotoDetailPanel(
            selection: selection,
            onPrev: () {},
            onNext: () {},
            onClose: () {},
            onExpand: () {},
          ),
        ),
      );

      // Filename + dimensions + coordinates.
      expect(find.text('shot.heic'), findsOneWidget);
      expect(find.text('4032 × 3024'), findsOneWidget);
      expect(find.text('42.50000, 18.10000'), findsOneWidget);
      // HEIC isn't decodable -> typed placeholder, not an Image.
      expect(find.text('HEIC'), findsOneWidget);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      // No pager for a single photo.
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      // Expand + close are present.
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('multi photo: counter and prev/next fire callbacks', (
      tester,
    ) async {
      var prev = 0, next = 0, expanded = 0, closed = 0;
      final selection = DetailSelection(
        point: MapPoint(
          latitude: 1,
          longitude: 2,
          photos: [_photo('/a.heic'), _photo('/b.heic'), _photo('/c.heic')],
        ),
        index: 1,
      );

      await tester.pumpWidget(
        _wrap(
          PhotoDetailPanel(
            selection: selection,
            onPrev: () => prev++,
            onNext: () => next++,
            onExpand: () => expanded++,
            onClose: () => closed++,
          ),
        ),
      );

      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.tap(find.byIcon(Icons.close));
      expect([prev, next, expanded, closed], [1, 1, 1, 1]);
    });

    testWidgets('expand opens a fullscreen InteractiveViewer', (tester) async {
      final selection = DetailSelection(
        point: MapPoint(
          latitude: 1,
          longitude: 2,
          photos: [_photo('/library/shot.heic')],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => PhotoDetailPanel(
                selection: selection,
                onPrev: () {},
                onNext: () {},
                onClose: () {},
                onExpand: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const FullscreenImageView(path: '/library/shot.heic'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('HEIC'), findsOneWidget); // placeholder fullscreen
    });
  });

  group('FullscreenImageView', () {
    testWidgets('decodable path uses an Image inside InteractiveViewer', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: FullscreenImageView(path: '/library/pic.jpg')),
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('pic.jpg'), findsOneWidget);
    });
  });

  group('deep-link from the file list', () {
    Widget host(AppController c, FolderScanResult scan) => ControllerScope(
      controller: c,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ContentPanel(scan: scan)),
        ),
      ),
    );

    testWidgets('tapping an image row pin opens Explore focused on it', (
      tester,
    ) async {
      final c = AppController(
        runner: FakeEngineRunner(
          imageMeta: {
            '/library/a.jpg': const FileMeta(
              path: '/library/a.jpg',
              hasGps: true,
              latitude: 42.5,
              longitude: 18.1,
            ),
          },
        ),
      );
      final scan = fakeScan(photos: const ['/library/a.jpg']);
      await tester.pumpWidget(host(c, scan));

      await tester.tap(find.text('JPG'));
      await tester.pumpAndSettle();

      // The pin is now an IconButton; tapping it deep-links and closes dialog.
      await tester.tap(find.byTooltip('Explore on map'));
      await tester.pumpAndSettle();

      expect(c.screen, AppScreen.explore);
      expect(c.exploreFocusPath, '/library/a.jpg');
    });

    testWidgets(
      'tapping an image row filename opens the standalone preview dialog',
      (tester) async {
        final c = AppController(
          runner: FakeEngineRunner(
            imageMeta: {
              '/library/a.jpg': FileMeta(
                path: '/library/a.jpg',
                width: 4032,
                height: 3024,
                date: DateTime(2023, 7, 15, 9, 4),
              ),
            },
          ),
        );
        final scan = fakeScan(photos: const ['/library/a.jpg']);
        await tester.pumpWidget(host(c, scan));

        await tester.tap(find.text('JPG'));
        await tester.pumpAndSettle();

        // Tapping the filename opens the preview dialog (NOT the map).
        await tester.tap(find.text('a.jpg'));
        await tester.pumpAndSettle();

        expect(c.screen, isNot(AppScreen.explore)); // not the map
        expect(find.byType(PhotoPreview), findsOneWidget);
        // Seeded metadata is shown.
        expect(find.text('4032 × 3024'), findsOneWidget);
        expect(find.text('2023-07-15 09:04'), findsOneWidget);

        // The expand control opens the fullscreen view.
        await tester.tap(find.byIcon(Icons.open_in_full));
        await tester.pumpAndSettle();
        expect(find.byType(FullscreenImageView), findsOneWidget);
      },
    );

    testWidgets('a GPS-source row filename is not a preview target', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSeedMeta(
          const FileMeta(path: '/library/t.gpx', hasGps: true, pointCount: 3),
        );
      final scan = fakeScan(gpxFiles: const ['/library/t.gpx']);
      await tester.pumpWidget(host(c, scan));

      await tester.tap(find.text('GPX'));
      await tester.pumpAndSettle();

      // Tapping a source filename does not open a photo preview.
      await tester.tap(find.text('t.gpx'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoPreview), findsNothing);
    });
  });

  group('Explore action card', () {
    testWidgets('the workspace shows an Explore card', (tester) async {
      tester.view.physicalSize = const Size(1400, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      await tester.pumpWidget(
        ControllerScope(
          controller: c,
          child: const MaterialApp(home: Scaffold(body: WorkspaceScreen())),
        ),
      );
      await tester.pump();

      expect(find.text('Explore on map'), findsOneWidget);
      // The card is ready (1 photo) — readiness label shows the count.
      expect(find.text('1 photos'), findsWidgets);
    });
  });

  group('PhotoDetailPanel metadata', () {
    testWidgets('renders a date line when the meta carries a date', (
      tester,
    ) async {
      final selection = DetailSelection(
        point: MapPoint(
          latitude: 1,
          longitude: 2,
          photos: [
            _photo(
              '/library/shot.heic',
              meta: FileMeta(
                path: '/library/shot.heic',
                hasGps: true,
                latitude: 1,
                longitude: 2,
                date: DateTime(2023, 7, 5, 9, 4),
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(
          PhotoDetailPanel(
            selection: selection,
            onPrev: () {},
            onNext: () {},
            onClose: () {},
            onExpand: () {},
          ),
        ),
      );
      expect(find.text('2023-07-05 09:04'), findsOneWidget);
    });
  });

  group('PhotoThumbnail', () {
    testWidgets('decodes a real jpg into an Image (cacheWidth)', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('thumb');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'pic.jpg');
      File(
        path,
      ).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));

      await tester.pumpWidget(_wrap(PhotoThumbnail(path: path, height: 100)));
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(find.byType(Image), findsOneWidget);
      // No placeholder for a decodable type.
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
      // cacheWidth wired through.
      expect(image.image, isA<ResizeImage>());
    });
  });

  group('explore markers', () {
    testWidgets('PhotoPin shows no badge for a single photo', (tester) async {
      await tester.pumpWidget(
        _wrap(const PhotoPin(count: 1, color: Colors.blue)),
      );
      expect(find.byIcon(Icons.location_on), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });

    testWidgets('PhotoPin badges the count when several photos stack', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const PhotoPin(count: 4, color: Colors.blue)),
      );
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('ClusterBadge shows the cluster count', (tester) async {
      await tester.pumpWidget(
        _wrap(const ClusterBadge(count: 42, color: Colors.blue)),
      );
      expect(find.text('42'), findsOneWidget);
    });
  });

  group('PhotoThumbnail error fallback', () {
    testWidgets('a missing decodable file falls back to the placeholder', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _wrap(const PhotoThumbnail(path: '/no/such/pic.jpg', height: 100)),
        );
        // Let the real file read fail so errorBuilder runs.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(find.text('JPG'), findsOneWidget);
    });
  });

  group('previewMetaLines', () {
    test('includes date, dimensions and coordinates when present', () {
      final lines = previewMetaLines(
        '/a.jpg',
        FileMeta(
          path: '/a.jpg',
          hasGps: true,
          latitude: 42.5,
          longitude: 18.1,
          width: 100,
          height: 80,
          date: DateTime(2023, 1, 2, 3, 4),
        ),
      );
      expect(lines, ['2023-01-02 03:04', '100 × 80', '42.50000, 18.10000']);
    });

    test('omits coordinates for a non-GPS photo and null meta', () {
      expect(
        previewMetaLines('/a.jpg', const FileMeta(path: '/a.jpg')),
        isEmpty,
      );
      expect(previewMetaLines('/a.jpg', null), isEmpty);
    });
  });

  group('PhotoPreview (reusable)', () {
    testWidgets('hides the close button when onClose is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PhotoPreview(
            path: '/library/shot.heic',
            meta: const FileMeta(path: '/library/shot.heic'),
            onExpand: () {},
          ),
        ),
      );
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      expect(find.text('shot.heic'), findsOneWidget);
    });

    testWidgets('expand control fires onExpand', (tester) async {
      var expanded = 0;
      await tester.pumpWidget(
        _wrap(
          PhotoPreview(
            path: '/library/shot.heic',
            onExpand: () => expanded++,
            onClose: () {},
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.tap(find.byIcon(Icons.close));
      expect(expanded, 1);
    });
  });
}
