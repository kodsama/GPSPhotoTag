import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/action_run_state.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

HashedFile _hf(String path) => HashedFile(
  path: path,
  hash: 0,
  width: 10,
  height: 10,
  fileSize: 1,
  basename: path,
  isRaw: false,
);

void main() {
  group('per-action run state', () {
    test('an action is idle before any run', () {
      final c = AppController(runner: FakeEngineRunner());
      expect(c.runStateFor(LibraryAction.tag), ActionRunState.idle);
      expect(c.anyRunning, isFalse);
      expect(c.actionsNeedingReview, isEmpty);
      expect(c.exitDecision, AppExitResponse.exit);
    });

    test('a run flips the owner to running then back', () async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final c = AppController(runner: fake)..debugSetScan(fakeScan());

      final run = c.runTag();
      expect(c.runStateFor(LibraryAction.tag).running, isTrue);
      expect(c.anyRunning, isTrue);
      expect(c.exitDecision, AppExitResponse.cancel);

      fake.release();
      await run;
      expect(c.runStateFor(LibraryAction.tag).running, isFalse);
      expect(c.anyRunning, isFalse);
    });

    test(
      'a tag run finished off-screen needs review; on-screen it does not',
      () async {
        // Off-screen: the user navigated to the workspace mid-run.
        final c = AppController(runner: FakeEngineRunner())
          ..debugSetScan(fakeScan())
          ..openAction(LibraryAction.tag);
        c.backToLibrary();
        await c.runTag();
        expect(c.runStateFor(LibraryAction.tag).needsReview, isTrue);
        expect(c.actionsNeedingReview, {LibraryAction.tag});

        // On-screen: the user stays on the action and watches it finish.
        final c2 = AppController(runner: FakeEngineRunner())
          ..debugSetScan(fakeScan())
          ..openAction(LibraryAction.tag);
        await c2.runTag();
        expect(c2.runStateFor(LibraryAction.tag).needsReview, isFalse);
      },
    );

    test('opening an action clears its attention badge', () async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan())
        ..openAction(LibraryAction.tag);
      c.backToLibrary();
      await c.runTag();
      expect(c.runStateFor(LibraryAction.tag).attention, isTrue);

      c.openAction(LibraryAction.tag);
      expect(c.runStateFor(LibraryAction.tag).attention, isFalse);
      expect(c.actionsNeedingReview, isEmpty);
    });
  });

  group('runs survive navigation', () {
    test('backToLibrary mid-run keeps the run alive (still running)', () async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan())
        ..openAction(LibraryAction.tag);

      final run = c.runTag();
      expect(c.runStateFor(LibraryAction.tag).running, isTrue);

      // Navigating back must NOT cancel the run.
      c.backToLibrary();
      expect(c.screen, AppScreen.workspace);
      expect(c.runStateFor(LibraryAction.tag).running, isTrue);
      expect(fake.calls, contains('tag'));

      fake.release();
      await run;
      expect(c.runStateFor(LibraryAction.tag).running, isFalse);
    });

    test('reopening a running action keeps its live state', () async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan())
        ..openAction(LibraryAction.tag);
      final run = c.runTag();
      c.backToLibrary();
      // Reopening does not reset the still-running run.
      c.openAction(LibraryAction.tag);
      expect(c.running, isTrue);
      expect(c.runStateFor(LibraryAction.tag).running, isTrue);
      fake.release();
      await run;
    });
  });

  group('cancellation', () {
    test(
      'cancel sets the action idle and leaves no destructive side effect',
      () async {
        final fake = FakeEngineRunner(keepOpen: true);
        addTearDown(fake.release);
        final c = AppController(runner: fake)
          ..debugSetScan(fakeScan(photos: const ['/a.raf']))
          ..openAction(LibraryAction.pruneRaw);

        final run = c.runTrashSelected();
        expect(c.runStateFor(LibraryAction.pruneRaw).running, isTrue);

        c.cancelAction(LibraryAction.pruneRaw);
        expect(c.runStateFor(LibraryAction.pruneRaw), ActionRunState.idle);
        expect(c.running, isFalse);
        expect(c.anyRunning, isFalse);
        // A cancelled run never reports a completed summary (no trash committed
        // in observable state).
        expect(c.lastSummary, isNull);
        fake.release();
        await run;
      },
    );

    test('cancelActiveRun cancels whichever action is running', () async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final c = AppController(runner: fake)..debugSetScan(fakeScan());
      final run = c.runTag();
      expect(c.anyRunning, isTrue);
      c.cancelActiveRun();
      expect(c.anyRunning, isFalse);
      fake.release();
      await run;
    });

    test('cancelActiveRun is a no-op when nothing runs', () {
      final c = AppController(runner: FakeEngineRunner());
      c.cancelActiveRun(); // must not throw
      expect(c.anyRunning, isFalse);
    });

    test('cancel on an idle action is a no-op', () {
      final c = AppController(runner: FakeEngineRunner());
      c.cancelAction(LibraryAction.tag);
      expect(c.runStateFor(LibraryAction.tag), ActionRunState.idle);
    });

    test('cancelling a hashing run discards its result', () async {
      final fake = FakeEngineRunner()
        ..duplicatesGate = Completer<void>()
        ..duplicateGroups = [
          DuplicateGroup(best: _hf('/best.jpg'), duplicates: [_hf('/dup.jpg')]),
        ];
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/best.jpg', '/dup.jpg']))
        ..openAction(LibraryAction.duplicates);

      final run = c.runFindDuplicates();
      expect(c.runStateFor(LibraryAction.duplicates).running, isTrue);

      c.cancelAction(LibraryAction.duplicates);
      expect(c.runStateFor(LibraryAction.duplicates), ActionRunState.idle);
      expect(c.findingDuplicates, isFalse);

      // Let the (now-ignored) hashing future complete.
      fake.duplicatesGate!.complete();
      await run;
      // The cancelled result was discarded, not folded into pairs.
      expect(c.duplicatePairs, isNull);
    });
  });

  group('progress fraction on the card', () {
    test('a determinate tag run tracks the done/total fraction', () async {
      final fake = FakeEngineRunner(
        keepOpen: true,
        events: const [ProgressEvent(done: 1, total: 4)],
      );
      addTearDown(fake.release);
      final c = AppController(runner: fake)..debugSetScan(fakeScan());
      final run = c.runTag();
      await Future<void>.delayed(Duration.zero);
      expect(c.runStateFor(LibraryAction.tag).progress, closeTo(0.25, 1e-9));
      fake.release();
      await run;
    });

    test('a hashing run exposes its fraction via the card state', () async {
      final fake = FakeEngineRunner()..duplicatesGate = Completer<void>();
      final c = AppController(runner: fake)
        ..debugSetScan(fakeScan(photos: const ['/a.jpg', '/b.jpg', '/c.jpg']))
        ..openAction(LibraryAction.duplicates);
      final run = c.runFindDuplicates();
      fake.lastOnProgress!(2, 3);
      expect(
        c.runStateFor(LibraryAction.duplicates).progress,
        closeTo(2 / 3, 1e-9),
      );
      fake.duplicatesGate!.complete();
      await run;
    });

    test('a finished hashing run with no matches returns to idle', () async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScan(fakeScan(photos: const ['/a.jpg', '/b.jpg']))
        ..openAction(LibraryAction.duplicates);
      c.backToLibrary();
      await c.runFindDuplicates();
      expect(c.runStateFor(LibraryAction.duplicates), ActionRunState.idle);
    });

    test(
      'a finished hashing run with matches, viewed off-screen, badges',
      () async {
        final fake = FakeEngineRunner()
          ..duplicateGroups = [
            DuplicateGroup(
              best: _hf('/best.jpg'),
              duplicates: [_hf('/dup.jpg')],
            ),
          ];
        final c = AppController(runner: fake)
          ..debugSetScan(fakeScan(photos: const ['/best.jpg', '/dup.jpg']))
          ..openAction(LibraryAction.duplicates);
        c.backToLibrary();
        await c.runFindDuplicates();
        expect(c.runStateFor(LibraryAction.duplicates).attention, isTrue);
      },
    );
  });

  group('changeLibrary resets run state', () {
    test('clears any in-flight run state', () async {
      final fake = FakeEngineRunner(keepOpen: true);
      addTearDown(fake.release);
      final c = AppController(runner: fake)..debugSetScan(fakeScan());
      final run = c.runTag();
      expect(c.anyRunning, isTrue);
      c.changeLibrary();
      expect(c.anyRunning, isFalse);
      expect(c.actionsNeedingReview, isEmpty);
      fake.release();
      await run;
    });
  });
}
