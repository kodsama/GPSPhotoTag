import 'package:gpsphototag_engine/gpsphototag_engine.dart';

/// The seam between [AppController] and the engine.
///
/// Production uses [IsolateRunner], which runs each operation on a worker
/// isolate; tests inject a fake that returns canned [EngineEvent] streams
/// without spawning isolates. Method signatures mirror the engine's services.
abstract interface class EngineRunner {
  /// Tags [photos] using GPS read from [gpxFiles] and [googleFiles].
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
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

  /// Fixes capture/file dates for [files] in the given [mode].
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  });
}
