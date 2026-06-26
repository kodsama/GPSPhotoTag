import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/actions/duplicates_action.dart';
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

      await tester.tap(find.text('Remove 1 duplicate(s) on the right'));
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

  testWidgets('disables the slider and shows a spinner while hashing', (
    tester,
  ) async {
    final fake = FakeEngineRunner()..duplicatesGate = Completer<void>();
    final c = AppController(runner: fake)
      ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates)
      ..debugSetScan(fakeScan(photos: const ['/a.jpg', '/b.jpg']));
    // Kick off hashing but hold it open via the gate so findingDuplicates stays
    // true while we assert on the mid-flight UI.
    final run = c.runFindDuplicates();
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(c.findingDuplicates, isTrue);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    fake.duplicatesGate!.complete();
    await run;
  });

  testWidgets('cancelling the confirm dialog trashes nothing', (tester) async {
    final fake = FakeEngineRunner();
    final c = AppController(runner: fake)
      ..debugSetDuplicatePairs([
        DuplicatePair(kept: _hf('/best.jpg'), other: _hf('/dup.jpg')),
      ]);
    await tester.pumpWidget(_host(c, random: _FixedRandom(0)));

    await tester.tap(find.text('Remove 1 duplicate(s) on the right'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(fake.calls, isNot(contains('trashPaths')));
  });
}
