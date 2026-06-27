import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/actions/duplicates_action.dart';
import 'package:stunda/src/actions/prune_action.dart';
import 'package:stunda/src/actions/shrink_action.dart';
import 'package:stunda/src/actions/shrink_low_quality_review.dart';
import 'package:stunda/src/actions/shrink_pairs_review.dart';
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

HashedFile _hf(String path, {int size = 1000, double quality = 0.9}) =>
    HashedFile(
      path: path,
      hash: 0,
      width: 10,
      height: 10,
      fileSize: size,
      basename: path,
      isRaw: false,
      quality: ImageQuality(
        sharpness: quality,
        contrast: quality,
        colorfulness: quality,
        composite: quality,
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
  testWidgets('the hub lists a card for every stage with an include toggle', (
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
    expect(find.byType(Switch), findsNWidgets(ShrinkStage.values.length));
    expect(
      find.text('Open & review'),
      findsNWidgets(ShrinkStage.values.length),
    );
    expect(
      find.text('Not reviewed yet — open to choose files.'),
      findsNWidgets(ShrinkStage.values.length),
    );
    expect(
      find.text('Nothing on the shrink list yet. Open a stage above to begin.'),
      findsOneWidget,
    );
  });

  testWidgets('a skipped stage shows Skipped instead of the open button', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink)
      ..setShrinkStageIncluded(ShrinkStage.lowQuality, false);
    await tester.pumpWidget(_host(c));
    expect(find.text('Skipped'), findsOneWidget);
    expect(find.text('Open & review'), findsNWidgets(3));
  });

  testWidgets(
    'opening the duplicates stage routes to the real Duplicates page',
    (tester) async {
      final c =
          AppController(runner: FakeEngineRunner()..duplicateGroups = const [])
            ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
            ..openAction(LibraryAction.shrink);
      await tester.pumpWidget(_host(c));

      await tester.ensureVisible(find.text('Open & review').first);
      await tester.tap(find.text('Open & review').first);
      await tester.pump();

      expect(c.shrinkActiveStage, ShrinkStage.duplicates);
      expect(find.byType(DuplicatesAction), findsOneWidget);
      expect(find.text('Back to shrink wizard'), findsOneWidget);
    },
  );

  testWidgets(
    'the duplicates page in shrink mode adds the selection and returns',
    (tester) async {
      final fake = FakeEngineRunner()
        ..duplicateGroups = [
          DuplicateGroup(
            best: _hf('/library/a.jpg', size: 3000, quality: 1),
            duplicates: [_hf('/library/b.jpg', size: 1500, quality: 1)],
          ),
        ];
      final c = AppController(runner: fake)
        ..debugSetScan(
          fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']),
        )
        ..openAction(LibraryAction.shrink);
      c.openShrinkStage(ShrinkStage.duplicates);
      await c.runFindDuplicates();
      await tester.pumpWidget(_host(c));

      // The terminal button reads "Add N to shrink list", not the trash label.
      expect(find.text('Add 1 to shrink list'), findsOneWidget);
      expect(find.byType(ShrinkAddButton), findsOneWidget);
      await tester.ensureVisible(find.byType(ShrinkAddButton));
      await tester.tap(find.text('Add 1 to shrink list'));
      await tester.pump();

      // Returned to the hub; the running total reflects the addition.
      expect(c.shrinkActiveStage, isNull);
      expect(find.text('1. Duplicates'), findsOneWidget);
      expect(
        find.textContaining('Added 1 file(s) · 1 KB to free'),
        findsOneWidget,
      );
      expect(find.text('Staged: 1 file(s) · 1 KB to be freed'), findsOneWidget);
    },
  );

  testWidgets('opening the orphans stage routes to the real Prune page', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/only.raf']))
      ..openAction(LibraryAction.shrink);
    await tester.pumpWidget(_host(c));

    await tester.ensureVisible(find.text('Open & review').at(1));
    await tester.tap(find.text('Open & review').at(1));
    await tester.pump();

    expect(c.shrinkActiveStage, ShrinkStage.orphans);
    expect(find.byType(PruneAction), findsOneWidget);
    expect(find.byType(ShrinkAddButton), findsOneWidget);
  });

  testWidgets('the pairs review picks a side and adds the selection', (
    tester,
  ) async {
    // Non-existent paths: classifyPairing works on the strings, the size read
    // returns 0, and Image.file on a missing file shows the placeholder
    // immediately (a real garbage file would decode async and never settle).
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const pairRaw = '/library/pair.raf';
    const pairJpg = '/library/pair.jpg';
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const [pairRaw, pairJpg]))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.pairs);
    // Drop the photo side so the listed candidate is the .jpg.
    c.setShrinkPairDrop(PairDropSide.dropPhoto);
    await tester.pumpWidget(_host(c));

    expect(find.byType(ShrinkPairsReview), findsOneWidget);
    expect(find.text('1 of 1 selected'), findsOneWidget);
    expect(find.text('Keep the RAW'), findsOneWidget);
    expect(c.shrinkPairCandidates.map((f) => f.path), [pairJpg]);

    // The segmented button flips the drop side back to the RAW. A single pump
    // (not pumpAndSettle) drives the onSelectionChanged callback without running
    // the selection animation to a frame that overflows the test viewport.
    await tester.tap(find.text('Keep the photo'), warnIfMissed: false);
    await tester.pump();
    expect(c.shrinkPairDrop, PairDropSide.dropRaw);
    c.setShrinkPairDrop(PairDropSide.dropPhoto);
    await tester.pump();

    // The select-all checkbox is the first Checkbox; the row checkbox follows.
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.first); // deselect all
    await tester.pump();
    expect(c.shrinkPairSelectedCount, 0);
    await tester.tap(boxes.last); // re-select the single row
    await tester.pump();
    expect(c.isShrinkPairSelected(pairJpg), isTrue);

    await tester.tap(find.text('Add 1 to shrink list'));
    await tester.pump();
    expect(c.shrinkActiveStage, isNull);
    expect(c.shrinkStaged.map((e) => e.path), [pairJpg]);
  });

  testWidgets('the pairs review shows an empty state with no pairs', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/solo.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.pairs);
    await tester.pumpWidget(_host(c));
    expect(find.text('No RAW + photo pairs found.'), findsOneWidget);
    // The add button is disabled with nothing to add.
    final btn = tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(ShrinkAddButton),
        matching: find.byType(FilledButton),
      ),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('the low-quality review finds, lists, and adds candidates', (
    tester,
  ) async {
    final fake = FakeEngineRunner()
      ..hashedFiles = [_hf('/library/blur.jpg', size: 2222, quality: 0.1)];
    final c = AppController(runner: fake)
      ..debugSetScan(fakeScan(photos: const ['/library/blur.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.lowQuality);
    await tester.pumpWidget(_host(c));

    expect(find.byType(ShrinkLowQualityReview), findsOneWidget);
    await tester.ensureVisible(find.text('Find low-quality photos'));
    await tester.tap(find.text('Find low-quality photos'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('below'), findsWidgets);
    // Exercise the select-all and per-row checkboxes.
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.first); // deselect all
    await tester.pump();
    expect(c.shrinkLowQSelectedCount, 0);
    await tester.tap(boxes.last); // re-select the single row
    await tester.pump();
    expect(c.isShrinkLowQSelected('/library/blur.jpg'), isTrue);

    await tester.ensureVisible(find.text('Add 1 to shrink list'));
    await tester.tap(find.text('Add 1 to shrink list'));
    await tester.pump();
    expect(c.shrinkStaged.map((e) => e.path), ['/library/blur.jpg']);
  });

  testWidgets('the low-quality review shows an empty state above threshold', (
    tester,
  ) async {
    final fake = FakeEngineRunner()
      ..hashedFiles = [_hf('/library/sharp.jpg', size: 1, quality: 0.9)];
    final c = AppController(runner: fake)
      ..debugSetScan(fakeScan(photos: const ['/library/sharp.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.lowQuality);
    await c.runShrinkLowQualityHash();
    await tester.pumpWidget(_host(c));
    expect(find.text('No photos scored below the threshold.'), findsOneWidget);
  });

  testWidgets('the low-quality review shows the hashing bar while busy', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink)
      ..openShrinkStage(ShrinkStage.lowQuality)
      ..debugSetShrinkBusy(total: 4, done: 1);
    await tester.pumpWidget(_host(c));
    expect(find.textContaining('Hashing 1 / 4'), findsOneWidget);
  });

  testWidgets('Back to shrink wizard returns to the hub without adding', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/solo.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.pairs);
    await tester.pumpWidget(_host(c));
    await tester.ensureVisible(find.text('Back to shrink wizard'));
    await tester.tap(find.text('Back to shrink wizard'));
    await tester.pump();
    expect(c.shrinkActiveStage, isNull);
    expect(find.text('1. Duplicates'), findsOneWidget);
  });

  testWidgets('a reviewed stage shows Review again on the hub', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));
    expect(find.text('Review again'), findsNWidgets(2));
    expect(
      find.textContaining('Added 1 file(s) · 2.0 MB to free'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Added 1 file(s) · 1.0 MB to free'),
      findsOneWidget,
    );
    expect(find.text('Staged: 2 file(s) · 3.0 MB to be freed'), findsOneWidget);
  });

  testWidgets('the final summary lists every staged file with reason + GPS', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));
    expect(find.text('duplicate'), findsWidgets);
    expect(find.text('orphan RAW'), findsWidgets);
    expect(find.text('GPS'), findsWidgets);
    expect(find.text('No GPS'), findsWidgets);
  });

  testWidgets('toggling a stage off shrinks the staged set and total', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSeedShrink(_twoStaged);
    await tester.pumpWidget(_host(c));
    expect(c.shrinkTotal.count, 2);

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

    final trashBtn = find.widgetWithText(FilledButton, 'Move to Trash');
    expect(trashBtn, findsOneWidget);
    expect(tester.widget<FilledButton>(trashBtn).onPressed, isNull);
    expect(fake.calls, isNot(contains('trashPaths')));

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

  testWidgets('an error message renders the banner above the wizard hub', (
    tester,
  ) async {
    final c = AppController(runner: ThrowingEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']))
      ..openAction(LibraryAction.shrink);
    c.openShrinkStage(ShrinkStage.lowQuality);
    await c.runShrinkLowQualityHash();
    c.returnToShrinkWizard();
    await tester.pumpWidget(_host(c));
    expect(find.byType(ErrorBanner), findsOneWidget);
  });

  test('shrinkReasonLabel resolves a reason to its English label', () {
    expect(shrinkReasonLabel(ShrinkReason.duplicate, enTr), 'duplicate');
    expect(shrinkReasonLabel(ShrinkReason.lowQuality, enTr), 'low quality');
  });
}
