import 'dart:async';
import 'dart:isolate';

import 'package:stunda_engine/stunda_engine.dart';

import 'engine_runner.dart';

/// Runs each engine operation on a dedicated worker isolate and surfaces its
/// [EngineEvent]s as a broadcast [Stream] on the main isolate.
///
/// The engine is Flutter-free and its events/options are plain data, so they
/// cross the isolate boundary unchanged. File parsing (GPX/Google) happens
/// inside the worker too, keeping the UI isolate free of all I/O and CPU work.
class IsolateRunner implements EngineRunner {
  /// Creates a runner. [exiftoolAvailable] is detected once on the UI side and
  /// passed in so workers skip a redundant probe; pass null to let each worker
  /// probe for itself. [exiftoolBundleDir] is the on-disk directory of the
  /// app-bundled exiftool (null = use whatever is on `PATH`); each worker builds
  /// its own [ExiftoolRunner] from it since runners aren't isolate-sendable.
  const IsolateRunner({this.exiftoolAvailable, this.exiftoolBundleDir});

  /// Whether exiftool was detected; null means "detect inside the worker".
  final bool? exiftoolAvailable;

  /// On-disk dir of the bundled exiftool, or null to use `PATH`.
  final String? exiftoolBundleDir;

  /// Scans [roots] on a worker isolate, streaming [ScanEvent]s back.
  @override
  Stream<ScanEvent> scan(List<String> roots) => _spawn(
    _scanEntry,
    (port) => _ScanRequest(port: port, roots: roots),
    onSpawnError: ScanLogEvent.new,
  );

  /// Tags [photos] using GPS pooled from [gpxFiles], [kmlFiles] and
  /// [googleFiles]. Pooling (parsing all source files) happens inside the
  /// worker, so the UI isolate stays free.
  @override
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> kmlFiles,
    required List<String> googleFiles,
    required TagOptions options,
  }) => _spawn(
    _tagEntry,
    (port) => _TagRequest(
      port: port,
      photos: photos,
      gpxFiles: gpxFiles,
      kmlFiles: kmlFiles,
      googleFiles: googleFiles,
      options: options,
      exiftoolAvailable: exiftoolAvailable,
      bundleDir: exiftoolBundleDir,
    ),
    onSpawnError: ErrorEvent.new,
  );

  /// Renders a heatmap PNG from the GPS already embedded in [photos].
  @override
  Stream<EngineEvent> map({
    required List<String> photos,
    required MapOptions options,
  }) => _spawn(
    _mapEntry,
    (port) => _MapRequest(
      port: port,
      photos: photos,
      options: options,
      exiftoolAvailable: exiftoolAvailable,
      bundleDir: exiftoolBundleDir,
    ),
    onSpawnError: ErrorEvent.new,
  );

  /// Prunes orphan RAW files under [roots].
  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) => _spawn(
    _pruneEntry,
    (port) => _PruneRequest(port: port, roots: roots, options: options),
    onSpawnError: ErrorEvent.new,
  );

  /// Moves exactly the given [paths] (plus sidecars) to Trash on a worker.
  @override
  Stream<EngineEvent> trashPaths(List<String> paths, {bool delete = false}) =>
      _spawn(
        _trashPathsEntry,
        (port) => _TrashPathsRequest(port: port, paths: paths, delete: delete),
        onSpawnError: ErrorEvent.new,
      );

  /// Fixes capture/file dates for [files] in the given [mode].
  @override
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  }) => _spawn(
    _fixDatesEntry,
    (port) => _FixDatesRequest(
      port: port,
      files: files,
      mode: mode,
      dryRun: dryRun,
      exiftoolAvailable: exiftoolAvailable,
      bundleDir: exiftoolBundleDir,
    ),
    onSpawnError: ErrorEvent.new,
  );

  /// Batch-reads image metadata for [paths] on a worker isolate, streaming one
  /// [FileMeta] per path back to the UI isolate as exiftool yields each chunk.
  @override
  Stream<FileMeta> readImageMeta(List<String> paths) => _spawn(
    _readImageMetaEntry,
    (port) => _ReadImageMetaRequest(
      port: port,
      paths: paths,
      bundleDir: exiftoolBundleDir,
    ),
    onSpawnError: (_) => const FileMeta(path: ''),
  );

  /// Spawns a worker via [entry], wiring its [SendPort] into the request built
  /// by [makeRequest], and re-emits every event of type [E] it sends until the
  /// null sentinel. A spawn failure is surfaced via [onSpawnError].
  Stream<E> _spawn<E, R>(
    void Function(R) entry,
    R Function(SendPort) makeRequest, {
    required E Function(String message) onSpawnError,
  }) {
    final controller = StreamController<E>.broadcast();
    final receive = ReceivePort();
    Isolate? isolate;

    receive.listen((message) {
      if (message == null) {
        controller.close();
        receive.close();
        isolate?.kill(priority: Isolate.immediate);
        return;
      }
      if (message is E) controller.add(message);
    });

    Isolate.spawn(entry, makeRequest(receive.sendPort)).then(
      (spawned) => isolate = spawned,
      onError: (Object e, StackTrace _) {
        controller.add(onSpawnError('failed to start worker: $e'));
        controller.close();
        receive.close();
      },
    );

    return controller.stream;
  }
}

// --- Request payloads (plain data, isolate-sendable) ----------------------

class _ScanRequest {
  const _ScanRequest({required this.port, required this.roots});

  final SendPort port;
  final List<String> roots;
}

class _TagRequest {
  const _TagRequest({
    required this.port,
    required this.photos,
    required this.gpxFiles,
    required this.kmlFiles,
    required this.googleFiles,
    required this.options,
    required this.exiftoolAvailable,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> photos;
  final List<String> gpxFiles;
  final List<String> kmlFiles;
  final List<String> googleFiles;
  final TagOptions options;
  final bool? exiftoolAvailable;
  final String? bundleDir;
}

class _MapRequest {
  const _MapRequest({
    required this.port,
    required this.photos,
    required this.options,
    required this.exiftoolAvailable,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> photos;
  final MapOptions options;
  final bool? exiftoolAvailable;
  final String? bundleDir;
}

class _PruneRequest {
  const _PruneRequest({
    required this.port,
    required this.roots,
    required this.options,
  });

  final SendPort port;
  final List<String> roots;
  final PruneOptions options;
}

class _TrashPathsRequest {
  const _TrashPathsRequest({
    required this.port,
    required this.paths,
    required this.delete,
  });

  final SendPort port;
  final List<String> paths;
  final bool delete;
}

class _FixDatesRequest {
  const _FixDatesRequest({
    required this.port,
    required this.files,
    required this.mode,
    required this.dryRun,
    required this.exiftoolAvailable,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> files;
  final FixDatesMode mode;
  final bool dryRun;
  final bool? exiftoolAvailable;
  final String? bundleDir;
}

class _ReadImageMetaRequest {
  const _ReadImageMetaRequest({
    required this.port,
    required this.paths,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> paths;
  final String? bundleDir;
}

// --- Worker entry points (top-level, run on the spawned isolate) -----------

/// Detects exiftool inside the worker when the caller did not pass a value.
Future<bool> _resolveExiftool(bool? passed) async {
  if (passed != null) return passed;
  final tools = await ToolkitChecker(const SystemProcessRunner()).check();
  return tools.any((t) => t.id == 'exiftool' && t.present);
}

/// Builds the runner for a worker: a plain system runner when no bundle dir is
/// known, otherwise one that routes `exiftool` to the bundled copy.
ProcessRunner _buildRunner(String? bundleDir) => bundleDir == null
    ? const SystemProcessRunner()
    : ExiftoolRunner(
        const SystemProcessRunner(),
        ExiftoolInvocation.resolve(bundleDir),
      );

/// Pipes [events] to [port], then sends the null sentinel. A thrown error is
/// converted by [onError] (an [ErrorEvent] or [ScanLogEvent]) before the
/// sentinel, so the consumer's stream always closes cleanly.
Future<void> _pump<E>(
  SendPort port,
  Stream<E> events, {
  required E Function(String message) onError,
}) async {
  try {
    await for (final event in events) {
      port.send(event);
    }
  } on Object catch (e) {
    port.send(onError('$e'));
  } finally {
    port.send(null);
  }
}

Future<void> _scanEntry(_ScanRequest req) async {
  try {
    await _pump(
      req.port,
      FolderScanner().scan(req.roots),
      onError: ScanLogEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ScanLogEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _tagEntry(_TagRequest req) async {
  try {
    final exiftool = await _resolveExiftool(req.exiftoolAvailable);
    final runner = _buildRunner(req.bundleDir);
    final registry = BackendRegistry(
      runner: runner,
      rawMode: req.options.rawMode,
      exiftoolAvailable: exiftool,
    );
    // Pool every GPS source found in the scan (gpx + kml → track, json →
    // google), inside the worker so parsing never touches the UI isolate.
    final pool = poolSources(
      gpxFiles: req.gpxFiles,
      kmlFiles: req.kmlFiles,
      googleJsonFiles: req.googleFiles,
    );
    final stream = TagService(registry: registry).tag(
      photos: req.photos,
      gpx: pool.track,
      google: pool.google,
      options: req.options,
    );
    await _pump(req.port, stream, onError: ErrorEvent.new);
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _mapEntry(_MapRequest req) async {
  try {
    final exiftool = await _resolveExiftool(req.exiftoolAvailable);
    final service = MapService(
      runner: _buildRunner(req.bundleDir),
      exiftoolAvailable: exiftool,
    );
    await _pump(
      req.port,
      service.render(req.photos, req.options),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _pruneEntry(_PruneRequest req) async {
  try {
    final pruner = Pruner(trash: const SystemTrash());
    await _pump(
      req.port,
      pruner.prune(req.roots, req.options),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _trashPathsEntry(_TrashPathsRequest req) async {
  try {
    final pruner = Pruner(trash: const SystemTrash());
    await _pump(
      req.port,
      pruner.trashPaths(req.paths, delete: req.delete),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _readImageMetaEntry(_ReadImageMetaRequest req) async {
  try {
    final runner = _buildRunner(req.bundleDir);
    await for (final meta in readImageMeta(req.paths, runner: runner)) {
      req.port.send(meta);
    }
  } on Object {
    // Best-effort: a failed exiftool read just leaves rows un-enriched.
  } finally {
    req.port.send(null);
  }
}

Future<void> _fixDatesEntry(_FixDatesRequest req) async {
  try {
    final exiftool = await _resolveExiftool(req.exiftoolAvailable);
    final runner = _buildRunner(req.bundleDir);
    final registry = BackendRegistry(
      runner: runner,
      exiftoolAvailable: exiftool,
    );
    final dater = Dater(exif: DispatchingExifBackend(registry), runner: runner);
    await _pump(
      req.port,
      dater.fixDates(req.files, req.mode, dryRun: req.dryRun),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}
