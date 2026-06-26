import 'package:flutter/foundation.dart';

/// The lifecycle of a single background action run, owned by the controller so
/// it survives navigating away from the action's screen.
///
/// An action is in exactly one of three phases:
/// - **idle** — nothing in flight and nothing waiting to be reviewed.
/// - **running** — work is in flight, optionally with a known [progress]
///   fraction (null while the size is unknown → render an indeterminate ring).
/// - **needs review** — the run finished with something for the user to look at
///   (e.g. duplicates were found), surfaced as a pulsing attention badge until
///   the user opens the action.
///
/// Pure and immutable so the running flag, the progress→fraction mapping, and
/// the "needs attention" decision are all unit-testable away from isolates.
@immutable
class ActionRunState {
  /// Creates a run state. Prefer the [idle], [active], and [review] factories.
  const ActionRunState({
    this.running = false,
    this.progress,
    this.needsReview = false,
    this.summary,
  }) : assert(
         progress == null || (progress >= 0 && progress <= 1),
         'progress must be null or within 0..1',
       );

  /// Nothing running, nothing to review.
  static const ActionRunState idle = ActionRunState();

  /// A run in flight. [progress] is the 0..1 fraction when known, else null
  /// (indeterminate). Clamped to 0..1.
  factory ActionRunState.active({double? progress}) =>
      ActionRunState(running: true, progress: progress?.clamp(0.0, 1.0));

  /// A finished run that needs the user's attention, with an optional one-line
  /// [summary] of what it found.
  factory ActionRunState.review({String? summary}) =>
      ActionRunState(needsReview: true, summary: summary);

  /// Whether work is currently in flight.
  final bool running;

  /// Completion fraction in 0..1 while [running], or null for indeterminate.
  final double? progress;

  /// Whether the finished run left something for the user to review.
  final bool needsReview;

  /// A short summary of the run's outcome, or null when there is none.
  final String? summary;

  /// Whether the card should pulse an attention badge (finished, needs review).
  bool get attention => needsReview && !running;

  @override
  bool operator ==(Object other) =>
      other is ActionRunState &&
      other.running == running &&
      other.progress == progress &&
      other.needsReview == needsReview &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(running, progress, needsReview, summary);

  @override
  String toString() =>
      'ActionRunState(running: $running, progress: $progress, '
      'needsReview: $needsReview, summary: $summary)';
}
