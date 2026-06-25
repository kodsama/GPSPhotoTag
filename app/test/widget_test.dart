import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/screens/scanning_screen.dart';
import 'package:stunda/src/screens/welcome_screen.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/widgets/activity_log_panel.dart';
import 'package:stunda/src/widgets/warning_banner.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true, String? version}) =>
    ToolStatus(
      id: id,
      name: id,
      present: present,
      version: version,
      purpose: 'unlocks $id',
      required: false,
    );

Future<void> _pumpApp(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(StundaApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('AppShell renders the header and the welcome screen', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool', version: '12.0')]);
    await _pumpApp(tester, controller);

    expect(find.text('Stunda'), findsWidgets);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(controller.screen, AppScreen.welcome);
    expect(find.text('Choose photo library'), findsOneWidget);
  });

  testWidgets('the scanning screen shows live tallies and the folder name', (
    tester,
  ) async {
    // A scan stream that emits progress then holds open, so the scanning
    // screen (with the folder name) stays on screen for assertions.
    final fake = FakeEngineRunner(
      keepOpen: true,
      scanEvents: const [ScanProgressEvent(ScanProgress(files: 5, photos: 3))],
    );
    addTearDown(fake.release);
    final controller = AppController(runner: fake)
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);
    unawaited(controller.startScan('/Users/me/Pictures'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ScanningScreen), findsOneWidget);
    expect(find.text('Scanning your library…'), findsOneWidget);
    expect(find.text('Pictures'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('3'), findsWidgets); // live photo tally

    // Release and pump a frame (no settle: the indeterminate bar never stops).
    fake.release();
    await tester.pump();
  });

  testWidgets('picking a library scans it and lands on the workspace', (
    tester,
  ) async {
    final controller = AppController(
      runner: FakeEngineRunner(
        scanEvents: [
          const ScanProgressEvent(ScanProgress(files: 2, photos: 1)),
          ScanDoneEvent(fakeScan(gpxFiles: const ['/library/t.gpx'])),
        ],
      ),
      pickFolder: () async => '/library',
    )..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    await tester.tap(find.text('Choose photo library'));
    await tester.pumpAndSettle();

    expect(controller.screen, AppScreen.workspace);
    expect(find.byType(WorkspaceScreen), findsOneWidget);
  });

  group('warning banner', () {
    testWidgets('shows when an environment warning is set', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool', present: false)],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(find.byType(WarningBanner), findsOneWidget);
      expect(find.textContaining("ExifTool couldn't start"), findsOneWidget);
    });

    testWidgets('hides after the close button is tapped', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool', present: false)],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();

      expect(controller.warningDismissed, isTrue);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });

    testWidgets('renders nothing when no warning is set', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool')],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(controller.environmentWarning, isNull);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });
  });

  testWidgets('MCP chip renders in the header', (tester) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);
    expect(find.textContaining('MCP'), findsOneWidget);
  });

  testWidgets('the settings menu appearance item flips the theme', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    // The standalone toggle is gone — the theme lives in the overflow menu.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Appearance:'));
    await tester.pumpAndSettle();
    expect(controller.themeMode, isNot(ThemeMode.system));
  });

  testWidgets('activity-log panel opens on FAB tap and shows entries', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')])
      ..debugAddLog('first event')
      ..debugAddLog('second event');
    await _pumpApp(tester, controller);

    expect(find.byType(ActivityLogPanel), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Activity log'), findsOneWidget);
    expect(find.text('first event'), findsOneWidget);
    expect(find.text('second event'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
