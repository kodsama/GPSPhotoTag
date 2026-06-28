// The home-screen action customization: the pure order/visibility model
// (HomeActionsConfig), its tolerant (de)serialization, and the controller +
// AppPrefs wiring that persists the user's choices.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_prefs.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

void main() {
  group('HomeActionsConfig (pure model)', () {
    test('standard is the canonical order (Explore first), all visible', () {
      const cfg = HomeActionsConfig.standard;
      expect(cfg.order, LibraryAction.all);
      expect(cfg.order.first, LibraryAction.explore);
      expect(cfg.hidden, isEmpty);
      expect(cfg.visibleInOrder, LibraryAction.all);
    });

    test('normalized appends missing actions in canonical order', () {
      // A partial order (only two actions) is completed with the rest.
      final cfg = HomeActionsConfig.normalized(
        order: const [LibraryAction.shrink, LibraryAction.tag],
        hidden: const [],
      );
      expect(cfg.order.length, LibraryAction.all.length);
      expect(cfg.order.take(2), [LibraryAction.shrink, LibraryAction.tag]);
      // Every action appears exactly once.
      expect(cfg.order.toSet(), LibraryAction.all.toSet());
    });

    test('normalized drops duplicate entries in the order', () {
      final cfg = HomeActionsConfig.normalized(
        order: const [
          LibraryAction.tag,
          LibraryAction.tag,
          LibraryAction.explore,
        ],
        hidden: const [],
      );
      expect(cfg.order.where((a) => a == LibraryAction.tag).length, 1);
      expect(cfg.order.toSet(), LibraryAction.all.toSet());
    });

    test('reorder moves an action and clamps out-of-range targets', () {
      const cfg = HomeActionsConfig.standard;
      // Move the second action to the front.
      final moved = cfg.reorder(1, 0);
      expect(moved.order.first, LibraryAction.all[1]);
      // Out-of-range source is a no-op (returns the same instance).
      expect(identical(cfg.reorder(99, 0), cfg), isTrue);
      // No-op move returns the same instance.
      expect(identical(cfg.reorder(0, 0), cfg), isTrue);
      // A too-large target clamps to the last slot.
      final toEnd = cfg.reorder(0, 999);
      expect(toEnd.order.last, LibraryAction.all.first);
    });

    test('withVisibility hides and shows an action without touching order', () {
      const cfg = HomeActionsConfig.standard;
      final hidden = cfg.withVisibility(LibraryAction.tag, false);
      expect(hidden.isVisible(LibraryAction.tag), isFalse);
      expect(hidden.visibleInOrder, isNot(contains(LibraryAction.tag)));
      expect(hidden.order, cfg.order); // order unchanged
      final shown = hidden.withVisibility(LibraryAction.tag, true);
      expect(shown.isVisible(LibraryAction.tag), isTrue);
      expect(shown.visibleInOrder, contains(LibraryAction.tag));
    });

    test('visibleInOrder reflects both order and hidden flags', () {
      final cfg = HomeActionsConfig.standard
          .reorder(0, LibraryAction.all.length - 1) // Explore to the end
          .withVisibility(LibraryAction.tag, false);
      expect(cfg.visibleInOrder, isNot(contains(LibraryAction.tag)));
      expect(cfg.visibleInOrder.last, LibraryAction.explore);
    });

    test('toJson/fromJson round-trips order and hidden set', () {
      final cfg = HomeActionsConfig.standard
          .reorder(0, 2)
          .withVisibility(LibraryAction.duplicates, false);
      final back = HomeActionsConfig.fromJson(cfg.toJson());
      expect(back.order, cfg.order);
      expect(back.hidden, cfg.hidden);
    });

    group('fromJson tolerance', () {
      test('null/garbage yields the standard config', () {
        expect(HomeActionsConfig.fromJson(null).order, LibraryAction.all);
        expect(HomeActionsConfig.fromJson('nope').order, LibraryAction.all);
        expect(HomeActionsConfig.fromJson(42).hidden, isEmpty);
      });

      test('unknown action ids are dropped from order and hidden', () {
        final cfg = HomeActionsConfig.fromJson({
          'order': ['tag', 'made_up_action', 'explore'],
          'hidden': ['also_fake', 'duplicates'],
        });
        // Known ones keep their order; the unknown is gone; the rest append.
        expect(cfg.order.take(2), [LibraryAction.tag, LibraryAction.explore]);
        expect(cfg.order.toSet(), LibraryAction.all.toSet());
        expect(cfg.hidden, {LibraryAction.duplicates});
      });

      test('an action missing from a saved order is appended VISIBLE', () {
        // A saved order from before `shrink` existed: it must still appear, and
        // visible (not hidden), so a newly-added action shows for old users.
        final cfg = HomeActionsConfig.fromJson({
          'order': ['explore', 'tag', 'prune_raw', 'duplicates'],
          'hidden': <String>[],
        });
        expect(cfg.order, contains(LibraryAction.shrink));
        expect(cfg.isVisible(LibraryAction.shrink), isTrue);
      });
    });
  });

  group('AppController home actions', () {
    test(
      'defaults to the standard config / all visible in canonical order',
      () {
        final c = AppController(runner: FakeEngineRunner());
        expect(c.visibleActionsInOrder, LibraryAction.all);
        expect(c.homeActions.order, LibraryAction.all);
      },
    );

    test('reordering changes the order, persists, and notifies', () {
      final prefs = AppPrefs();
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      var notifies = 0;
      c.addListener(() => notifies++);
      c.reorderHomeAction(0, 2);
      expect(c.homeActions.order.first, isNot(LibraryAction.all.first));
      expect(prefs.homeActions.order, c.homeActions.order);
      expect(notifies, 1);
      // A no-op reorder does not notify again.
      c.reorderHomeAction(0, 0);
      expect(notifies, 1);
    });

    test('hiding an action drops it from visibleActionsInOrder + persists', () {
      final prefs = AppPrefs();
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      var notifies = 0;
      c.addListener(() => notifies++);
      c.setHomeActionVisible(LibraryAction.tag, false);
      expect(c.visibleActionsInOrder, isNot(contains(LibraryAction.tag)));
      expect(prefs.homeActions.isVisible(LibraryAction.tag), isFalse);
      expect(notifies, 1);
      // Setting it to the same visibility is a no-op (no extra notify).
      c.setHomeActionVisible(LibraryAction.tag, false);
      expect(notifies, 1);
    });

    test('a controller applies the loaded home-actions config', () {
      final prefs = AppPrefs(
        homeActions: HomeActionsConfig.standard.withVisibility(
          LibraryAction.shrink,
          false,
        ),
      );
      final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
      expect(c.visibleActionsInOrder, isNot(contains(LibraryAction.shrink)));
    });

    group('persistence round-trip', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('home_actions'));
      tearDown(() => dir.deleteSync(recursive: true));

      test('order + hidden survive save then load', () async {
        final prefs = await AppPrefs.load(dir.path);
        final c = AppController(runner: FakeEngineRunner(), prefs: prefs);
        c.reorderHomeAction(0, 3);
        c.setHomeActionVisible(LibraryAction.duplicates, false);
        await prefs.save();

        final reloaded = await AppPrefs.load(dir.path);
        expect(reloaded.homeActions.order, c.homeActions.order);
        expect(reloaded.homeActions.isVisible(LibraryAction.duplicates), false);
      });
    });
  });
}
