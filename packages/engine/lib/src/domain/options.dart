import 'package:meta/meta.dart';

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
  const PruneOptions({this.delete = false, this.dryRun = false});

  /// Permanently delete orphans instead of moving them to Trash.
  final bool delete;

  /// Report only; remove nothing.
  final bool dryRun;
}
