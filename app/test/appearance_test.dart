import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_prefs.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/app_background.dart';
import 'package:stunda/src/widgets/glass.dart';
import 'package:stunda/src/widgets/settings_dialog.dart';

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
  group('veilColor', () {
    test('is opaque white in light mode at full opacity', () {
      final c = veilColor(Brightness.light, 1.0);
      expect(c.r, 1.0);
      expect(c.g, 1.0);
      expect(c.b, 1.0);
      expect(c.a, 1.0);
    });

    test('is black in dark mode and carries the given opacity', () {
      final c = veilColor(Brightness.dark, 0.5);
      expect(c.r, 0.0);
      expect(c.g, 0.0);
      expect(c.b, 0.0);
      expect(c.a, closeTo(0.5, 0.001));
    });

    test('clamps an out-of-range opacity to 0..1', () {
      expect(veilColor(Brightness.light, 2.0).a, 1.0);
      expect(veilColor(Brightness.light, -1.0).a, 0.0);
    });
  });

  group('contourArcs geometry', () {
    test('produces arcs for a normal canvas', () {
      final arcs = contourArcs(const Size(800, 600));
      expect(arcs, isNotEmpty);
      // Every arc has a positive radius and a full sweep.
      for (final a in arcs) {
        expect(a.radius, greaterThan(0));
        expect(a.sweepAngle, greaterThan(0));
      }
    });

    test('returns nothing for an empty canvas or non-positive spacing', () {
      expect(contourArcs(Size.zero), isEmpty);
      expect(contourArcs(const Size(800, 600), spacing: 0), isEmpty);
    });

    test('tighter spacing yields more arcs', () {
      final few = contourArcs(const Size(800, 600), spacing: 200);
      final many = contourArcs(const Size(800, 600), spacing: 40);
      expect(many.length, greaterThan(few.length));
    });
  });

  testWidgets('default background paints the map motif (no image)', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pump(tester, controller);
    expect(find.byType(AppBackground), findsOneWidget);
    expect(find.byType(MapBackgroundPainter), findsNothing); // it's the painter
    // No image set → the default painter is used (a CustomPaint).
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('an existing background image is shown instead of the map', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('bgimg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/bg.png')..writeAsBytesSync(_tinyPng);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [AppBackground(imagePath: file.path, veil: 0.5)],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  group('header visibility per screen', () {
    testWidgets('present on welcome', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);
      expect(controller.screen, AppScreen.welcome);
      expect(find.byTooltip('Menu'), findsOneWidget);
    });

    testWidgets('present on workspace', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
      await _pump(tester, controller);
      expect(controller.screen, AppScreen.workspace);
      expect(find.byTooltip('Menu'), findsOneWidget);
    });

    testWidgets('absent on scanning', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScreen(AppScreen.scanning);
      await _pump(tester, controller);
      expect(controller.screen, AppScreen.scanning);
      expect(find.byTooltip('Menu'), findsNothing);
    });

    testWidgets('absent on action', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']))
        ..debugSetScreen(AppScreen.action, action: LibraryAction.tag);
      await _pump(tester, controller);
      expect(controller.screen, AppScreen.action);
      expect(find.byTooltip('Menu'), findsNothing);
    });

    testWidgets('absent on explore', (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
        ..debugSetExplore(const <ExplorePhoto>[]);
      await _pump(tester, controller);
      expect(controller.screen, AppScreen.explore);
      expect(find.byTooltip('Menu'), findsNothing);
    });
  });

  group('settings dialog appearance controls', () {
    Future<AppController> openSettings(WidgetTester tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        prefs: AppPrefs(),
      )..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings…'));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('shows the Background section and the MCP status row', (
      tester,
    ) async {
      await openSettings(tester);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Choose image…'), findsOneWidget);
      expect(find.text('Background intensity'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('MCP server'), findsOneWidget);
    });

    testWidgets('the intensity slider drives setBackgroundVeil', (
      tester,
    ) async {
      final controller = await openSettings(tester);
      final before = controller.backgroundVeil;
      // Drag the slider toward its start (lower veil).
      await tester.drag(find.byType(Slider), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(controller.backgroundVeil, lessThan(before));
    });

    testWidgets('Choose image… picks a file and sets it as the background', (
      tester,
    ) async {
      final original = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _FakeFileSelector(
        XFile('/pics/picked.jpg'),
      );
      addTearDown(() => FileSelectorPlatform.instance = original);

      final controller = await openSettings(tester);
      expect(controller.backgroundImagePath, isNull);

      await tester.tap(find.text('Choose image…'));
      await tester.pumpAndSettle();

      // The picked path flowed through _pickImage -> setBackgroundImagePath.
      expect(controller.backgroundImagePath, '/pics/picked.jpg');
      expect(find.text('picked.jpg'), findsOneWidget);
    });

    testWidgets('Choose image… cancelled leaves the background unchanged', (
      tester,
    ) async {
      final original = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _FakeFileSelector(null); // user cancels
      addTearDown(() => FileSelectorPlatform.instance = original);

      final controller = await openSettings(tester);
      await tester.tap(find.text('Choose image…'));
      await tester.pumpAndSettle();
      expect(controller.backgroundImagePath, isNull);
    });

    testWidgets('reset button appears only with an image and clears it', (
      tester,
    ) async {
      final controller = await openSettings(tester);
      // No image yet → no reset button.
      expect(find.text('Reset to default'), findsNothing);

      controller.setBackgroundImagePath('/pics/bg.png');
      await tester.pumpAndSettle();
      expect(find.text('bg.png'), findsOneWidget);
      expect(find.text('Reset to default'), findsOneWidget);

      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();
      expect(controller.backgroundImagePath, isNull);
      expect(find.text('Default map style'), findsOneWidget);
    });
  });

  group('mcpStatus', () {
    test('reports running with the bound port', () {
      final s = mcpStatus(running: true, port: 8787);
      expect(s.label, 'running on :8787');
      expect(s.tip, contains('8787'));
    });

    test('reports off when an error is present', () {
      final s = mcpStatus(running: false, error: 'boom');
      expect(s.label, 'off');
      expect(s.tip, contains('boom'));
    });

    test('reports starting before either', () {
      final s = mcpStatus(running: false);
      expect(s.label, 'starting…');
    });
  });
}

/// A minimal valid 1x1 transparent PNG, for the background-image test.
final Uint8List _tinyPng = Uint8List.fromList(const [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, //
  0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, //
  120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1, 122, 94, 171, 63, 0, 0, 0, 0, 73, //
  69, 78, 68, 174, 66, 96, 130,
]);

/// A fake file-picker that returns a pre-set [XFile] (or null for "cancelled")
/// so the settings dialog's "Choose image…" flow is testable without a real
/// platform file dialog.
class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this._result);

  final XFile? _result;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => _result;
}
