import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stunda/src/state/action_run_state.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/action_card.dart';

Widget _wrap(ActionCard card) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 260, height: 200, child: card)),
);

void main() {
  group('ActionCard run state', () {
    testWidgets('shows no progress ring when idle', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.tag,
            readiness: const ActionReadiness.ready('Ready — 1 source'),
            onOpen: () {},
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Ready — 1 source'), findsOneWidget);
    });

    testWidgets('overlays a determinate ring while running', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.tag,
            readiness: const ActionReadiness.ready('Ready'),
            runState: ActionRunState.active(progress: 0.4),
            onOpen: () {},
          ),
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, 0.4); // determinate
    });

    testWidgets('an indeterminate ring has a null value', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.duplicates,
            readiness: const ActionReadiness.ready('Ready'),
            runState: ActionRunState.active(),
            onOpen: () {},
          ),
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, isNull);
    });

    testWidgets('a running card stays tappable even when readiness blocks it', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.tag,
            readiness: const ActionReadiness.blocked('No GPS sources found'),
            runState: ActionRunState.active(progress: 0.2),
            onOpen: () => opened++,
          ),
        ),
      );
      await tester.tap(find.byType(ActionCard));
      expect(opened, 1);
    });

    testWidgets('pulses an attention badge when a run needs review', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.duplicates,
            readiness: const ActionReadiness.ready('Ready'),
            runState: ActionRunState.review(summary: '2 pairs'),
            onOpen: () {},
          ),
        ),
      );
      // The badge is a tooltipped dot; it must be present (and the looping
      // animation means we never pumpAndSettle here).
      expect(find.byTooltip('Needs your review'), findsOneWidget);
      // No ring when only reviewing (not running).
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byTooltip('Needs your review'), findsOneWidget);
    });

    testWidgets('no badge for a plain idle card', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.tag,
            readiness: const ActionReadiness.ready('Ready'),
            onOpen: () {},
          ),
        ),
      );
      expect(find.byTooltip('Needs your review'), findsNothing);
    });

    testWidgets('running shows a progress strip with percent, not the chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.duplicates,
            readiness: const ActionReadiness.ready('Ready — 5 photos'),
            runState: ActionRunState.active(progress: 0.4),
            onOpen: () {},
          ),
        ),
      );
      // The bottom progress bar (distinct from the icon ring) + a percent label.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      // The idle readiness chip is replaced while running.
      expect(find.text('Ready — 5 photos'), findsNothing);
    });

    testWidgets('a finished run shows a tappable results-ready chip', (
      tester,
    ) async {
      var opened = false;
      await tester.pumpWidget(
        _wrap(
          ActionCard(
            action: LibraryAction.duplicates,
            readiness: const ActionReadiness.ready('Ready'),
            runState: ActionRunState.review(summary: '3 duplicate pair(s)'),
            onOpen: () => opened = true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1200)); // settle the flash
      // The summary surfaces on the card with a "go review" chevron.
      expect(find.text('3 duplicate pair(s)'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // The card is tappable to return to the results.
      await tester.tap(find.byType(ActionCard));
      expect(opened, isTrue);
    });
  });
}
