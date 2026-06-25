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

  /// Renders a heatmap PNG from the GPS already embedded in [photos].
  Stream<EngineEvent> map({
    required List<String> photos,
    required MapOptions options,
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
}
