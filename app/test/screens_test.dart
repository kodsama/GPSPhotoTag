import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/actions/map_action.dart';
import 'package:stunda/src/actions/prune_action.dart';
import 'package:stunda/src/actions/tag_action.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/widgets/action_card.dart';
import 'package:stunda/src/widgets/status_pill.dart';

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
  await tester.pumpWidget(StundaApp(controller: controller));
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

    testWidgets('the action grid reflows to fewer columns when narrow', (
      tester,
    ) async {
      // A narrow viewport drives the LayoutBuilder's 2-then-1 column branches.
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      await tester.pumpWidget(StundaApp(controller: controller));
      await tester.pump();

      // All cards still render; they stack rather than sitting 3-across.
      final cards = find.byType(ActionCard);
      expect(cards, findsNWidgets(LibraryAction.all.length));
      // Cards are full-width (single column): each spans most of the viewport.
      final size = tester.getSize(cards.first);
      expect(size.width, greaterThan(300));
    });

    testWidgets('a non-const WorkspaceScreen builds from the scanned library', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      await tester.pumpWidget(
        ControllerScope(
          controller: controller,
          child: MaterialApp(
            // Non-const construction so the constructor body is exercised.
            home: Scaffold(
              body: SingleChildScrollView(
                child: WorkspaceScreen(key: UniqueKey()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ActionCard), findsNWidgets(LibraryAction.all.length));
    });

    testWidgets('readiness reflects the scan', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan()); // 1 jpg, no GPS, no RAW
      await _pump(tester, controller);

      // Tag has no GPS sources; prune has no RAWs.
      expect(find.text('No GPS sources found'), findsOneWidget);
      expect(find.text('No RAW files found'), findsOneWidget);
      // Map and Explore are both ready (1 photo).
      expect(find.text('1 photos'), findsNWidgets(2));
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

    testWidgets('tapping the Explore card opens the live map screen', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      await _pump(tester, controller);

      await tester.tap(find.text('Explore on map'));
      await tester.pump();
      expect(controller.screen, AppScreen.explore);
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

    testWidgets('a chosen output folder shows the confirmation row', (
      tester,
    ) async {
      final controller = await open(tester);

      // Turn on copy-to-folder, then pick a destination.
      controller.setCopyToFolder(true);
      controller.setOutDir('/exports/tagged');
      await tester.pump();

      // The chosen-dir row renders with the confirmation tick and the path.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('/exports/tagged'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

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
      expect(File('${tmp.path}/stunda-heatmap.png').existsSync(), isTrue);
      expect(find.text('Heatmap'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);

      await tester.tap(find.text('Done — back to library'));
      await tester.pumpAndSettle();
      expect(controller.screen, AppScreen.workspace);
    });
  });

  group('prune action', () {
    AppController openReview(FakeEngineRunner fake) =>
        AppController(runner: fake)
          ..debugSetToolkit([_tool('exiftool')])
          ..debugSetScan(
            fakeScan(
              photos: const [
                '/library/orphan.raf',
                '/library/keeper.raf',
                '/library/keeper.jpg',
              ],
            ),
          )
          ..debugSetScreen(AppScreen.action, action: LibraryAction.pruneRaw);

    testWidgets('shows a review list with the summary, not an immediate run', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = openReview(fake);
      await _pump(tester, controller);

      expect(find.byType(PruneAction), findsOneWidget);
      // Header summary + candidate row + pre-selected button label.
      expect(find.textContaining('orphan RAWs ·'), findsOneWidget);
      expect(find.text('orphan.raf'), findsOneWidget);
      expect(find.text('Move 1 selected to Trash'), findsOneWidget);
      // Context rows hidden by default; nothing trashed yet.
      expect(find.text('keeper.raf'), findsNothing);
      expect(fake.calls, isEmpty);
    });

    testWidgets('the Paired chip reveals both sides of the RAW+JPG pairing', (
      tester,
    ) async {
      final controller = openReview(FakeEngineRunner());
      await _pump(tester, controller);

      // Three merged chips; the duplicate side is gone.
      expect(find.text('Orphan RAWs'), findsOneWidget);
      expect(find.text('Paired (RAW + JPG)'), findsOneWidget);
      expect(find.text('Photos without RAW'), findsOneWidget);
      expect(find.text('RAWs with JPG'), findsNothing);
      expect(find.text('Photos with RAW'), findsNothing);

      await tester.tap(find.text('Paired (RAW + JPG)'));
      await tester.pumpAndSettle();
      // Reveals both the paired RAF and its JPG twin.
      expect(find.text('keeper.raf'), findsOneWidget);
      expect(find.text('keeper.jpg'), findsOneWidget);
    });

    testWidgets('the Orphan RAWs chip toggles candidate visibility', (
      tester,
    ) async {
      final controller = openReview(FakeEngineRunner());
      await _pump(tester, controller);

      expect(controller.isKindVisible(PairKind.orphanRaw), isTrue);
      expect(find.text('orphan.raf'), findsOneWidget);

      // Tapping the (selected) chip hides the orphan candidates.
      await tester.tap(find.text('Orphan RAWs'));
      await tester.pumpAndSettle();
      expect(controller.isKindVisible(PairKind.orphanRaw), isFalse);
      expect(find.text('orphan.raf'), findsNothing);
    });

    testWidgets('the Photos-without-RAW chip toggles those rows', (
      tester,
    ) async {
      // keeper.jpg has a RAW twin, lonely.jpg does not -> it is the only
      // "photo without RAW" row the chip reveals.
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(
          fakeScan(
            photos: const ['/library/orphan.raf', '/library/lonely.jpg'],
          ),
        )
        ..debugSetScreen(AppScreen.action, action: LibraryAction.pruneRaw);
      await _pump(tester, controller);

      expect(controller.isKindVisible(PairKind.photoWithoutRaw), isFalse);
      expect(find.text('lonely.jpg'), findsNothing);

      await tester.tap(find.text('Photos without RAW'));
      await tester.pumpAndSettle();
      expect(controller.isKindVisible(PairKind.photoWithoutRaw), isTrue);
      expect(find.text('lonely.jpg'), findsOneWidget);
    });

    testWidgets('cancelling the confirm dialog trashes nothing', (
      tester,
    ) async {
      final fake = FakeEngineRunner();
      final controller = openReview(fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Move 1 selected to Trash'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Move 1 RAW files'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fake.calls, isEmpty);
      expect(controller.lastSummary, isNull);
    });

    testWidgets(
      'confirming trashes exactly the selected paths and shows done',
      (tester) async {
        final fake = FakeEngineRunner(
          events: const [
            DoneEvent({'pruned_trashed': 1}),
          ],
        );
        final controller = openReview(fake);
        await _pump(tester, controller);

        await tester.tap(find.text('Move 1 selected to Trash'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move to Trash'));
        await tester.pumpAndSettle();

        expect(fake.calls, contains('trashPaths'));
        expect(fake.lastTrashedPaths, ['/library/orphan.raf']);
        expect(find.text('Done — back to library'), findsOneWidget);
      },
    );

    testWidgets('deselecting all disables the primary button', (tester) async {
      final controller = openReview(FakeEngineRunner());
      await _pump(tester, controller);

      // Tap the per-row orphan checkbox to deselect it.
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(find.text('Move 0 selected to Trash'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Move 0 selected to Trash'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the select-all header checkbox clears then restores', (
      tester,
    ) async {
      final controller = openReview(FakeEngineRunner());
      await _pump(tester, controller);

      // First (header) checkbox is currently fully selected -> tap clears all.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(controller.selectedCount, 0);
      // Tap again -> selects all orphans.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(controller.selectedCount, 1);
    });

    testWidgets('a non-matching filter shows the empty state', (tester) async {
      final controller = openReview(FakeEngineRunner());
      await _pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'zzzz-nomatch');
      await tester.pumpAndSettle();
      expect(find.text('No files match.'), findsOneWidget);
    });

    testWidgets('the done view lists the per-file rows', (tester) async {
      final fake = FakeEngineRunner(
        events: const [
          ItemEvent(
            PhotoRow(
              path: '/library/orphan.raf',
              status: PhotoStatus.prunedTrashed,
            ),
          ),
          DoneEvent({'pruned_trashed': 1}),
        ],
      );
      final controller = openReview(fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Move 1 selected to Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();

      expect(find.text('Recent results'), findsOneWidget);
      expect(find.text('orphan.raf'), findsWidgets);
    });

    testWidgets('the review surface handles a missing pairing', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScreen(AppScreen.action, action: LibraryAction.pruneRaw);
      await _pump(tester, controller);
      expect(find.text('No library scanned.'), findsOneWidget);
    });
  });

  group('action screen routing', () {
    testWidgets('the explore arm renders nothing as an action body', (
      tester,
    ) async {
      // Explore is normally a full screen, never an action; forcing it as the
      // action exercises the exhaustive switch's explore arm (a SizedBox).
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan())
        ..debugSetScreen(AppScreen.action, action: LibraryAction.explore);
      await _pump(tester, controller);

      // The action chrome (title) shows, but no tag/map/prune body renders.
      expect(find.byType(TagAction), findsNothing);
      expect(find.byType(MapAction), findsNothing);
      expect(find.byType(PruneAction), findsNothing);
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

    testWidgets('prune shows a live progress bar while trashing', (
      tester,
    ) async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ProgressEvent(done: 0, total: 1)],
      );
      addTearDown(fake.release);
      final controller = openWith(LibraryAction.pruneRaw, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Move 1 selected to Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pump();
      await tester.pump();
      expect(controller.running, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('an in-flight error renders the banner above the progress', (
      tester,
    ) async {
      // An ErrorEvent arrives while the stream is still open: the run stays
      // active so the running column shows the error banner over the progress.
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ErrorEvent('mid-flight prune fail')],
      );
      addTearDown(fake.release);
      final controller = openWith(LibraryAction.pruneRaw, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Move 1 selected to Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pump();
      await tester.pump();

      expect(controller.running, isTrue);
      expect(controller.errorMessage, 'mid-flight prune fail');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('an in-flight tag error renders the banner over progress', (
      tester,
    ) async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ErrorEvent('mid-flight tag fail')],
      );
      addTearDown(fake.release);
      final controller = openWith(LibraryAction.tag, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Tag 1 photos'));
      await tester.pump();
      await tester.pump();

      expect(controller.running, isTrue);
      expect(controller.errorMessage, 'mid-flight tag fail');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      fake.release();
      await tester.pumpAndSettle();
    });

    testWidgets('prune surfaces an error event', (tester) async {
      final fake = FakeEngineRunner(events: const [ErrorEvent('prune boom')]);
      final controller = openWith(LibraryAction.pruneRaw, fake);
      await _pump(tester, controller);

      await tester.tap(find.text('Move 1 selected to Trash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
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

      // On hover the card's border takes the primary accent (the onEnter path).
      final scheme = Theme.of(
        tester.element(find.text('Generate map')),
      ).colorScheme;
      Border borderOf() {
        final container = tester.widget<AnimatedContainer>(
          find
              .ancestor(
                of: find.text('Generate map'),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
        return (container.decoration! as BoxDecoration).border! as Border;
      }

      expect(borderOf().top.color, scheme.primary);

      // Moving the pointer off the card fires onExit and drops the accent.
      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(borderOf().top.color, isNot(scheme.primary));
    });
  });
}
