import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/i18n/app_localizations.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/help.dart';

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

AppController _workspaceController() =>
    AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')])
      ..debugSetScan(
        fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
      );

void main() {
  group('topic → section resolution (pure)', () {
    test('every topic maps to an existing Help section anchor', () {
      final anchors = {for (final s in kHelpSections) s.key};
      for (final topic in HelpTopic.values) {
        expect(
          anchors.contains(sectionForTopic(topic)),
          isTrue,
          reason: 'no Help section for $topic',
        );
      }
    });

    test('each action maps to the matching topic', () {
      expect(topicForAction(LibraryAction.tag), HelpTopic.tag);
      expect(topicForAction(LibraryAction.explore), HelpTopic.explore);
      expect(topicForAction(LibraryAction.pruneRaw), HelpTopic.match);
      expect(topicForAction(LibraryAction.duplicates), HelpTopic.duplicates);
      expect(topicForAction(LibraryAction.shrink), HelpTopic.shrink);
    });

    test('the menu + tooltip strings exist in English', () {
      for (final key in [
        'tt_help',
        'help_menu_documentation',
        'help_menu_contextual',
        'help_mode_banner',
        'help_mode_done',
      ]) {
        expect(
          kEnglishStrings.containsKey(key),
          isTrue,
          reason: 'missing $key',
        );
      }
    });

    test('every section anchor is unique', () {
      final keys = [for (final s in kHelpSections) s.key];
      expect(keys.toSet().length, keys.length);
    });
  });

  group('help-mode state transitions (controller)', () {
    test('enter/exit toggles the flag and notifies once each', () {
      final controller = AppController(runner: FakeEngineRunner());
      var notified = 0;
      controller.addListener(() => notified++);

      expect(controller.helpMode, isFalse);
      controller.enterHelpMode();
      expect(controller.helpMode, isTrue);
      controller.enterHelpMode(); // idempotent
      expect(notified, 1);

      controller.exitHelpMode();
      expect(controller.helpMode, isFalse);
      controller.exitHelpMode(); // idempotent
      expect(notified, 2);
    });
  });

  group('the "?" header menu', () {
    testWidgets('lists Documentation and What\'s this?', (tester) async {
      final controller = _workspaceController();
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Documentation and contextual help'));
      await tester.pumpAndSettle();

      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text("What's this?"), findsOneWidget);
    });

    testWidgets('Documentation opens the Help page', (tester) async {
      final controller = _workspaceController();
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Documentation and contextual help'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();

      expect(find.byType(HelpPage), findsOneWidget);
      expect(find.text('Getting started'), findsOneWidget);
    });

    testWidgets('What\'s this? enters help mode and shows the banner', (
      tester,
    ) async {
      final controller = _workspaceController();
      await _pump(tester, controller);

      await tester.tap(find.byTooltip('Documentation and contextual help'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("What's this?"));
      await tester.pumpAndSettle();

      expect(controller.helpMode, isTrue);
      expect(find.text('Click any control to see its help.'), findsOneWidget);
      // The body shows the help cursor.
      final region = tester.widgetList<MouseRegion>(find.byType(MouseRegion));
      expect(region.any((r) => r.cursor == SystemMouseCursors.help), isTrue);
    });

    testWidgets('Done exits help mode and hides the banner', (tester) async {
      final controller = _workspaceController()..enterHelpMode();
      await _pump(tester, controller);

      expect(find.text('Click any control to see its help.'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(controller.helpMode, isFalse);
      expect(find.text('Click any control to see its help.'), findsNothing);
    });

    testWidgets('Esc exits help mode', (tester) async {
      final controller = _workspaceController()..enterHelpMode();
      await _pump(tester, controller);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.helpMode, isFalse);
    });
  });

  group('HelpTarget tap behaviour', () {
    testWidgets(
      'in help mode, tapping an action card opens Help at its section and '
      'does NOT open the action',
      (tester) async {
        final controller = _workspaceController()..enterHelpMode();
        await _pump(tester, controller);

        // The Duplicates card is wrapped in a HelpTarget(topic: duplicates):
        // its overlay absorbs the tap (the painted child is behind an
        // IgnorePointer), so target the card text location with warnIfMissed
        // off — the tap deliberately lands on the absorbing overlay.
        await tester.tap(find.text('Find duplicates'), warnIfMissed: false);
        await tester.pumpAndSettle();

        // Help page is shown at the duplicates section; the underlying card's
        // openAction was NOT performed (we're not on the action screen).
        expect(find.byType(HelpPage), findsOneWidget);
        expect(controller.screen, isNot(AppScreen.action));
        // One use exits help mode.
        expect(controller.helpMode, isFalse);
      },
    );

    testWidgets(
      'with help mode OFF, tapping a card opens the action normally',
      (tester) async {
        final controller = _workspaceController();
        await _pump(tester, controller);

        await tester.tap(find.text('Find duplicates'));
        await tester.pumpAndSettle();

        expect(find.byType(HelpPage), findsNothing);
        expect(controller.screen, AppScreen.action);
        expect(controller.action, LibraryAction.duplicates);
      },
    );
  });
}
