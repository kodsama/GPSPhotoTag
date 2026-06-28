import 'dart:math';

import 'package:stunda_engine/stunda_engine.dart';

import 'library_action.dart' show Translator;

/// Pure helpers behind the Find-Duplicates review: the looseness-percent ↔
/// min-similarity mapping, expanding a group into reviewable pairs, the swap
/// that flips which side is kept, collecting the selected removal set, and the
/// silly-word confirm gate. Kept Flutter-free so they are unit-testable.

/// The number of slider divisions: 0..100 in steps of 10 (11 stops). The slider
/// value IS the looseness percent (0 = Exact, 100 = Loose).
const int similaritySteps = 10;

/// The minimum percent the slider can take (Exact).
const int similarityMinPercent = 0;

/// The maximum percent the slider can take (Loose).
const int similarityMaxPercent = 100;

/// The min-similarity cutoff at the Exact (0%) end: only ~identical images group.
const double _exactSimilarity = 0.98;

/// The min-similarity cutoff at the Loose (100%) end. Deliberately kept high
/// enough (~0.55) that the loosest setting still groups genuinely-similar photos
/// rather than unrelated ones — the whole point of the new metric's full-range,
/// trustworthy distance.
const double _looseSimilarity = 0.55;

/// Maps a looseness [percent] (0 = Exact, 100 = Loose) to the min-similarity
/// cutoff (0..1) [groupDuplicates] uses.
///
/// Linearly interpolates across the trustworthy band [_looseSimilarity] (loose)
/// .. [_exactSimilarity] (exact): 0% → 0.98 (only near-identical group), 100% →
/// 0.55 (still genuinely-similar, never random). DECREASING in the percent (a
/// looser setting accepts a lower similarity). Out-of-range inputs are clamped.
double similarityToThreshold(int percent) {
  final p = percent.clamp(similarityMinPercent, similarityMaxPercent) / 100;
  return _exactSimilarity - p * (_exactSimilarity - _looseSimilarity);
}

/// Snaps an arbitrary [value] to the nearest valid slider stop: a multiple of 10
/// clamped to 0..100. Used to migrate/clamp a persisted value and to snap the
/// slider's continuous drag. Pure.
int snapSimilarityPercent(int value) {
  final clamped = value.clamp(similarityMinPercent, similarityMaxPercent);
  return ((clamped / 10).round()) * 10;
}

/// Normalises a looseness [percent] (0..100) to a 0..1 "scene variance" the
/// example-pair painter uses to perturb its right tile.
///
/// 0 at Exact, 1 at Loose, strictly increasing in between (simply `percent/100`).
/// Out-of-range inputs are clamped. Pure so the painter stays deterministic and
/// the mapping is unit-testable.
double sceneVariance(int percent) =>
    percent.clamp(similarityMinPercent, similarityMaxPercent) / 100;

/// The localization KEY for a short, human descriptor of what the current
/// looseness [percent] catches, shown as the example-pair caption.
///
/// Buckets the percent into five bands: Exact (0) → identical copies; low (≤20) →
/// light re-encodes; mid (≤50) → small edits; high (≤80) → the same scene shot
/// differently; and the loosest band → only loosely-similar scenes ("kind of the
/// same"). Out-of-range inputs are clamped. Pure so the bucket boundaries are
/// testable; the widget layer resolves the key through `context.tr`.
String similarityExampleKey(int percent) {
  final value = percent.clamp(similarityMinPercent, similarityMaxPercent);
  if (value == 0) return 'sim_identical';
  if (value <= 20) return 'sim_resaved';
  if (value <= 50) return 'sim_minor';
  if (value <= 80) return 'sim_same_scene';
  return 'sim_loose';
}

/// Pure helpers behind the Shrink "Low quality" stage: the quality-threshold ↔
/// example-degradation mapping, the threshold → caption-bucket key, and the
/// always-visible picked-threshold label. Kept Flutter-free so the mappings are
/// unit-testable away from any widget. Quality here is the engine's composite
/// score — a blend of sharpness, contrast, and colourfulness (see
/// `ImageQuality`) — and the stage flags photos scoring below the threshold.

/// Maps a 0..1 quality [threshold] to a 0..1 "degradation amount" the example
/// painter applies to its FLAGGED tile (0 = crisp/vivid, 1 = very blurry/flat).
///
/// DECREASING: a stricter (higher) threshold flags even mild cases, so the
/// illustrative flagged sample should look LESS degraded (`1 - threshold`); a
/// lenient (low) threshold only catches clearly-bad photos, so the sample looks
/// strongly degraded. Out-of-range inputs are clamped. Pure so the painter
/// stays deterministic and the mapping is unit-testable.
double qualityDegradation(double threshold) => (1 - threshold).clamp(0.0, 1.0);

/// The localization KEY for a short descriptor of what the current quality
/// [threshold] flags, shown as the example caption.
///
/// Buckets the 0..1 threshold into three bands: lenient (≤0.25) → only clearly
/// blurry/flat photos; mid (≤0.55) → also so-so shots; strict (>0.55) → even
/// slightly soft or flat photos. Out-of-range inputs are clamped. Pure so the
/// boundaries are testable; the widget resolves the key through `context.tr`.
String qualityExampleKey(double threshold) {
  final value = threshold.clamp(0.0, 1.0);
  if (value <= 0.25) return 'lowq_only_blurry';
  if (value <= 0.55) return 'lowq_soso';
  return 'lowq_strict';
}

/// The always-visible picked-threshold label, e.g. "Lenient ↔ Strict · 35%".
///
/// Mirrors the similarity slider's picked-setting label: it resolves the
/// `lowq_threshold_value` string through [tr] with the threshold as a clamped
/// whole percent. Pure (Flutter-free) so the formatting is unit-testable.
String qualityPickedLabel(double threshold, Translator tr) => tr(
  'lowq_threshold_value',
  {'percent': (threshold.clamp(0.0, 1.0) * 100).round()},
);

/// The localization key for a metric's short display name (the segment label).
String similarityMetricLabelKey(SimilarityMetric metric) => switch (metric) {
  SimilarityMetric.fast => 'dup_metric_fast',
  SimilarityMetric.smart => 'dup_metric_smart',
};

/// The localization key for a metric's one-line explanation.
String similarityMetricDescKey(SimilarityMetric metric) => switch (metric) {
  SimilarityMetric.fast => 'dup_metric_fast_desc',
  SimilarityMetric.smart => 'dup_metric_smart_desc',
};

/// The localization key for a metric's "pro" (what it is good at).
String similarityMetricProKey(SimilarityMetric metric) => switch (metric) {
  SimilarityMetric.fast => 'dup_metric_fast_pro',
  SimilarityMetric.smart => 'dup_metric_smart_pro',
};

/// The localization key for a metric's "con" (its trade-off).
String similarityMetricConKey(SimilarityMetric metric) => switch (metric) {
  SimilarityMetric.fast => 'dup_metric_fast_con',
  SimilarityMetric.smart => 'dup_metric_smart_con',
};

/// One reviewable duplicate pair: the [kept] file and the [other] candidate.
///
/// A group of N members renders N−1 pairs (the best vs each other member). The
/// [other] side is selected for removal by default.
class DuplicatePair {
  /// Creates a pair keeping [kept] over [other].
  const DuplicatePair({
    required this.kept,
    required this.other,
    this.removeSelected = true,
  });

  /// The file kept (shown on the LEFT).
  final HashedFile kept;

  /// The candidate to remove (shown on the RIGHT).
  final HashedFile other;

  /// Whether [other] is currently selected for removal.
  final bool removeSelected;

  /// This pair with [removeSelected] set to [selected].
  DuplicatePair withSelected(bool selected) =>
      DuplicatePair(kept: kept, other: other, removeSelected: selected);

  /// This pair with [kept] and [other] swapped (selection preserved).
  DuplicatePair swap() =>
      DuplicatePair(kept: other, other: kept, removeSelected: removeSelected);
}

/// Expands [groups] into the flat list of reviewable [DuplicatePair]s.
///
/// Each group yields one pair per other member: the keeper as the kept (left)
/// side and every remaining member as the other (right) side, all initially
/// selected for removal.
///
/// The keeper defaults to [DuplicateGroup.best] (the engine's choice). Passing a
/// [pipeline] re-decides the keeper per group with [chooseKeeper] over all the
/// group's members, so the kept side reflects the user's keep-priority pipeline
/// even though the engine grouped with its standard one. The per-pair Swap still
/// lets the user override the choice afterwards.
List<DuplicatePair> pairsFromGroups(
  List<DuplicateGroup> groups, {
  KeepPipeline? pipeline,
}) {
  final pairs = <DuplicatePair>[];
  for (final group in groups) {
    final members = [group.best, ...group.duplicates];
    final keeper = pipeline == null
        ? group.best
        : chooseKeeper(members, pipeline);
    for (final member in members) {
      if (identical(member, keeper)) continue;
      pairs.add(DuplicatePair(kept: keeper, other: member));
    }
  }
  return pairs;
}

/// The set of right-side files still selected for removal across [pairs].
///
/// A file appears once even if several pairs target it; order follows [pairs].
List<String> selectedRemovalPaths(List<DuplicatePair> pairs) {
  final seen = <String>{};
  final out = <String>[];
  for (final pair in pairs) {
    if (!pair.removeSelected) continue;
    if (seen.add(pair.other.path)) out.add(pair.other.path);
  }
  return out;
}

/// The live progress of a duplicate-hashing run: how many files have been
/// hashed ([done]) out of the [total] to hash. Pure and immutable so the
/// done/total → fraction + label mapping is unit-testable away from isolates.
class HashProgress {
  /// Creates a progress snapshot. [done] is clamped to `0..total` so a stray
  /// extra tick can never push the bar past full.
  HashProgress({int done = 0, this.total = 0})
    : assert(total >= 0, 'total must be non-negative'),
      done = done < 0 ? 0 : (done > total ? total : done);

  /// Files hashed so far.
  final int done;

  /// Total files to hash (0 before the run's size is known).
  final int total;

  /// Folds a worker tick of [hashed] freshly-hashed files into a new snapshot.
  HashProgress tick(int hashed) =>
      HashProgress(done: done + hashed, total: total);

  /// Completion fraction in 0..1, or null when [total] is 0 (size unknown →
  /// the bar should render indeterminate).
  double? get fraction => total == 0 ? null : done / total;

  /// [done] formatted with grouped thousands (e.g. 1234 → "1,234").
  String get groupedDone => _grouped(done);

  /// [total] formatted with grouped thousands (e.g. 5000 → "5,000").
  String get groupedTotal => _grouped(total);

  /// Formats [n] with comma thousands separators (e.g. 1234 → "1,234").
  static String _grouped(int n) {
    final digits = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}

/// A small built-in list of fun confirmation words for the trash gate.
const List<String> sillyWords = [
  'bananaphone',
  'wobblegong',
  'snorkledoodle',
  'flibbertigibbet',
  'kerfuffle',
  'gobbledygook',
  'wibblewobble',
  'snickerdoodle',
];

/// Picks a silly confirmation word from [sillyWords] using [random] (injected so
/// tests are deterministic).
String pickSillyWord(Random random) =>
    sillyWords[random.nextInt(sillyWords.length)];

/// Whether [typed] matches the [expected] silly word (case-insensitive, trimmed)
/// — the gate that enables the Trash button in the confirm dialog.
bool sillyWordMatches(String typed, String expected) =>
    typed.trim().toLowerCase() == expected.trim().toLowerCase();
