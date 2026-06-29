import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/state/action_run_state.dart';

void main() {
  group('ActionRunState', () {
    test('idle is not running, not reviewing, no attention', () {
      const s = ActionRunState.idle;
      expect(s.running, isFalse);
      expect(s.needsReview, isFalse);
      expect(s.attention, isFalse);
      expect(s.progress, isNull);
      expect(s.summary, isNull);
    });

    test('active carries a clamped progress fraction', () {
      expect(ActionRunState.active(progress: 0.5).progress, 0.5);
      expect(ActionRunState.active(progress: -1).progress, 0.0);
      expect(ActionRunState.active(progress: 2).progress, 1.0);
      expect(ActionRunState.active().progress, isNull); // indeterminate
      expect(ActionRunState.active(progress: 0.3).running, isTrue);
    });

    test('review needs review and pulses attention only when not running', () {
      final s = ActionRunState.review(summary: '2 pairs');
      expect(s.needsReview, isTrue);
      expect(s.running, isFalse);
      expect(s.summary, '2 pairs');
      expect(s.attention, isTrue);
    });

    test('a running state never pulses attention', () {
      const s = ActionRunState(running: true, needsReview: true);
      expect(s.attention, isFalse);
    });

    test('value equality and hashCode over all fields', () {
      expect(
        ActionRunState.active(progress: 0.5),
        ActionRunState.active(progress: 0.5),
      );
      expect(
        ActionRunState.active(progress: 0.5).hashCode,
        ActionRunState.active(progress: 0.5).hashCode,
      );
      expect(
        ActionRunState.active(progress: 0.5),
        isNot(ActionRunState.active(progress: 0.6)),
      );
      expect(
        ActionRunState.review(summary: 'a'),
        isNot(ActionRunState.review(summary: 'b')),
      );
      expect(ActionRunState.idle, isNot(ActionRunState.active()));
      expect(ActionRunState.idle, isNot('not a state'));
    });

    test('toString names every field', () {
      expect(
        ActionRunState.active(progress: 0.5).toString(),
        contains('running: true'),
      );
      expect(
        ActionRunState.review(summary: 'x').toString(),
        contains('needsReview: true'),
      );
    });

    test('asserts progress stays within 0..1', () {
      expect(
        () => ActionRunState(progress: 1.5),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
