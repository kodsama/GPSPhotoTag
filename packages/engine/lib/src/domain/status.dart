/// The outcome of processing a single photo (or RAW file).
///
/// Mirrors the status vocabulary of the original tool so summaries are familiar.
enum PhotoStatus {
  /// New GPS written from an exact source match.
  tagged('tagged'),

  /// New GPS written from an interpolated coordinate.
  interpolated('interpolated'),

  /// Photo already carried GPS and was skipped (no `--replace`).
  alreadyTagged('already_tagged'),

  /// No source coordinate within the time threshold; left untouched.
  noGps('no_gps'),

  /// No usable capture timestamp could be read; cannot match.
  noTimestamp('no_timestamp'),

  /// File/EXIF dates were adjusted by the date-fix operation.
  datesFixed('dates_fixed'),

  /// Reported only; nothing was written (dry run).
  dryRun('dry_run'),

  /// An orphan RAW was moved to the OS Trash.
  prunedTrashed('pruned_trashed'),

  /// An orphan RAW was permanently deleted.
  prunedDeleted('pruned_deleted'),

  /// Processing failed for this item; see the row note.
  error('error');

  const PhotoStatus(this.wire);

  /// Stable snake_case identifier used in `--json` output and summaries.
  final String wire;
}
