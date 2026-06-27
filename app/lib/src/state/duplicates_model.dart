import 'dart:math';

import 'package:stunda_engine/stunda_engine.dart';

import 'library_action.dart' show Translator;

/// Pure helpers behind the Find-Duplicates review: the similarity-slider ↔
/// Hamming-threshold mapping, expanding a group into reviewable pairs, the swap
/// that flips which side is kept, collecting the selected removal set, and the
/// silly-word confirm gate. Kept Flutter-free so they are unit-testable.

/// The number of discrete similarity steps the slider offers (0..[similaritySteps]).
///
/// Raised from 10 to 14 so the loosest settings reach a higher Hamming distance
/// ("Similar scenes"), catching photos that are only *kind of* the same — a
/// looser tier than the old near-duplicate maximum.
const int similaritySteps = 14;

/// Maps a similarity slider value (0 = Exact, [similaritySteps] = Loose) to a
/// Hamming-distance threshold for [groupDuplicates].
///
/// 0 → 0 (only bit-identical previews group); each step up adds one bit of
/// tolerance, so the loosest setting groups previews up to [similaritySteps]
/// bits apart. Out-of-range inputs are clamped.
int similarityToThreshold(int slider) => slider.clamp(0, similaritySteps);

/// Normalises a similarity slider value (0..[similaritySteps]) to a 0..1
/// "scene variance" the example-pair painter uses to perturb its right tile.
///
/// 0 at Exact (pixel-identical preview), 1 at Loose, and strictly increasing in
/// between. Out-of-range inputs are clamped. Pure so the painter stays
/// deterministic and the mapping is unit-testable.
double sceneVariance(int slider) =>
    slider.clamp(0, similaritySteps) / similaritySteps;

/// The localization KEY for a short, human descriptor of what the current
/// similarity [slider] level catches, shown as the example-pair caption.
///
/// Buckets the slider into five bands: Exact (0) → identical copies; low → light
/// re-encodes; mid → small edits; high → the same scene shot differently; and
/// the loosest band → only loosely-similar scenes ("kind of the same"). Out-of-
/// range inputs are clamped. Pure so the bucket boundaries are testable; the
/// widget layer resolves the key through `context.tr`.
String similarityExampleKey(int slider) {
  final value = slider.clamp(0, similaritySteps);
  if (value == 0) return 'sim_identical';
  if (value <= 3) return 'sim_resaved';
  if (value <= 7) return 'sim_minor';
  if (value <= 10) return 'sim_same_scene';
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
