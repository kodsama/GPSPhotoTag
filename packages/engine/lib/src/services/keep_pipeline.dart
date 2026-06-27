import 'duplicate_finder.dart';

/// The configurable "which photo to KEEP" decision for a duplicate group.
///
/// A [KeepPipeline] is an ORDERED list of [KeepRule]s, each with an enabled
/// flag; placement is priority. [chooseKeeper] runs the enabled rules in order
/// and keeps the first one's *clear winner* — a candidate whose score beats the
/// runner-up by more than that rule's threshold. A near-tie falls through to the
/// next rule; if every rule ties, a deterministic final tie-break (larger file,
/// then path) decides. Everything here is pure so the cascade is unit-testable.

/// A single keep-decision criterion.
enum KeepRule {
  /// Prefer the higher-resolution (more pixels) candidate.
  resolution,

  /// Prefer the higher composite-quality (sharpness/contrast/colour) candidate.
  quality,

  /// Prefer the candidate with more / better-framed people. NOT YET IMPLEMENTED
  /// — reserved so the pipeline order can already include it later. A future
  /// pass will score it; for now [chooseKeeper] treats it as a no-op (every
  /// candidate ties, so it always falls through).
  people,
}

/// Resolution is a "clear winner" only when the top candidate has at least this
/// fraction more pixels than the runner-up (≈15% more area). Tunable.
const double kResolutionClearWinnerRatio = 1.15;

/// Quality is a "clear winner" only when the top composite quality beats the
/// runner-up by at least this absolute margin (composite is 0..1). Tunable.
const double kQualityClearWinnerMargin = 0.08;

/// One rule in a [KeepPipeline]: the [rule] and whether it is [enabled].
class KeepStep {
  /// Creates a pipeline step.
  const KeepStep(this.rule, {this.enabled = true});

  /// The decision criterion.
  final KeepRule rule;

  /// Whether this step participates in the cascade.
  final bool enabled;

  /// This step with [enabled] set to [value].
  KeepStep withEnabled(bool value) => KeepStep(rule, enabled: value);

  /// JSON view (`{"rule": "...", "enabled": true}`).
  Map<String, Object> toJson() => {'rule': rule.name, 'enabled': enabled};

  /// Parses a step from [json], or null when the rule name is unknown.
  static KeepStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['rule'];
    if (name is! String) return null;
    final rule = KeepRule.values.where((r) => r.name == name).firstOrNull;
    if (rule == null) return null;
    return KeepStep(rule, enabled: json['enabled'] == true);
  }
}

/// An ordered list of [KeepStep]s. Placement = priority.
class KeepPipeline {
  /// Creates a pipeline from [steps] (order = priority).
  const KeepPipeline(this.steps);

  /// The standard default: resolution first, then quality, both enabled.
  static const standard = KeepPipeline([
    KeepStep(KeepRule.resolution),
    KeepStep(KeepRule.quality),
  ]);

  /// The ordered steps.
  final List<KeepStep> steps;

  /// JSON view (a list of step maps), suitable for persistence.
  List<Object> toJson() => [for (final s in steps) s.toJson()];

  /// Rebuilds a pipeline from [json] produced by [toJson]. Unknown/duplicate
  /// rules are dropped; any rule missing from [json] is appended (disabled) in
  /// its canonical order, so the pipeline always covers every [KeepRule] exactly
  /// once even as new rules are added across versions. A null/garbage input
  /// yields [standard].
  static KeepPipeline fromJson(Object? json) {
    if (json is! List) return standard;
    final seen = <KeepRule>{};
    final steps = <KeepStep>[];
    for (final item in json) {
      final step = KeepStep.fromJson(item);
      if (step == null || !seen.add(step.rule)) continue;
      steps.add(step);
    }
    if (steps.isEmpty) return standard;
    // Append any rule the saved order didn't mention, disabled, so toggles for
    // newly-introduced rules can still appear in the UI.
    for (final rule in KeepRule.values) {
      if (seen.add(rule)) steps.add(KeepStep(rule, enabled: false));
    }
    return KeepPipeline(steps);
  }
}

/// Chooses which of [candidates] to KEEP using [pipeline].
///
/// Runs the enabled steps in order. Each rule scores every candidate; if the
/// top score beats the runner-up by more than the rule's threshold (a "clear
/// winner") that candidate is kept and the cascade STOPS. Otherwise (a near-tie
/// the rule can't decide) it falls through to the next enabled rule. If no rule
/// produces a clear winner, the deterministic final tie-break wins: larger
/// [HashedFile.fileSize], then the lexicographically smallest path.
///
/// [candidates] must be non-empty.
HashedFile chooseKeeper(List<HashedFile> candidates, KeepPipeline pipeline) {
  if (candidates.isEmpty) {
    throw ArgumentError('chooseKeeper needs at least one candidate');
  }
  if (candidates.length == 1) return candidates.first;

  for (final step in pipeline.steps) {
    if (!step.enabled) continue;
    final winner = _clearWinner(candidates, step.rule);
    if (winner != null) return winner;
  }
  return _finalTieBreak(candidates);
}

/// The clear winner of [candidates] under [rule], or null when the top two are
/// within the rule's threshold (a near-tie) — or the rule has no scoring yet.
HashedFile? _clearWinner(List<HashedFile> candidates, KeepRule rule) {
  switch (rule) {
    case KeepRule.resolution:
      return _ratioWinner(
        candidates,
        (c) => c.resolution.toDouble(),
        kResolutionClearWinnerRatio,
      );
    case KeepRule.quality:
      return _marginWinner(
        candidates,
        (c) => c.quality.composite,
        kQualityClearWinnerMargin,
      );
    case KeepRule.people:
      // Not implemented yet: no scores, so every candidate ties → fall through.
      return null;
  }
}

/// The candidate with the top [score] when it is at least [ratio]× the
/// runner-up's score; null when within that ratio (a near-tie) or all-zero.
HashedFile? _ratioWinner(
  List<HashedFile> candidates,
  double Function(HashedFile) score,
  double ratio,
) {
  final (top, topScore, runnerUp) = _topTwo(candidates, score);
  if (topScore <= 0) return null;
  if (topScore >= runnerUp * ratio) return top;
  return null;
}

/// The candidate with the top [score] when it beats the runner-up by at least
/// [margin]; null when within that margin (a near-tie).
HashedFile? _marginWinner(
  List<HashedFile> candidates,
  double Function(HashedFile) score,
  double margin,
) {
  final (top, topScore, runnerUp) = _topTwo(candidates, score);
  if (topScore - runnerUp >= margin) return top;
  return null;
}

/// The top-scoring candidate, its score, and the second-best score. Ties on the
/// score are broken by [_finalTieBreak] so "top" is deterministic.
(HashedFile, double, double) _topTwo(
  List<HashedFile> candidates,
  double Function(HashedFile) score,
) {
  var top = candidates.first;
  var topScore = score(top);
  var runnerUp = double.negativeInfinity;
  for (final c in candidates.skip(1)) {
    final s = score(c);
    if (s > topScore || (s == topScore && _prefer(c, top))) {
      runnerUp = topScore;
      top = c;
      topScore = s;
    } else if (s > runnerUp) {
      runnerUp = s;
    }
  }
  if (runnerUp == double.negativeInfinity) runnerUp = topScore;
  return (top, topScore, runnerUp);
}

/// The deterministic last-resort keeper: largest file size, then smallest path.
HashedFile _finalTieBreak(List<HashedFile> candidates) {
  var best = candidates.first;
  for (final c in candidates.skip(1)) {
    if (_prefer(c, best)) best = c;
  }
  return best;
}

/// Whether [a] beats [b] in the final tie-break (larger file, then path).
bool _prefer(HashedFile a, HashedFile b) {
  if (a.fileSize != b.fileSize) return a.fileSize > b.fileSize;
  return a.path.compareTo(b.path) < 0;
}
