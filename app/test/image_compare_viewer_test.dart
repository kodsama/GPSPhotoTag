import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/widgets/image_compare_viewer.dart';

import 'support/fakes.dart';

Widget _host(AppController c, List<ComparePane> panes) => ControllerScope(
  controller: c,
  child: MaterialApp(home: ImageCompareViewer(panes: panes)),
);

void main() {
  group('single mode', () {
    testWidgets('shows the image, reset + close, and no compare button', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(
        _host(c, const [ComparePane(path: '/library/doc.pdf')]),
      );
      await tester.pump();

      // No compare-layout (mode) button in single mode.
      expect(find.byIcon(Icons.splitscreen), findsNothing);
      // Reset + close are present.
      expect(find.byIcon(Icons.center_focus_strong), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      // A non-decodable file shows the typed placeholder.
      expect(find.text('PDF'), findsOneWidget);
    });

    testWidgets('decodable but missing file falls back to the placeholder', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _host(c, const [ComparePane(path: '/no/such/pic.jpg')]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('JPG'), findsOneWidget);
    });

    testWidgets('reads the curated EXIF for the shown path on open', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake);
      await tester.pumpWidget(
        _host(c, const [ComparePane(path: '/library/a.jpg')]),
      );
      await tester.pump();
      expect(fake.lastCuratedExifPaths, ['/library/a.jpg']);
    });

    testWidgets('reset recentres the shared transform', (tester) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(
        _host(c, const [ComparePane(path: '/library/doc.pdf')]),
      );
      await tester.pump();
      // Tapping reset is a no-op-safe path that exercises the handler.
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pump();
      expect(find.byType(ImageCompareViewer), findsOneWidget);
    });
  });

  group('compare mode', () {
    const panes = [
      ComparePane(path: '/library/left.heic'),
      ComparePane(path: '/library/right.heic'),
    ];

    testWidgets('opens in the default vertical curtain with two placeholders', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(_host(c, panes));
      await tester.pump();

      // Compare-layout button present; default mode icon is the vertical curtain.
      expect(find.byIcon(Icons.splitscreen), findsOneWidget);
      // Both panes render the HEIC placeholder (fake returns no preview).
      expect(find.text('HEIC'), findsNWidgets(2));
      // No reset in a curtain mode.
      expect(find.byIcon(Icons.center_focus_strong), findsNothing);
    });

    testWidgets('mode button cycles vertical → horizontal → side-by-side', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(_host(c, panes));
      await tester.pump();

      // Start: vertical curtain.
      expect(find.byIcon(Icons.splitscreen), findsOneWidget);
      // → horizontal curtain.
      await tester.tap(find.byIcon(Icons.splitscreen));
      await tester.pump();
      expect(find.byIcon(Icons.horizontal_split), findsOneWidget);
      expect(find.byIcon(Icons.center_focus_strong), findsNothing);
      // → side-by-side (adds a reset + a vertical divider).
      await tester.tap(find.byIcon(Icons.horizontal_split));
      await tester.pump();
      expect(find.byIcon(Icons.view_column), findsOneWidget);
      expect(find.byIcon(Icons.center_focus_strong), findsOneWidget);
      expect(find.byType(VerticalDivider), findsOneWidget);
      // → back to vertical curtain.
      await tester.tap(find.byIcon(Icons.view_column));
      await tester.pump();
      expect(find.byIcon(Icons.splitscreen), findsOneWidget);
    });

    testWidgets('dragging the vertical divider changes the reveal fraction', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(_host(c, panes));
      await tester.pump();

      final knob = find.byIcon(Icons.drag_indicator);
      expect(knob, findsOneWidget);
      final before = tester.getCenter(knob).dx;
      // Drag the curtain leftwards.
      await tester.drag(knob, const Offset(-200, 0));
      await tester.pump();
      final after = tester.getCenter(knob).dx;
      expect(after, lessThan(before));
    });

    testWidgets('side-by-side reset is tappable', (tester) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(_host(c, panes));
      await tester.pump();
      // Cycle to side-by-side.
      await tester.tap(find.byIcon(Icons.splitscreen));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.horizontal_split));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.center_focus_strong));
      await tester.pump();
      expect(find.byType(ImageCompareViewer), findsOneWidget);
    });

    testWidgets('switching to horizontal then dragging moves the handle', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(_host(c, panes));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.splitscreen)); // → horizontal
      await tester.pump();

      final knob = find.byIcon(Icons.drag_indicator);
      final before = tester.getCenter(knob).dy;
      await tester.drag(knob, const Offset(0, -150));
      await tester.pump();
      expect(tester.getCenter(knob).dy, lessThan(before));
    });
  });

  group('info line', () {
    testWidgets('shows name, resolution, size and the GPS pin with a tooltip', (
      tester,
    ) async {
      final fake = FakeEngineRunner(
        curatedExif: const {
          '/library/a.jpg': CuratedExif(path: '/library/a.jpg', iso: '400'),
        },
      );
      final c = AppController(runner: fake);
      await tester.pumpWidget(
        _host(c, const [
          ComparePane(
            path: '/library/a.jpg',
            fileSize: 2 * 1024 * 1024,
            meta: FileMeta(
              path: '/library/a.jpg',
              hasGps: true,
              latitude: 42.5,
              longitude: 18.1,
              width: 4032,
              height: 3024,
            ),
          ),
        ]),
      );
      await tester.pump(); // let loadCuratedExif resolve
      await tester.pump();

      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('4032 × 3024'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
      expect(find.text('ISO 400'), findsOneWidget);
      // The GPS pin is rendered with a tooltip carrying the coordinate.
      final tip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byIcon(Icons.place),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tip.message, '42.50000, 18.10000');
    });

    testWidgets('no GPS pin when the meta carries no coordinates', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(
        _host(c, const [
          ComparePane(
            path: '/library/a.jpg',
            meta: FileMeta(path: '/library/a.jpg', width: 10, height: 10),
          ),
        ]),
      );
      await tester.pump();
      expect(find.byIcon(Icons.place), findsNothing);
    });
  });

  group('RAW/HEIC preview', () {
    testWidgets('renders the extracted JPEG when one is available', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('viewer_raw');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jpeg = p.join(dir.path, 'full.jpg');
      File(
        jpeg,
      ).writeAsBytesSync(img.encodeJpg(img.Image(width: 16, height: 16)));

      final fake = FakeEngineRunner()..previews['/library/shot.raf'] = jpeg;
      final c = AppController(runner: fake);
      await tester.pumpWidget(
        _host(c, const [ComparePane(path: '/library/shot.raf')]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('falls back to the placeholder when no preview is produced', (
      tester,
    ) async {
      final fake = FakeEngineRunner(); // previews map empty → null
      final c = AppController(runner: fake);
      await tester.pumpWidget(
        _host(c, const [ComparePane(path: '/library/shot.raf')]),
      );
      await tester.pumpAndSettle();
      expect(find.text('RAF'), findsOneWidget);
    });

    testWidgets('a preview that fails to decode shows the placeholder', (
      tester,
    ) async {
      final fake = FakeEngineRunner()
        ..previews['/library/shot.raf'] = '/no/such/extracted.jpg';
      final c = AppController(runner: fake);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _host(c, const [ComparePane(path: '/library/shot.raf')]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('RAF'), findsOneWidget);
    });
  });

  group('openImageCompare', () {
    testWidgets('pushes the viewer and the close button pops it', (
      tester,
    ) async {
      final c = AppController(runner: FakeEngineRunner());
      await tester.pumpWidget(
        ControllerScope(
          controller: c,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => openImageCompare(context, const [
                    ComparePane(path: '/library/a.jpg'),
                  ]),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageCompareViewer), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(ImageCompareViewer), findsNothing);
    });
  });
}
