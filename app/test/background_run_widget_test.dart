import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';

import 'package:stunda/main.dart';
import 'package:stunda/src/screens/action_screen.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/action_card.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id) => ToolStatus(
  id: id,
  name: id,
  present: true,
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

/// The CircularProgressIndicator overlaying the tag card, if any.
Finder _tagCardRing() => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is ActionCard && w.action == LibraryAction.tag,
  ),
  matching: find.byType(CircularProgressIndicator),
);

void main() {
  testWidgets('a running action shows a progress ring on its workspace card', (
    tester,
  ) async {
    final fake = FakeEngineRunner(keepOpen: true);
    addTearDown(fake.release);
    final controller = AppController(runner: fake)
      ..debugSetToolkit([_tool('exiftool')])
      ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']));
    await _pump(tester, controller);

    // No ring before a run.
    expect(_tagCardRing(), findsNothing);

    // Start a run, then return to the workspace — the run keeps going.
    controller.openAction(LibraryAction.tag);
    final run = controller.runTag();
    controller.backToLibrary();
    await tester.pump();

    expect(controller.screen, AppScreen.workspace);
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    // The card now overlays a progress ring while the run continues.
    expect(_tagCardRing(), findsOneWidget);
    expect(controller.runStateFor(LibraryAction.tag).running, isTrue);

    fake.release();
    await run;
    await tester.pump();
    // Ring gone once the run finishes.
    expect(_tagCardRing(), findsNothing);
  });

  testWidgets(
    'a finished off-screen run pulses an attention badge, cleared on open',
    (tester) async {
      final fake = FakeEngineRunner()
        ..duplicateGroups = [
          DuplicateGroup(
            best: HashedFile(
              path: '/best.jpg',
              width: 10,
              height: 10,
              fileSize: 1,
              basename: 'best.jpg',
              isRaw: false,
            ),
            duplicates: [
              HashedFile(
                path: '/dup.jpg',
                width: 10,
                height: 10,
                fileSize: 1,
                basename: 'dup.jpg',
                isRaw: false,
              ),
            ],
          ),
        ];
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/best.jpg', '/dup.jpg']));
      await _pump(tester, controller);

      // Run duplicates while the user is on the workspace (off the action).
      controller.openAction(LibraryAction.duplicates);
      controller.backToLibrary();
      await controller.runFindDuplicates();
      await tester.pump();

      // The badge pulses on the duplicates card (never pumpAndSettle: it loops).
      expect(find.byTooltip('Needs your review'), findsOneWidget);

      // Opening the action clears the badge.
      controller.openAction(LibraryAction.duplicates);
      await tester.pump();
      expect(controller.screen, AppScreen.action);
      expect(find.byTooltip('Needs your review'), findsNothing);
    },
  );

  testWidgets('the action screen offers Cancel while running and back works', (
    tester,
  ) async {
    final fake = FakeEngineRunner(keepOpen: true);
    addTearDown(fake.release);
    final controller = AppController(runner: fake)
      ..debugSetToolkit([_tool('exiftool')])
      ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']))
      ..openAction(LibraryAction.tag);
    await _pump(tester, controller);

    final run = controller.runTag();
    await tester.pump();

    // The Cancel affordance is present while running; Library back is enabled.
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.byType(ActionScreen), findsOneWidget);

    // Cancelling stops the run and returns the action to idle.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(controller.runStateFor(LibraryAction.tag).running, isFalse);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);

    fake.release();
    await run;
  });

  group('close-while-running guard', () {
    // Drive the registered AppLifecycleListener.onExitRequested via a platform
    // "System.requestAppExit" message so the warning SnackBar wiring is
    // exercised, without letting the framework actually tear down.
    Future<String?> requestExit(WidgetTester tester) async {
      String? result;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/platform',
        const JSONMethodCodec().encodeMethodCall(
          const MethodCall('System.requestAppExit'),
        ),
        (data) {
          final reply =
              const JSONMethodCodec().decodeEnvelope(data!)
                  as Map<Object?, Object?>;
          result = reply['response'] as String?;
        },
      );
      return result;
    }

    testWidgets('blocks exit and warns while a run is in flight', (
      tester,
    ) async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final controller = AppController(runner: fake)
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']));
      await _pump(tester, controller);

      final run = controller.runTag();
      await tester.pump();

      final response = await requestExit(tester);
      expect(response, 'cancel');

      await tester.pump();
      expect(
        find.text('A process is still running — cancel it before quitting.'),
        findsOneWidget,
      );

      // Cancel the run so teardown isn't left with an open stream.
      controller.cancelActiveRun();
      fake.release();
      await run;
    });

    testWidgets('allows exit when nothing is running', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan());
      await _pump(tester, controller);

      final response = await requestExit(tester);
      expect(response, 'exit');
      await tester.pump();
      expect(
        find.text('A process is still running — cancel it before quitting.'),
        findsNothing,
      );
    });
  });
}
