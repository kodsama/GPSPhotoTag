import 'package:meta/meta.dart';

import '../services/duplicate_finder.dart';
import '../services/keep_pipeline.dart';
import '../services/raw_pairing.dart';

/// How GPS is written into RAW files.
enum RawMode {
  /// Embed via exiftool when available, else fall back to an XMP sidecar.
  auto,

  /// Always write an XMP sidecar; never touch the RAW bytes.
  sidecar,

  /// Force embedding via exiftool (fails if exiftool is missing).
  embed,
}

/// Direction of the optional date-fix pass.
enum FixDatesMode {
  /// Do not touch dates.
  none,

  /// Set the file's created/modified date from EXIF `DateTimeOriginal`.
  exif,

  /// Write EXIF `DateTimeOriginal` from the file's created date.
  file,
}

/// Options for the `tag` operation. Defaults mirror the original CLI.
@immutable
class TagOptions {
  /// Creates tag options with sensible defaults.
  const TagOptions({
    this.outDir,
    this.overwrite = false,
    this.replace = false,
    this.rawMode = RawMode.auto,
    this.maxTimeDiff = const Duration(seconds: 300),
    this.timezone,
    this.fixDates = FixDatesMode.none,
    this.dryRun = false,
  });

  /// Write tagged copies here; when null, [overwrite] must be true.
  final String? outDir;

  /// Modify originals in place (required when [outDir] is null).
  final bool overwrite;

  /// Overwrite GPS bytes already present in a photo.
  final bool replace;

  /// RAW write strategy.
  final RawMode rawMode;

  /// Largest gap allowed between a photo time and a source point.
  final Duration maxTimeDiff;

  /// IANA timezone name used when EXIF lacks an offset (e.g. `Europe/Paris`).
  final String? timezone;

  /// Optional date-fix pass to run alongside (or instead of) tagging.
  final FixDatesMode fixDates;

  /// Locate and report only; write nothing.
  final bool dryRun;
}

/// Options for the read-only `map` (heatmap) operation.
@immutable
class MapOptions {
  /// Creates map options.
  const MapOptions({
    required this.outputPng,
    this.dpi = 200,
    this.clusters,
    this.labelNames = false,
  });

  /// Destination PNG path (zoom variants derive sibling names).
  final String outputPng;

  /// Output resolution, clamped to 30..1200 by the renderer.
  final int dpi;

  /// Cluster selection: null = all; otherwise the 1-based cluster numbers.
  final Set<int>? clusters;

  /// Label each area with its collapsed filename range.
  final bool labelNames;
}

/// Options for the standalone `prune-raw` operation.
@immutable
class PruneOptions {
  /// Creates prune options.
  const PruneOptions({
    this.delete = false,
    this.dryRun = false,
    this.direction = PruneDirection.removeOrphanRaws,
  });

  /// Permanently delete orphans instead of moving them to Trash.
  final bool delete;

  /// Report only; remove nothing.
  final bool dryRun;

  /// Which side of the RAW/photo pairing to trash.
  final PruneDirection direction;
}

/// Options for the `duplicates` operation.
///
/// The default is review-first: [dryRun] reports the groups it found and
/// removes nothing, so a caller has to opt in to deletion explicitly.
@immutable
class DuplicatesOptions {
  /// Creates duplicate-finding options.
  const DuplicatesOptions({
    this.minSimilarity = 0.92,
    this.metric = SimilarityMetric.fast,
    this.pipeline = KeepPipeline.standard,
    this.delete = false,
    this.dryRun = true,
  });

  /// Similarity cutoff in 0..1; 1.0 groups only near-identical images.
  final double minSimilarity;

  /// Which per-pair similarity to use.
  final SimilarityMetric metric;

  /// The keep-rule cascade choosing which member of a group survives.
  final KeepPipeline pipeline;

  /// Permanently delete the non-kept members instead of trashing them.
  final bool delete;

  /// Report the groups only; remove nothing.
  final bool dryRun;
}

/// One opt-in stage of the `shrink` operation.
enum ShrinkStage {
  /// Non-kept members of a visually-similar group.
  duplicates('duplicates'),

  /// A RAW with no photo companion, or a photo with no RAW.
  orphans('orphans'),

  /// Both halves of a RAW+photo pair exist; drop one side.
  pairs('pairs'),

  /// Composite quality below [ShrinkOptions.qualityThreshold].
  lowQuality('low-quality');

  const ShrinkStage(this.wire);

  /// Stable name used by the CLI `--stage` flag and the MCP `stages` argument.
  final String wire;

  /// The stage whose [wire] is [name], or null when unrecognised.
  static ShrinkStage? byWire(String name) {
    for (final s in ShrinkStage.values) {
      if (s.wire == name) return s;
    }
    return null;
  }
}

/// Which half of a RAW+photo pair the [ShrinkStage.pairs] stage drops.
enum PairDropSide {
  /// Drop the RAW, keep the photo.
  dropRaw('raw'),

  /// Drop the photo, keep the RAW.
  dropPhoto('photo');

  const PairDropSide(this.wire);

  /// Stable name used by the CLI and MCP arguments.
  final String wire;

  /// The side whose [wire] is [name], or null when unrecognised.
  static PairDropSide? byWire(String name) {
    for (final s in PairDropSide.values) {
      if (s.wire == name) return s;
    }
    return null;
  }
}

/// Options for the staged `shrink` operation.
///
/// Every stage is opt-in and the default is review-first ([dryRun]), mirroring
/// the GUI wizard: nothing is removed until the caller both selects stages and
/// turns the dry run off.
@immutable
class ShrinkOptions {
  /// Creates shrink options.
  const ShrinkOptions({
    this.stages = const {},
    this.minSimilarity = 0.92,
    this.metric = SimilarityMetric.fast,
    this.pipeline = KeepPipeline.standard,
    this.qualityThreshold = 0.35,
    this.pairDropSide = PairDropSide.dropRaw,
    this.delete = false,
    this.dryRun = true,
  });

  /// The stages to run, in [ShrinkStage] order. Empty means nothing to do.
  final Set<ShrinkStage> stages;

  /// Similarity cutoff for the [ShrinkStage.duplicates] stage.
  final double minSimilarity;

  /// Which per-pair similarity the duplicates stage uses.
  final SimilarityMetric metric;

  /// The keep-rule cascade for the duplicates stage.
  final KeepPipeline pipeline;

  /// Composite-quality cutoff for [ShrinkStage.lowQuality]; below is staged.
  final double qualityThreshold;

  /// Which half [ShrinkStage.pairs] drops.
  final PairDropSide pairDropSide;

  /// Permanently delete instead of trashing.
  final bool delete;

  /// Report the candidates only; remove nothing.
  final bool dryRun;
}
