import 'package:stunda_engine/stunda_engine.dart';

/// The seam between [AppController] and the engine.
///
/// Production uses [IsolateRunner], which runs each operation on a worker
/// isolate; tests inject a fake that returns canned [EngineEvent] streams
/// without spawning isolates. Method signatures mirror the engine's services.
abstract interface class EngineRunner {
  /// Recursively scans [roots], streaming [ScanProgressEvent]s then a final
  /// [ScanDoneEvent] carrying the [FolderScanResult].
  Stream<ScanEvent> scan(List<String> roots);

  /// Tags [photos] using GPS read from [gpxFiles], [kmlFiles] and
  /// [googleFiles] (all pooled inside the worker, off the UI isolate).
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> kmlFiles,
    required List<String> googleFiles,
    required TagOptions options,
  });

  /// Prunes orphan RAW files under [roots].
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  });

  /// Moves exactly the given [paths] (plus any `.xmp` sidecars) to the Trash,
  /// or deletes them when [delete] is true. Backs the preview→confirm flow,
  /// where the user has already selected which files to remove.
  Stream<EngineEvent> trashPaths(List<String> paths, {bool delete = false});

  /// Fixes capture/file dates for [files] in the given [mode].
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  });

  /// Batch-reads image metadata for [paths] (off the UI isolate), streaming one
  /// [FileMeta] per path as exiftool yields each chunk. Backs the drill-down
  /// dialog's progressive per-row metadata.
  Stream<FileMeta> readImageMeta(List<String> paths);

  /// Batch-reads the curated camera/exposure EXIF set for [paths] (off the UI
  /// isolate), streaming one [CuratedExif] per path as exiftool yields each
  /// chunk. Backs the big-preview viewer's EXIF info line.
  Stream<CuratedExif> readCuratedExif(List<String> paths);

  /// Extracts an embedded JPEG preview of [path] (a RAW/HEIC file) on a worker
  /// isolate via the bundled exiftool, returning the cached JPEG path — or null
  /// when the file carries no usable embedded image. [full] picks the largest
  /// preview (fullscreen) vs the small thumbnail (list miniature).
  Future<String?> extractPreview(String path, {bool full = false});

  /// Perceptually hashes [paths] across worker isolates and groups files whose
  /// hashes are within [threshold] Hamming distance, returning the duplicate
  /// groups (undecodable files and RAW companions are excluded). RAW/HEIC are
  /// hashed via their embedded preview using the bundled exiftool.
  ///
  /// [onProgress] (when given) is called as files finish hashing with the
  /// running `done` count against the fixed `total` (= `paths.length`), so the
  /// UI can show determinate progress instead of an indeterminate spinner.
  Future<List<DuplicateGroup>> findDuplicates(
    List<String> paths, {
    required int threshold,
    void Function(int done, int total)? onProgress,
  });

  /// Perceptually hashes [paths] across worker isolates, returning every
  /// [HashedFile] (each carrying its on-disk size, dimensions, and an
  /// [ImageQuality] composite score). Backs both the duplicate grouping and the
  /// shrink wizard's low-quality stage, so neither has to re-decode the library.
  ///
  /// [onProgress] (when given) reports the running `done` count against the
  /// fixed `total` (= `paths.length`) as files finish hashing.
  Future<List<HashedFile>> hashFiles(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  });
}
