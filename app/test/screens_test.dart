import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/main.dart';
import 'package:gpsphototag_gui/src/actions/map_action.dart';
import 'package:gpsphototag_gui/src/actions/prune_action.dart';
import 'package:gpsphototag_gui/src/actions/tag_action.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/app_screen.dart';
import 'package:gpsphototag_gui/src/state/library_action.dart';
import 'package:gpsphototag_gui/src/widgets/action_card.dart';
import 'package:gpsphototag_gui/src/widgets/status_pill.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true}) => ToolStatus(
  id: id,
  name: id,
  present: present,
  purpose: 'test',
  required: false,
);

Future<void> _pump(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(1400, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(GpsPhotoTagApp(controller: controller));
  await tester.pump();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('gui_screens'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('workspace', () {
    testWidgets('renders the library bar, content panel and action cards', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(
          fakeScan(
            photos: const ['/library/a.jpg', '/library/b.raf'],
            gpxFiles: const ['/library/t.gpx'],
            unsupported: const [
              UnsupportedFile('/library/clip.mov', UnsupportedCategory.video),
              UnsupportedFile('/library/old.tif', UnsupportedCategory.image),
            ],
          ),
        );
      await _pump(tester, controller);

      // Library bar stat line + change button.
      expect(find.textContaining('photos ·'), findsOneWidget);
      expect(find.text('Change library'), findsOneWidget);

      // One card per action.
      expect(find.byType(ActionCard), findsNWidgets(LibraryAction.all.length));
      expect(find.text('Tag with GPS'), findsOneWidget);
      expect(find.text('Generate map'), findsOneWidget);
      expect(find.text('Remove orphan RAWs'), findsOneWidget);

      // Content panel groups unsupported files.
      expect(find.textContaining('Videos (1)'), findsOneWidget);
      expect(find.textContaining('Images (1)'), findsOneWidget);
    });

    testWidgets('readiness reflects the scan', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan()); // 1 jpg, no GPS, no RAW
      await _pump(tester, controller);

      // Tag has no GPS sources; prune has no RAWs.
      expect(find.text('No GPS sources found'), findsOneWidget);
      expect(find.text('No RAW files found'), findsOneWidget);
      // Map is ready (1 photo).
      expect(find.text('1 photos'), findsOneWidget);
    });

    testWidgets('tapping a ready card opens its action', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']));
      await _pump(tester, controller);

      await tester.tap(find.text('Tag with GPS'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.action);
      expect(controller.action, LibraryAction.tag);
      expect(find.byType(TagAction), findsOneWidget);
    });

    testWidgets('Change library returns to welcome', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan());
      await _pump(tester, controller);

      await tester.tap(find.text('Change library'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.welcome);
    });
  });

  group('tag action', () {
    Future<AppController> open(
      WidgetTester tester, {
      bool exiftool = true,
    }) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool', present: exiftool)])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']))
        ..debugSetScreen(AppScreen.action, action: LibraryAction.tag);
      await _pump(tester, controller);
      return controller;
    }

    testWidgets(
      'options drive the controller and the primary button names it',
      (tester) async {
        final controller = await open(tester);
        expect(find.byType(TagAction), findsOneWidget);
        expect(find.text('Tag 1 photos'), findsOneWidget);

        final switches = find.byType(Switch);
        await tester.tap(switches.at(0)); // copy to folder
        await tester.pump();
        expect(controller.copyToFolder, isTrue);

        await tester.tap(find.text('Sidecar'));
        await tester.pump();
        expect(controller.rawMode, RawMode.sidecar);

        await tester.enterText(find.byType(TextFormField).at(0), '45');
        await tester.pump();
        expect(controller.maxTimeDiffSeconds, 45);
      },
    );

    testWidgets('dry-run renames the primary button to Preview', (
      tester,
    ) async {
      final controller = await open(tester);
      controller.setDryRun(true);
      await tester.pump();
      expect(find.text('Preview 1 photos'), findsOneWidget);
    });

    testWidgets('embed RAW mode is disabled and noted without exiftool', (
      tester,
    ) async {
      final controller = await open(tester, exiftool: false);
      expect(find.textContaining('Embed needs ExifTool'), findsOneWidget);
      await tester.tap(find.text('Embed'), warnIfMissed: false);
      await tester.pump();
      expect(controller.rawMode, RawMode.auto);
    });

    testWidgets('running the tag streams progress then shows the result', (
      tester,
    ) async {
      final controller = await open(tester);
      await tester.tap(find.text('Tag 1 photos'));
      await tester.pumpAndSettle();

      expect(controller.lastSummary, {'tagged': 1});
      expect(find.text('total'), findsOneWidget);
      expect(find.text('Done — back to library'), findsOneWidget);

      await tester.tap(find.text('Done — back to library'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.workspace);
    });

    testWidgets('a mid-run progress bar, item row and pill render', (
      tester,
    ) async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [
          ProgressEvent(done: 1, total: 2),
          ItemEvent(
            PhotoRow(
              path: '/photos/a.jpg',
              status: PhotoStatus.tagged,
              location: LocationResult(
                latitude: 42.5,
                longitude: 18.1,
                source: GpsSource.gpx,
                method: GpsMethod.exact,
              ),
            ),
          ),
        ],
      );
      addTearDown(fake.release);
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(
          fakeScan(
            photos: const ['/library/a.jpg', '/library/b.jpg'],
            gpxFiles: const ['/library/t.gpx'],
          ),
        )
        ..debugSetScreen(AppScreen.action, action: LibraryAction.tag);
      await _pump(tester, controller);

      await tester.tap(find.text('Tag 2 photos'));
      await tester.pump();
      await tester.pump();

      expect(controller.running, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.byType(StatusPill), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('an error event surfaces in the tag UI', (tester) async {
      final controller =
          AppController(
              runner: FakeEngineRunner(
                events: const [ErrorEvent('boom tagging')],
              ),
            )
            ..debugSetToolkit([_tool('exiftool')])
            ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']))
            ..debugSetScreen(AppScreen.action, action: LibraryAction.tag);
      await _pump(tester, controller);

      await tester.tap(find.text('Tag 1 photos'));
      await tester.pumpAndSettle();
      expect(controller.errorMessage, 'boom tagging');
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('map action', () {
    testWidgets('renders the heatmap and returns to library', (tester) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(), folder: tmp.path)
        ..debugSetScreen(AppScreen.action, action: LibraryAction.map);
      await _pump(tester, controller);

      expect(find.byType(MapAction), findsOneWidget);
      // Pick a different DPI then render.
      await tester.tap(find.text('300 dpi'));
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('Render heatmap'));
        while (controller.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(fake.calls, contains('map'));
      expect(File('${tmp.path}/gpsphototag-heatmap.png').existsSync(), isTrue);
      expect(find.text('Heatmap'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);

      await tester.tap(find.text('Done — back to library'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.workspace);
    });
  });

  group('prune action', () {
    testWidgets('preview-first toggles the button label and runs', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/x.raf']))
        ..debugSetScreen(AppScreen.action, action: LibraryAction.pruneRaw);
      await _pump(tester, controller);

      expect(find.byType(PruneAction), findsOneWidget);
      // Dry-run on by default.
      expect(find.text('Preview orphan RAWs'), findsOneWidget);

      // Turn dry-run off -> destructive label.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.text('Move orphan RAWs to Trash'), findsOneWidget);

      await tester.tap(find.text('Move orphan RAWs to Trash'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('prune'));
      expect(find.text('Done — back to library'), findsOneWidget);
    });
  });

  group('action header', () {
    testWidgets('the back affordance returns to the library', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan())
        ..debugSetScreen(AppScreen.action, action: LibraryAction.map);
      await _pump(tester, controller);

      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.workspace);
    });
  });

  group('mid-run and error states', () {
    AppController openWith(LibraryAction action, FakeEngineRunner fake) =>
        AppController(runner: fake)
          ..debugSetToolkit([_tool('exiftool')])
          ..debugSetScan(
            fakeScan(photos: const ['/library/x.raf']),
            folder: tmp.path,
          )
          ..debugSetScreen(AppScreen.action, action: action);

    testWidgets('prune shows a live progress bar while running', (
      tester,
    ) async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ProgressEvent(done: 0, total: 0)],
      );
      addTearDown(fake.release);
      final controller = openWith(LibraryAction.pruneRaw, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Preview orphan RAWs'));
      await tester.pump();
      await tester.pump();
      expect(controller.running, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('prune surfaces an error event', (tester) async {
      final fake = FakeEngineRunner(events: const [ErrorEvent('prune boom')]);
      final controller = openWith(LibraryAction.pruneRaw, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Preview orphan RAWs'));
      await tester.pumpAndSettle();
      expect(controller.errorMessage, 'prune boom');
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('map shows a live progress bar while running', (tester) async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ProgressEvent(done: 0, total: 1)],
      );
      addTearDown(fake.release);
      final controller = openWith(LibraryAction.map, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Render heatmap'));
      await tester.pump();
      await tester.pump();
      expect(controller.running, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('map surfaces an error event', (tester) async {
      final fake = FakeEngineRunner(events: const [ErrorEvent('map boom')]);
      final controller = openWith(LibraryAction.map, fake);
      await _pump(tester, controller);

      await tester.runAsync(() async {
        await tester.tap(find.text('Render heatmap'));
        while (controller.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(controller.errorMessage, 'map boom');
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('action card', () {
    testWidgets('hover highlights an enabled card', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']));
      await _pump(tester, controller);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('Generate map')));
      await tester.pumpAndSettle();
      // No assertion needed beyond no-throw: exercises the hover state path.
      expect(find.text('Generate map'), findsOneWidget);
    });
  });
}
