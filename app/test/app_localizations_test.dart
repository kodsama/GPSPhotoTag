import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/i18n/app_localizations.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/settings_dialog.dart';

import 'support/fakes.dart';

void main() {
  group('resolveLocale', () {
    test('a valid override wins over the system locale', () {
      expect(
        resolveLocale(override: 'sv', system: const Locale('de')),
        const Locale('sv'),
      );
    });

    test(
      'an unsupported override is ignored, falling to the system locale',
      () {
        expect(
          resolveLocale(override: 'xx', system: const Locale('ja')),
          const Locale('ja'),
        );
      },
    );

    test('a supported system locale is used when there is no override', () {
      expect(resolveLocale(system: const Locale('fr')), const Locale('fr'));
    });

    test('an unsupported system locale falls back to English', () {
      expect(resolveLocale(system: const Locale('xx')), const Locale('en'));
    });

    test('no override and no system locale falls back to English', () {
      expect(resolveLocale(), const Locale('en'));
    });
  });

  group('AppLocalizations.delegate', () {
    test('isSupported matches exactly the nine shipped locales', () {
      const d = AppLocalizations.delegate;
      for (final code in kSupportedLanguageCodes) {
        expect(d.isSupported(Locale(code)), isTrue, reason: code);
      }
      expect(d.isSupported(const Locale('xx')), isFalse);
      expect(kSupportedLanguageCodes.length, 9);
    });

    test('loads English synchronously from the bundled map', () async {
      final loc = await AppLocalizations.delegate.load(const Locale('en'));
      expect(loc.locale, const Locale('en'));
      expect(loc.tr('settings_done'), 'Done');
    });

    test('loads a non-English locale\'s JSON asset', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final loc = await AppLocalizations.delegate.load(const Locale('fr'));
      expect(loc.locale, const Locale('fr'));
      expect(loc.tr('settings_done'), 'Terminé');
    });

    test('an unsupported locale resolves to the English map', () async {
      final loc = await AppLocalizations.delegate.load(const Locale('xx'));
      expect(loc.locale, const Locale('en'));
      expect(loc.tr('settings_done'), 'Done');
    });
  });

  group('AppLocalizations.tr', () {
    test('returns the active locale string for a known key', () {
      final loc = AppLocalizations(const Locale('fr'), const {
        'settings_done': 'Terminé',
      });
      expect(loc.tr('settings_done'), 'Terminé');
    });

    test('falls back to English for a key missing in the active locale', () {
      // 'settings_done' is absent from this (sparse) French map.
      final loc = AppLocalizations(const Locale('fr'), const {});
      expect(loc.tr('settings_done'), 'Done');
    });

    test('returns the key itself for a genuinely unknown key', () {
      final loc = AppLocalizations(const Locale('en'), kEnglishStrings);
      expect(loc.tr('totally_unknown_key'), 'totally_unknown_key');
    });

    test('interpolates {placeholders} from params', () {
      final loc = AppLocalizations(const Locale('en'), const {
        'greet': 'Hi {name}, {n} new',
      });
      expect(loc.tr('greet', {'name': 'Sam', 'n': 3}), 'Hi Sam, 3 new');
    });

    test('leaves a placeholder intact when no matching param is given', () {
      final loc = AppLocalizations(const Locale('en'), const {
        'greet': 'Hi {name}',
      });
      expect(loc.tr('greet', {'other': 1}), 'Hi {name}');
    });
  });

  group('context.tr without a delegate', () {
    testWidgets('falls back to the compile-time English map', (tester) async {
      late String value;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              value = context.tr('settings_done');
              return const SizedBox();
            },
          ),
        ),
      );
      expect(value, 'Done');
    });
  });

  group('Language selector', () {
    Future<void> pumpApp(WidgetTester tester, AppController controller) async {
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ControllerScope(
          controller: controller,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MaterialApp(
              locale: controller.localeCode == null
                  ? null
                  : Locale(controller.localeCode!),
              supportedLocales: kSupportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              localeResolutionCallback: (device, supported) => resolveLocale(
                override: controller.localeCode,
                system: device,
              ),
              home: Scaffold(body: SettingsDialog(controller: controller)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('selecting a language persists the override and switches a '
        'visible string', (tester) async {
      final controller = AppController(runner: FakeEngineRunner());
      await pumpApp(tester, controller);

      // English by default: the Done button reads "Done".
      expect(find.text('Done'), findsOneWidget);
      expect(controller.localeCode, isNull);

      // Open the language dropdown and pick French.
      await tester.tap(find.byKey(const Key('settings-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Français').last);
      // The override applies immediately; the French JSON asset load is real
      // async I/O, so pump inside runAsync to let it actually complete and the
      // tree rebuild with the French strings.
      await tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });

      // The override is persisted on the controller…
      expect(controller.localeCode, 'fr');
      // …and a visible string switched to French.
      expect(find.text('Terminé'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
    });
  });

  group('Settings — Home actions section', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      AppController controller,
    ) async {
      tester.view.physicalSize = const Size(1400, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ControllerScope(
          controller: controller,
          child: MaterialApp(
            home: Scaffold(body: SettingsDialog(controller: controller)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lists every action with a show/hide toggle', (tester) async {
      final controller = AppController(runner: FakeEngineRunner());
      await pumpSettings(tester, controller);

      // The section header and one labelled row per action.
      expect(find.text('Home actions'), findsOneWidget);
      expect(find.text('Tag with GPS'), findsOneWidget);
      expect(find.text('Explore on map'), findsOneWidget);
      expect(find.text('Shrink picture library'), findsOneWidget);
      // A drag handle + a switch per action in the section.
      expect(find.byTooltip('Show or hide this action card'), findsNWidgets(5));
      expect(
        find.byTooltip('Drag to reorder the action cards'),
        findsNWidgets(5),
      );
    });

    testWidgets('toggling a switch hides the action on the controller', (
      tester,
    ) async {
      final controller = AppController(runner: FakeEngineRunner());
      await pumpSettings(tester, controller);

      expect(controller.homeActions.isVisible(LibraryAction.explore), isTrue);
      // The first row is Explore (default order). Tap its switch.
      await tester.tap(find.byType(Switch).first);
      await tester.pump();

      expect(controller.homeActions.isVisible(LibraryAction.explore), isFalse);
    });
  });
}
