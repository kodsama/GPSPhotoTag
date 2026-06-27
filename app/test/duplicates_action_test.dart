import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/actions/duplicates_action.dart';
import 'package:stunda/src/actions/example_scene.dart';
import 'package:stunda/src/explore/photo_detail_panel.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/duplicates_model.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/run_view.dart';

import 'support/fakes.dart';

HashedFile _hf(
  String path, {
  int width = 100,
  int height = 100,
  int size = 2048,
}) => HashedFile(
  path: path,
  hash: 0,
  width: width,
  height: height,
  fileSize: size,
  basename: path,
  isRaw: false,
);

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
      body: SingleChildScrollView(child: DuplicatesAction(random: random)),
    ),
  ),
);

void main() {
  testWidgets('shows the similarity slider and run button before a run', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates);
    await tester.pumpWidget(_host(c));

    expect(find.text('Find duplicates'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Exact'), findsOneWidget);
    expect(find.text('Loose'), findsOneWidget);

    // Dragging the slider toward Loose raises the similarity (exercises the
    // onChanged seam → setSimilarity).
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump();
    expect(c.similarity, greaterThan(0));
  });

  testWidgets(
    'shows the example pair and updates its caption with similarity',
    (tester) async {
      final c = AppController(runner: FakeEngineRunner())
        ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates);
      await tester.pumpWidget(_host(c));

      // The example pair renders under the slider at the Exact default.
      expect(find.byType(ExampleScenePair), findsOneWidget);
      expect(find.text('Identical copies'), findsOneWidget);
      expect(find.text('≈'), findsOneWidget);

      // Driving the controller to Loose updates the caption live.
      c.setSimilarity(similaritySteps);
      await tester.pump();
      expect(find.text('Loosely similar scenes'), findsOneWidget);
      expect(find.text('Identical copies'), findsNothing);
    },
  );

  testWidgets('renders best on the left and the duplicate on the right', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(
          kept: _hf('/best.jpg', width: 400, height: 300),
          other: _hf('/dup.jpg', width: 100, height: 100),
        ),
      ]);
    await tester.pumpWidget(_host(c));

    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('best.jpg'), findsOneWidget);
    expect(find.text('dup.jpg'), findsOneWidget);
    expect(find.byType(PhotoThumbnail), findsNWidgets(2));
    // The remove button counts the one selected right-side file.
    expect(find.text('Remove 1 duplicate(s) on the right'), findsOneWidget);
  });

  testWidgets('swap flips the kept side', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await tester.pumpWidget(_host(c));

    await tester.ensureVisible(find.byIcon(Icons.swap_horiz));
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pump();

    // After swap the right side (removal candidate) is the former best.
    expect(c.duplicateRemovalPaths, ['/best.jpg']);
  });

  testWidgets('deselect drops the pair from the removal set', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await tester.pumpWidget(_host(c));

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(c.duplicateRemovalCount, 0);
    // The remove button is now disabled (nothing selected).
    final button = find.widgetWithText(
      FilledButton,
      'Remove 0 duplicate(s) on the right',
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets(
    'confirm dialog blocks until the exact silly word is typed, then trashes',
    (tester) async {
      final fake = FakeEngineRunner();
      final c = AppController(runner: fake)
        ..debugSetDuplicatePairs([
          DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
        ]);
      // Seed the word pick to the first silly word.
      await tester.pumpWidget(_host(c, random: _FixedRandom(0)));

      final remove = find.text('Remove 1 duplicate(s) on the right');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();

      // The Trash button is disabled until the word matches.
      final trashButton = find.widgetWithText(FilledButton, 'Move to Trash');
      expect(tester.widget<FilledButton>(trashButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField), sillyWords.first);
      await tester.pump();
      expect(tester.widget<FilledButton>(trashButton).onPressed, isNotNull);

      await tester.tap(trashButton);
      await tester.pumpAndSettle();

      expect(fake.lastTrashedPaths, ['/dup.jpg']);
    },
  );

  testWidgets('shows the keep-priority pipeline with both rules', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates);
    await tester.pumpWidget(_host(c));

    expect(find.text('Keep priority'), findsOneWidget);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('Quality'), findsOneWidget);
    // The reserved People rule is hidden from the control.
    expect(find.text('People'), findsNothing);
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('toggling a rule switch updates the controller pipeline', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates);
    await tester.pumpWidget(_host(c));

    // The first switch is Resolution (top of the default order).
    final resolutionSwitch = find.byType(Switch).first;
    await tester.ensureVisible(resolutionSwitch);
    await tester.tap(resolutionSwitch);
    await tester.pump();

    final resolution = c.keepPipeline.steps.firstWhere(
      (s) => s.rule == KeepRule.resolution,
    );
    expect(resolution.enabled, isFalse);
  });

  testWidgets('the kept side reflects a controller pipeline change', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(
          kept: HashedFile(
            path: '/big.jpg',
            hash: 0,
            width: 300,
            height: 300,
            fileSize: 10,
            basename: 'big',
            isRaw: false,
            quality: const ImageQuality(
              sharpness: 0.1,
              contrast: 0.1,
              colorfulness: 0.1,
              composite: 0.1,
            ),
          ),
          other: HashedFile(
            path: '/crisp.jpg',
            hash: 0,
            width: 100,
            height: 100,
            fileSize: 10,
            basename: 'crisp',
            isRaw: false,
            quality: const ImageQuality(
              sharpness: 0.9,
              contrast: 0.9,
              colorfulness: 0.9,
              composite: 0.9,
            ),
          ),
        ),
      ]);
    await tester.pumpWidget(_host(c));
    // Initially resolution keeps the big file.
    expect(find.text('big.jpg'), findsOneWidget);

    // Disable resolution via the controller → quality keeps the crisp file, and
    // the review's kept side updates.
    c.setKeepRuleEnabled(KeepRule.resolution, false);
    await tester.pump();
    expect(c.duplicatePairs!.single.kept.path, '/crisp.jpg');
  });

  testWidgets('an empty result shows the no-duplicates note', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs(const []);
    await tester.pumpWidget(_host(c));
    expect(find.text('No duplicates found.'), findsOneWidget);
  });

  testWidgets('formatBytes renders B / KB / MB', (tester) async {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });

  testWidgets('keepRuleLabel names every keep rule', (tester) async {
    expect(keepRuleLabel(KeepRule.resolution), 'Resolution');
    expect(keepRuleLabel(KeepRule.quality), 'Quality');
    expect(keepRuleLabel(KeepRule.people), 'People');
  });

  testWidgets('shows live progress while a trash run is in flight', (
    tester,
  ) async {
    final fake = FakeEngineRunner(keepOpen: true);
    final c = AppController(runner: fake)
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    // Start a trash run that stays open → controller.running is true.
    unawaited(c.runTrashDuplicates());
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(c.running, isTrue);
    expect(find.byType(RunProgress), findsOneWidget);
    fake.release();
    await tester.pumpAndSettle();
  });

  testWidgets('shows the summary and back button after a run', (tester) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await c.runTrashDuplicates(); // completes → lastSummary set, not running
    await tester.pumpWidget(_host(c));

    expect(find.text('Done — back to library'), findsOneWidget);
  });

  testWidgets('surfaces an error banner when a run errors', (tester) async {
    final c = AppController(runner: ThrowingEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await c.runTrashDuplicates(); // stream error → errorMessage set
    await tester.pumpWidget(_host(c));

    expect(find.byType(ErrorBanner), findsOneWidget);
  });

  testWidgets(
    'disables the slider and shows determinate hashing progress while hashing',
    (tester) async {
      final fake = FakeEngineRunner()..duplicatesGate = Completer<void>();
      final c = AppController(runner: fake)
        ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates)
        ..debugSetScan(
          fakeScan(photos: const ['/a.jpg', '/b.jpg', '/c.jpg', '/d.jpg']),
        );
      // Kick off hashing but hold it open via the gate so findingDuplicates
      // stays true while we assert on the mid-flight UI.
      final run = c.runFindDuplicates();
      // Drive a progress tick directly (no real isolate timing): 1 of 4 hashed.
      fake.lastOnProgress!(1, 4);
      await tester.pumpWidget(_host(c));
      await tester.pump();

      expect(c.findingDuplicates, isTrue);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      // A determinate bar (value reflects 1/4), not the old indeterminate one.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.25, 1e-9));
      expect(find.text('Hashing 1 / 4'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      fake.duplicatesGate!.complete();
      await run;
    },
  );

  testWidgets('cancelling the confirm dialog trashes nothing', (tester) async {
    final fake = FakeEngineRunner();
    final c = AppController(runner: fake)
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await tester.pumpWidget(_host(c, random: _FixedRandom(0)));

    final remove = find.text('Remove 1 duplicate(s) on the right');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(fake.calls, isNot(contains('trashPaths')));
  });
}
