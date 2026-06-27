import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/actions/shrink_action.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/state/duplicates_model.dart' show sillyWords;
import 'package:stunda/src/state/shrink_model.dart';
import 'package:stunda/src/widgets/run_view.dart';

import 'support/fakes.dart';

/// A [Random] returning a fixed index so the silly word is deterministic.
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value % max;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

Widget _host(AppController c, {Random? random}) => ControllerScope(
  controller: c,
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: ShrinkAction(random: random)),
    ),
  ),
);

const _twoStaged = [
  ShrinkCandidate(
    path: '/library/dup.jpg',
    reason: ShrinkReason.duplicate,
    sizeBytes: 2 * 1024 * 1024,
    hasGps: true,
  ),
  ShrinkCandidate(
    path: '/library/orphan.raf',
    reason: ShrinkReason.orphanRaw,
    sizeBytes: 1024 * 1024,
    hasGps: false,
  ),
];

void main() {
  testWidgets('renders a card for every stage with an include toggle', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    await tester.pumpWidget(_host(c));

    expect(find.text('1. Duplicates'), findsOneWidget);
    expect(find.text('2. Orphans'), findsOneWidget);
    expect(find.text('3. RAW + photo pairs'), findsOneWidget);
    expect(find.text('4. Low quality'), findsOneWidget);
    // One include Switch per stage.
    expect(find.byType(Switch), findsNWidgets(ShrinkStage.values.length));
    expect(
      find.text('No files staged yet. Run a stage above to begin.'),
      findsOneWidget,
    );
  });

  testWidgets('seeded stages show their per-stage counts and the grand total', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));

    // The duplicate stage flagged 1 file (2.0 MB); orphan stage 1 file (1.0 MB).
    expect(find.textContaining('Flagged 1 file(s) · 2.0 MB'), findsOneWidget);
    expect(find.textContaining('Flagged 1 file(s) · 1.0 MB'), findsOneWidget);
    // Grand total across both = 2 files, 3.0 MB.
    expect(
      find.text('Staged for deletion: 2 file(s) · 3.0 MB'),
      findsOneWidget,
    );
    // The summary lists every staged file's reason and GPS indicator.
    expect(find.text('duplicate'), findsWidgets);
    expect(find.text('orphan RAW'), findsWidgets);
    expect(find.text('GPS'), findsWidgets);
    expect(find.text('No GPS'), findsWidgets);
  });

  testWidgets('toggling a stage off shrinks the staged set and grand total', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));
    expect(c.shrinkTotal.count, 2);

    // The orphans stage owns /orphan.raf — toggle it off via its Switch.
    final orphanSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('2. Orphans'),
        matching: find.byType(Row),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(orphanSwitch.first);
    await tester.tap(orphanSwitch.first);
    await tester.pump();

    expect(c.shrinkTotal.count, 1);
    expect(c.shrinkStaged.map((e) => e.path), ['/library/dup.jpg']);
  });

  testWidgets('deselecting a file in the summary drops it from the trash set', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));
    expect(c.shrinkSelectedCount, 2);

    // Each staged file has a checkbox; untick the first.
    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(c.shrinkSelectedCount, 1);
    expect(find.text('Move 1 file(s) to Trash'), findsOneWidget);
  });

  testWidgets('the silly-word confirm gates the trash call', (tester) async {
    final fake = FakeEngineRunner(
      events: const [
        DoneEvent({'trashed': 2}),
      ],
    );
    final c = AppController(runner: fake)..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c, random: _FixedRandom(0)));

    await tester.ensureVisible(find.text('Move 2 file(s) to Trash'));
    await tester.tap(find.text('Move 2 file(s) to Trash'));
    await tester.pumpAndSettle();

    // The dialog is open; the Trash button is disabled until the word matches.
    final trashBtn = find.widgetWithText(FilledButton, 'Move to Trash');
    expect(trashBtn, findsOneWidget);
    expect(tester.widget<FilledButton>(trashBtn).onPressed, isNull);
    expect(fake.calls, isNot(contains('trashPaths')));

    // Type the (deterministic) silly word — _FixedRandom(0) picks index 0.
    await tester.enterText(find.byType(TextField), sillyWords[0]);
    await tester.pump();
    expect(tester.widget<FilledButton>(trashBtn).onPressed, isNotNull);

    await tester.tap(trashBtn);
    await tester.pumpAndSettle();
    expect(fake.calls, contains('trashPaths'));
    expect(fake.lastTrashedPaths, ['/library/dup.jpg', '/library/orphan.raf']);
  });

  testWidgets('cancelling the confirm dialog trashes nothing', (tester) async {
    final fake = FakeEngineRunner();
    final c = AppController(runner: fake)..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c, random: _FixedRandom(0)));

    await tester.ensureVisible(find.text('Move 2 file(s) to Trash'));
    await tester.tap(find.text('Move 2 file(s) to Trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(fake.calls, isNot(contains('trashPaths')));
  });

  testWidgets('a running trash shows live progress', (tester) async {
    final fake = FakeEngineRunner(keepOpen: true);
    final c = AppController(runner: fake)..debugSeedShrink(_twoStaged);
    unawaited(c.runTrashShrink());
    await tester.pumpWidget(_host(c));
    await tester.pump();
    expect(find.byType(RunProgress), findsOneWidget);
    fake.release();
  });

  testWidgets('the done view summarises the run and returns to the library', (
    tester,
  ) async {
    final fake = FakeEngineRunner(
      events: const [
        DoneEvent({'trashed': 3}),
      ],
    );
    final c = AppController(runner: fake)..debugSeedShrink(_twoStaged);
    await c.runTrashShrink();
    await tester.pumpWidget(_host(c));

    expect(find.byType(ResultSummaryTable), findsOneWidget);
    await tester.ensureVisible(find.text('Done — back to library'));
    await tester.tap(find.text('Done — back to library'));
    await tester.pump();
    expect(c.screen, AppScreen.workspace);
  });

  testWidgets('the duplicates stage shows the hashing bar while busy', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink)
      ..debugSetShrinkBusy(total: 4, done: 1);
    await tester.pumpWidget(_host(c));
    // Both hashing stages (duplicates + low quality) show the bar while busy.
    expect(find.textContaining('Hashing 1 / 4'), findsNWidgets(2));
  });

  testWidgets('the low-quality slider and pair toggle drive the controller', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    await tester.pumpWidget(_host(c));

    // Drag the quality slider toward higher threshold.
    await tester.ensureVisible(find.byType(Slider));
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump();
    expect(c.shrinkQualityThreshold, greaterThan(0.35));

    // Flip the pair drop side via the segmented button.
    await tester.ensureVisible(find.text('Keep the RAW'));
    await tester.tap(find.text('Keep the RAW'));
    await tester.pump();
    expect(c.shrinkPairDrop, PairDropSide.dropPhoto);

    // Toggle the orphan-image checkbox on.
    await tester.ensureVisible(find.text('Orphan images (no matching RAW)'));
    await tester.tap(find.text('Orphan images (no matching RAW)'));
    await tester.pump();
    expect(c.shrinkOrphanImages, isTrue);
  });

  testWidgets('the "Run this stage" buttons drive each stage runner', (
    tester,
  ) async {
    final fake = FakeEngineRunner()..duplicateGroups = const [];
    final c = AppController(runner: fake)
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    await tester.pumpWidget(_host(c));

    // There is one "Run this stage" button per stage; tapping the orphans one
    // (a pure, synchronous stage) drives runShrinkOrphans.
    final runButtons = find.text('Run this stage');
    expect(runButtons, findsNWidgets(ShrinkStage.values.length));
    await tester.ensureVisible(runButtons.at(1));
    await tester.tap(runButtons.at(1));
    await tester.pump();
    expect(c.shrinkOutcome(ShrinkStage.orphans), isNotNull);

    // The redundant-pairs stage (also pure & synchronous).
    await tester.ensureVisible(runButtons.at(2));
    await tester.tap(runButtons.at(2));
    await tester.pump();
    expect(c.shrinkOutcome(ShrinkStage.pairs), isNotNull);

    // The low-quality stage hashes via the engine.
    await tester.ensureVisible(runButtons.at(3));
    await tester.tap(runButtons.at(3));
    await tester.pump();
    expect(fake.calls, contains('hashFiles'));

    // The duplicates stage runner kicks off hashing via the engine.
    await tester.ensureVisible(runButtons.first);
    await tester.tap(runButtons.first);
    await tester.pump();
    expect(fake.calls, contains('findDuplicates'));
  });

  testWidgets('an error message renders the banner above the wizard', (
    tester,
  ) async {
    final c = AppController(runner: ThrowingEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    await c.runShrinkDuplicates();
    await tester.pumpWidget(_host(c));
    expect(find.byType(ErrorBanner), findsOneWidget);
  });

  test('shrinkReasonLabel resolves a reason to its English label', () {
    expect(shrinkReasonLabel(ShrinkReason.duplicate, enTr), 'duplicate');
    expect(shrinkReasonLabel(ShrinkReason.lowQuality, enTr), 'low quality');
  });
}
