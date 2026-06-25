import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_prefs.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/licenses.dart';
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
  group('settings overflow menu', () {
    testWidgets('lists the four items and is the only theme control', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);

      // No standalone toggle anymore.
      expect(find.byTooltip('Switch to light'), findsNothing);
      expect(find.byTooltip('Switch to dark'), findsNothing);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Appearance:'), findsOneWidget);
      expect(find.text('Settings…'), findsOneWidget);
      expect(find.text('Licenses'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('Settings… opens the dialog and changes persisted prefs', (
      tester,
    ) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        prefs: AppPrefs(),
      )..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings…'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);

      // Flip the theme to Light via the appearance segmented button.
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, ThemeMode.light);

      // Change the default RAW mode.
      await tester.tap(find.text('Sidecar'));
      await tester.pumpAndSettle();
      expect(controller.defaultRawMode, RawMode.sidecar);

      // Change the default max time difference.
      await tester.enterText(
        find.byKey(const Key('settings-max-time-diff')),
        '75',
      );
      await tester.pump();
      expect(controller.defaultMaxTimeDiffSeconds, 75);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
    });

    testWidgets('Licenses opens the curated page with Stunda + components', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Licenses'));
      await tester.pumpAndSettle();

      expect(find.byType(LicensesPage), findsOneWidget);
      expect(find.textContaining('GPL-3.0-or-later'), findsOneWidget);
      expect(find.text('ExifTool'), findsOneWidget);
      expect(find.text('Flutter & Dart'), findsOneWidget);
      expect(find.textContaining('flutter_map'), findsWidgets);
    });

    testWidgets('About opens a dialog with the version and tagline', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text('Stunda'), findsWidgets);
      expect(
        find.textContaining('Give every photo its moment.'),
        findsOneWidget,
      );
      expect(find.textContaining('Kodsama'), findsOneWidget);
    });

    testWidgets('the appearance item toggles dark/light directly', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')]);
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Appearance:'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, isNot(ThemeMode.system));
    });
  });

  group('timezone dropdown', () {
    Future<AppController> openTag(WidgetTester tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugSetScan(fakeScan(gpxFiles: const ['/library/t.gpx']))
        ..debugSetScreen(AppScreen.action, action: LibraryAction.tag);
      await _pump(tester, controller);
      return controller;
    }

    testWidgets('defaults to Auto-detect (null timezone)', (tester) async {
      final controller = await openTag(tester);
      expect(find.byType(DropdownMenu<String>), findsOneWidget);
      expect(controller.timezone, isNull);
      // The field shows the Auto-detect selection.
      expect(find.widgetWithText(TextField, 'Auto-detect'), findsOneWidget);
    });

    testWidgets('typing filters and picking a zone calls setTimezone', (
      tester,
    ) async {
      final controller = await openTag(tester);

      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Auto-detect'),
        'Sarajevo',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(MenuItemButton, 'Europe/Sarajevo'));
      await tester.pumpAndSettle();
      expect(controller.timezone, 'Europe/Sarajevo');
    });

    testWidgets('choosing Auto-detect clears the timezone back to null', (
      tester,
    ) async {
      final controller = await openTag(tester);
      controller.setTimezone('Europe/Paris');
      await tester.pump();

      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      // Filter down to the Auto-detect entry so it is on-screen to tap.
      await tester.enterText(
        find.widgetWithText(TextField, 'Europe/Paris'),
        'Auto',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Auto-detect'));
      await tester.pumpAndSettle();
      expect(controller.timezone, isNull);
    });
  });
}
