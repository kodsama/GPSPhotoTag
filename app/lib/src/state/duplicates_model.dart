import 'dart:math';

import 'package:stunda_engine/stunda_engine.dart';

/// Pure helpers behind the Find-Duplicates review: the similarity-slider ↔
/// Hamming-threshold mapping, expanding a group into reviewable pairs, the swap
/// that flips which side is kept, collecting the selected removal set, and the
/// silly-word confirm gate. Kept Flutter-free so they are unit-testable.

/// The number of discrete similarity steps the slider offers (0..[similaritySteps]).
const int similaritySteps = 10;

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

/// A short, human descriptor of what the current similarity [slider] level
/// catches, shown as the example-pair caption.
///
/// Buckets the slider into four bands: Exact (0) → identical copies; low → light
/// re-encodes; mid → small edits; high/Loose → the same scene shot differently.
/// Out-of-range inputs are clamped. Pure so the bucket boundaries are testable.
String similarityExampleLabel(int slider) {
  final value = slider.clamp(0, similaritySteps);
  if (value == 0) return 'Identical copies';
  if (value <= 3) return 'Re-saved or resized';
  if (value <= 7) return 'Minor edits (crop, exposure)';
  return 'Same scene, a different shot';
}

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
/// Each group yields one pair per duplicate: its [DuplicateGroup.best] as the
/// kept (left) side and each [DuplicateGroup.duplicates] member as the other
/// (right) side, all initially selected for removal.
List<DuplicatePair> pairsFromGroups(List<DuplicateGroup> groups) {
  final pairs = <DuplicatePair>[];
  for (final group in groups) {
    for (final dup in group.duplicates) {
      pairs.add(DuplicatePair(kept: group.best, other: dup));
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

  /// A human label like "Hashing 1,234 / 5,000" with grouped thousands.
  String get label => 'Hashing ${_grouped(done)} / ${_grouped(total)}';

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
