import 'package:stunda_engine/stunda_engine.dart';

import 'duplicates_model.dart' show DuplicatePair;
import 'library_action.dart' show Translator;

/// Pure orchestration behind the "Shrink picture library" wizard.
///
/// The wizard walks OPT-IN stages, each contributing trash candidates, into ONE
/// cumulative set. A file flagged by an earlier stage is never counted again by
/// a later one (first reason wins). Everything here is Flutter-free and side
/// effect-free so the stage candidate computation, the cross-stage dedup, the
/// per-stage and running count/bytes tallies, the reason mapping, and the
/// low-quality threshold filter are all unit-testable away from isolates and the
/// filesystem.

/// The opt-in stages of the shrink wizard, in order.
enum ShrinkStage {
  /// Visually-similar photos (perceptual hashing); non-kept members.
  duplicates,

  /// RAW with no JPG/HEIC companion, or image with no RAW.
  orphans,

  /// Both a RAW and a non-RAW exist; drop one side.
  pairs,

  /// Quality score below a user-chosen threshold.
  lowQuality,
}

/// Why a file was staged for deletion. Maps to a localization key for display.
enum ShrinkReason {
  /// Non-kept member of a duplicate group.
  duplicate('shrink_reason_duplicate'),

  /// A RAW file with no JPG/HEIC companion.
  orphanRaw('shrink_reason_orphan_raw'),

  /// A non-RAW image with no RAW companion.
  orphanImage('shrink_reason_orphan_image'),

  /// The RAW half of a RAW+photo pair (the photo is kept).
  redundantRaw('shrink_reason_redundant_raw'),

  /// The photo half of a RAW+photo pair (the RAW is kept).
  redundantJpg('shrink_reason_redundant_jpg'),

  /// Quality score below the chosen threshold.
  lowQuality('shrink_reason_low_quality');

  const ShrinkReason(this.labelKey);

  /// The localization key for this reason's label.
  final String labelKey;

  /// The localized label via [tr].
  String label(Translator tr) => tr(labelKey);
}

/// One file staged for deletion: where it is, why, how big, and whether it
/// carries GPS coordinates (shown as an indicator in the final review).
class ShrinkCandidate {
  /// Creates a candidate for [path] flagged with [reason].
  const ShrinkCandidate({
    required this.path,
    required this.reason,
    required this.sizeBytes,
    required this.hasGps,
  });

  /// The file path.
  final String path;

  /// Why the file was staged.
  final ShrinkReason reason;

  /// On-disk size in bytes (0 when unknown).
  final int sizeBytes;

  /// Whether the file carries GPS coordinates.
  final bool hasGps;
}

/// A tally of staged files: how many, and their combined size in bytes.
class ShrinkTally {
  /// Creates a tally of [count] files totalling [bytes].
  const ShrinkTally({this.count = 0, this.bytes = 0});

  /// An empty tally.
  static const ShrinkTally zero = ShrinkTally();

  /// Number of files.
  final int count;

  /// Combined size in bytes.
  final int bytes;

  /// This tally with [candidates] folded in.
  ShrinkTally plusAll(Iterable<ShrinkCandidate> candidates) {
    var c = count;
    var b = bytes;
    for (final cand in candidates) {
      c++;
      b += cand.sizeBytes;
    }
    return ShrinkTally(count: c, bytes: b);
  }
}

/// The result of folding one stage into the cumulative set: the freshly-added
/// candidates (after cross-stage dedup), that stage's own tally, and the running
/// total across every stage so far.
class ShrinkStageOutcome {
  /// Creates a stage outcome.
  const ShrinkStageOutcome({
    required this.stage,
    required this.added,
    required this.stageTally,
    required this.runningTotal,
  });

  /// The stage this outcome is for.
  final ShrinkStage stage;

  /// Candidates this stage newly contributed (already deduped against earlier
  /// stages).
  final List<ShrinkCandidate> added;

  /// The tally of just this stage's [added] candidates.
  final ShrinkTally stageTally;

  /// The running total across every staged file so far.
  final ShrinkTally runningTotal;
}

/// The mutable accumulator that builds ONE cumulative trash set across stages.
///
/// First reason wins: a path already staged by an earlier stage is skipped (not
/// re-flagged) when a later stage proposes it again, so it is never
/// double-counted. The accumulator also tracks per-path deselection so the user
/// can review and drop files within a stage and on the final summary.
class StagedSet {
  StagedSet();

  /// path → candidate, in insertion order (first reason wins).
  final Map<String, ShrinkCandidate> _byPath = {};

  /// Paths the user has explicitly deselected (kept despite being staged).
  final Set<String> _deselected = {};

  /// Every staged path's candidate, in insertion order.
  List<ShrinkCandidate> get all => _byPath.values.toList(growable: false);

  /// The currently-selected candidates (staged and not deselected).
  List<ShrinkCandidate> get selected => [
    for (final c in _byPath.values)
      if (!_deselected.contains(c.path)) c,
  ];

  /// The selected paths (those that will actually be trashed).
  List<String> get selectedPaths => [
    for (final c in _byPath.values)
      if (!_deselected.contains(c.path)) c.path,
  ];

  /// Whether [path] is staged at all.
  bool contains(String path) => _byPath.containsKey(path);

  /// Whether [path] is staged AND still selected for deletion.
  bool isSelected(String path) =>
      _byPath.containsKey(path) && !_deselected.contains(path);

  /// Selects or deselects an already-staged [path]. A no-op for unstaged paths.
  void setSelected(String path, bool selected) {
    if (!_byPath.containsKey(path)) return;
    if (selected) {
      _deselected.remove(path);
    } else {
      _deselected.add(path);
    }
  }

  /// The grand total over the currently-selected candidates.
  ShrinkTally get selectedTally => ShrinkTally.zero.plusAll(selected);

  /// Folds [candidates] in as stage [stage]: any path already staged by an
  /// earlier stage is skipped (first reason wins). Returns the outcome with the
  /// freshly-added candidates, this stage's tally, and the running total.
  ShrinkStageOutcome addStage(
    ShrinkStage stage,
    List<ShrinkCandidate> candidates,
  ) {
    final added = <ShrinkCandidate>[];
    for (final cand in candidates) {
      if (_byPath.containsKey(cand.path)) continue;
      _byPath[cand.path] = cand;
      added.add(cand);
    }
    return ShrinkStageOutcome(
      stage: stage,
      added: added,
      stageTally: ShrinkTally.zero.plusAll(added),
      runningTotal: ShrinkTally.zero.plusAll(_byPath.values),
    );
  }

  /// Removes every candidate a stage contributed (used when the user toggles a
  /// stage off). Only paths whose reason came from [stage] are dropped; paths an
  /// earlier stage already owned are untouched.
  void removeStage(ShrinkStage stage) {
    final reasons = reasonsForStage(stage);
    final drop = [
      for (final c in _byPath.values)
        if (reasons.contains(c.reason)) c.path,
    ];
    for (final path in drop) {
      _byPath.remove(path);
      _deselected.remove(path);
    }
  }
}

/// The reasons a given [stage] can produce (used to roll a stage back out of the
/// cumulative set).
Set<ShrinkReason> reasonsForStage(ShrinkStage stage) => switch (stage) {
  ShrinkStage.duplicates => {ShrinkReason.duplicate},
  ShrinkStage.orphans => {ShrinkReason.orphanRaw, ShrinkReason.orphanImage},
  ShrinkStage.pairs => {ShrinkReason.redundantRaw, ShrinkReason.redundantJpg},
  ShrinkStage.lowQuality => {ShrinkReason.lowQuality},
};

// --- Per-stage candidate computation (pure) --------------------------------

/// The duplicate-stage candidates: every selected right-side ([DuplicatePair.other])
/// file becomes a candidate with the [ShrinkReason.duplicate] reason.
///
/// Sizes come straight off the [HashedFile.fileSize] the finder already
/// measured; [hasGps] is unknown at hash time so it is looked up via [gpsOf]
/// (defaults to false). A file targeted by several pairs is emitted once.
List<ShrinkCandidate> duplicateCandidates(
  List<DuplicatePair> pairs, {
  bool Function(String path)? gpsOf,
}) {
  final seen = <String>{};
  final out = <ShrinkCandidate>[];
  for (final pair in pairs) {
    if (!pair.removeSelected) continue;
    final path = pair.other.path;
    if (!seen.add(path)) continue;
    out.add(
      ShrinkCandidate(
        path: path,
        reason: ShrinkReason.duplicate,
        sizeBytes: pair.other.fileSize,
        hasGps: gpsOf?.call(path) ?? false,
      ),
    );
  }
  return out;
}

/// The orphan-stage candidates from a [RawPairing].
///
/// [includeOrphanRaws] flags RAWs with no JPG/HEIC companion; [includeOrphanImages]
/// flags non-RAW images with no RAW. [sizeOf]/[gpsOf] resolve each file's size
/// and GPS flag (both default to 0 / false).
List<ShrinkCandidate> orphanCandidates(
  RawPairing pairing, {
  required bool includeOrphanRaws,
  required bool includeOrphanImages,
  int Function(String path)? sizeOf,
  bool Function(String path)? gpsOf,
}) {
  final out = <ShrinkCandidate>[];
  for (final file in pairing.files) {
    final ShrinkReason reason;
    if (file.kind == PairKind.orphanRaw && includeOrphanRaws) {
      reason = ShrinkReason.orphanRaw;
    } else if (file.kind == PairKind.photoWithoutRaw && includeOrphanImages) {
      reason = ShrinkReason.orphanImage;
    } else {
      continue;
    }
    out.add(
      ShrinkCandidate(
        path: file.path,
        reason: reason,
        sizeBytes: sizeOf?.call(file.path) ?? 0,
        hasGps: gpsOf?.call(file.path) ?? false,
      ),
    );
  }
  return out;
}

/// Which side of a RAW+photo pair to drop in the redundant-pairs stage.
enum PairDropSide {
  /// Keep the photo; drop the RAW.
  dropRaw,

  /// Keep the RAW; drop the photo.
  dropPhoto,
}

/// The redundant-pairs candidates: where BOTH a RAW and its non-RAW partner
/// exist ([PairKind.pairedRaw] / [PairKind.photoWithRaw]), drop the [side] the
/// user chose. Dropping the RAW flags [PairKind.pairedRaw] rows
/// ([ShrinkReason.redundantRaw]); dropping the photo flags [PairKind.photoWithRaw]
/// rows ([ShrinkReason.redundantJpg]).
List<ShrinkCandidate> redundantPairCandidates(
  RawPairing pairing, {
  required PairDropSide side,
  int Function(String path)? sizeOf,
  bool Function(String path)? gpsOf,
}) {
  final wantKind = side == PairDropSide.dropRaw
      ? PairKind.pairedRaw
      : PairKind.photoWithRaw;
  final reason = side == PairDropSide.dropRaw
      ? ShrinkReason.redundantRaw
      : ShrinkReason.redundantJpg;
  final out = <ShrinkCandidate>[];
  for (final file in pairing.files) {
    if (file.kind != wantKind) continue;
    out.add(
      ShrinkCandidate(
        path: file.path,
        reason: reason,
        sizeBytes: sizeOf?.call(file.path) ?? 0,
        hasGps: gpsOf?.call(file.path) ?? false,
      ),
    );
  }
  return out;
}

/// The low-quality candidates: every entry in [scores] whose composite quality
/// is strictly below [threshold] (0..1). [sizeOf]/[gpsOf] resolve size and GPS.
List<ShrinkCandidate> lowQualityCandidates(
  Map<String, double> scores, {
  required double threshold,
  int Function(String path)? sizeOf,
  bool Function(String path)? gpsOf,
}) {
  final out = <ShrinkCandidate>[];
  scores.forEach((path, score) {
    if (score >= threshold) return;
    out.add(
      ShrinkCandidate(
        path: path,
        reason: ShrinkReason.lowQuality,
        sizeBytes: sizeOf?.call(path) ?? 0,
        hasGps: gpsOf?.call(path) ?? false,
      ),
    );
  });
  return out;
}
