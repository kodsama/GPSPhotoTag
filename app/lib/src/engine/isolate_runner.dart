import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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
    scanEntry,
    (port) => ScanRequest(port: port, roots: roots),
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
    tagEntry,
    (port) => TagRequest(
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

  /// Prunes orphan RAW files under [roots].
  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) => _spawn(
    pruneEntry,
    (port) => PruneRequest(port: port, roots: roots, options: options),
    onSpawnError: ErrorEvent.new,
  );

  /// Moves exactly the given [paths] (plus sidecars) to Trash on a worker.
  @override
  Stream<EngineEvent> trashPaths(List<String> paths, {bool delete = false}) =>
      _spawn(
        trashPathsEntry,
        (port) => TrashPathsRequest(port: port, paths: paths, delete: delete),
        onSpawnError: ErrorEvent.new,
      );

  /// Fixes capture/file dates for [files] in the given [mode].
  @override
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  }) => _spawn(
    fixDatesEntry,
    (port) => FixDatesRequest(
      port: port,
      files: files,
      mode: mode,
      dryRun: dryRun,
      exiftoolAvailable: exiftoolAvailable,
      bundleDir: exiftoolBundleDir,
    ),
    onSpawnError: ErrorEvent.new,
  );

  /// Batch-reads image metadata for [paths], FANNED OUT across several worker
  /// isolates (each running its own exiftool) so thousands of files fill in
  /// quickly; results from all workers are merged into one stream and arrive as
  /// each chunk is read. The stream closes when every worker is done.
  @override
  Stream<FileMeta> readImageMeta(List<String> paths) {
    if (paths.isEmpty) return const Stream<FileMeta>.empty();
    // One worker per ~chunk, capped so we don't oversubscribe the CPU.
    final cores = Platform.numberOfProcessors;
    final workers = paths.length <= 64
        ? 1
        : (cores - 2).clamp(2, 6).clamp(1, (paths.length / 64).ceil());

    final controller = StreamController<FileMeta>();
    final isolates = <Isolate>[];
    var active = workers;

    void onWorkerDone() {
      active--;
      if (active <= 0 && !controller.isClosed) controller.close();
    }

    for (var w = 0; w < workers; w++) {
      // Round-robin slice so progress is spread evenly across workers.
      final slice = [for (var i = w; i < paths.length; i += workers) paths[i]];
      final receive = ReceivePort();
      receive.listen((message) {
        if (message == null) {
          receive.close();
          onWorkerDone();
        } else if (message is FileMeta && !controller.isClosed) {
          controller.add(message);
        }
      });
      Isolate.spawn(
        readImageMetaEntry,
        ReadImageMetaRequest(
          port: receive.sendPort,
          paths: slice,
          bundleDir: exiftoolBundleDir,
        ),
      ).then((iso) => isolates.add(iso), onError: (_, _) => onWorkerDone());
    }

    controller.onCancel = () {
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
    };
    return controller.stream;
  }

  /// Extracts an embedded JPEG preview of [path] on a one-shot worker isolate
  /// via the bundled exiftool, returning the cached JPEG path (or null when no
  /// embedded image is produced or the worker fails to start).
  @override
  Future<String?> extractPreview(String path, {bool full = false}) async {
    final receive = ReceivePort();
    try {
      await Isolate.spawn(
        extractPreviewEntry,
        ExtractPreviewRequest(
          port: receive.sendPort,
          path: path,
          full: full,
          bundleDir: exiftoolBundleDir,
        ),
      );
    } on Object {
      receive.close();
      return null;
    }
    final result = await receive.first;
    receive.close();
    return result is String ? result : null;
  }

  /// Perceptually hashes [paths] across worker isolates, then groups the
  /// returned [HashedFile]s within [threshold] on the UI isolate (cheap, pure).
  ///
  /// Fans the paths out round-robin across a CPU-bounded set of workers (each
  /// running its own bundled exiftool for RAW/HEIC previews), collects every
  /// hashed file, then runs [groupDuplicates]. Undecodable files and a worker
  /// that fails to start are simply skipped.
  @override
  Future<List<DuplicateGroup>> findDuplicates(
    List<String> paths, {
    required int threshold,
  }) async {
    if (paths.isEmpty) return const [];
    final cores = Platform.numberOfProcessors;
    final workers = paths.length <= 32
        ? 1
        : (cores - 2).clamp(2, 6).clamp(1, (paths.length / 32).ceil());

    final results = <int, List<HashedFile>>{};
    final futures = <Future<void>>[];

    for (var w = 0; w < workers; w++) {
      final slice = [for (var i = w; i < paths.length; i += workers) paths[i]];
      final receive = ReceivePort();
      final done = Completer<void>();
      final collected = <HashedFile>[];
      receive.listen((message) {
        if (message == null) {
          receive.close();
          if (!done.isCompleted) done.complete();
        } else if (message is HashedFile) {
          collected.add(message);
        }
      });
      final slot = w;
      results[slot] = collected;
      Isolate.spawn(
        hashFilesEntry,
        HashFilesRequest(
          port: receive.sendPort,
          paths: slice,
          bundleDir: exiftoolBundleDir,
        ),
      ).catchError((Object _) {
        // A worker that never starts contributes no hashes; unblock the join.
        receive.close();
        if (!done.isCompleted) done.complete();
        return Isolate.current;
      });
      futures.add(done.future);
    }

    await Future.wait(futures);
    // Concatenate worker outputs in worker order for deterministic grouping.
    final all = <HashedFile>[for (var w = 0; w < workers; w++) ...?results[w]];
    return groupDuplicates(all, threshold: threshold);
  }

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
//
// These payloads and the worker entry points below are library-public ONLY so
// they can be driven in-process by tests (coverage tooling can't see code that
// runs on a spawned isolate). They are not part of the app's API surface.

@visibleForTesting
class ScanRequest {
  const ScanRequest({required this.port, required this.roots});

  final SendPort port;
  final List<String> roots;
}

@visibleForTesting
class TagRequest {
  const TagRequest({
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

@visibleForTesting
class PruneRequest {
  const PruneRequest({
    required this.port,
    required this.roots,
    required this.options,
  });

  final SendPort port;
  final List<String> roots;
  final PruneOptions options;
}

@visibleForTesting
class TrashPathsRequest {
  const TrashPathsRequest({
    required this.port,
    required this.paths,
    required this.delete,
  });

  final SendPort port;
  final List<String> paths;
  final bool delete;
}

@visibleForTesting
class FixDatesRequest {
  const FixDatesRequest({
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

@visibleForTesting
class ReadImageMetaRequest {
  const ReadImageMetaRequest({
    required this.port,
    required this.paths,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> paths;
  final String? bundleDir;
}

@visibleForTesting
class HashFilesRequest {
  const HashFilesRequest({
    required this.port,
    required this.paths,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> paths;
  final String? bundleDir;
}

@visibleForTesting
class ExtractPreviewRequest {
  const ExtractPreviewRequest({
    required this.port,
    required this.path,
    required this.full,
    required this.bundleDir,
  });

  final SendPort port;
  final String path;
  final bool full;
  final String? bundleDir;
}

// --- Worker entry points (top-level, run on the spawned isolate) -----------

/// Detects exiftool inside the worker when the caller did not pass a value.
@visibleForTesting
Future<bool> resolveWorkerExiftool(bool? passed) async {
  if (passed != null) return passed;
  final tools = await ToolkitChecker(const SystemProcessRunner()).check();
  return tools.any((t) => t.id == 'exiftool' && t.present);
}

/// Builds the runner for a worker: a plain system runner when no bundle dir is
/// known, otherwise one that routes `exiftool` to the bundled copy.
@visibleForTesting
ProcessRunner buildWorkerRunner(String? bundleDir) => bundleDir == null
    ? const SystemProcessRunner()
    : ExiftoolRunner(
        const SystemProcessRunner(),
        ExiftoolInvocation.resolve(bundleDir),
      );

/// Pipes [events] to [port], then sends the null sentinel. A thrown error is
/// converted by [onError] (an [ErrorEvent] or [ScanLogEvent]) before the
/// sentinel, so the consumer's stream always closes cleanly.
@visibleForTesting
Future<void> pumpEvents<E>(
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

@visibleForTesting
Future<void> scanEntry(ScanRequest req) async {
  try {
    await pumpEvents(
      req.port,
      FolderScanner().scan(req.roots),
      onError: ScanLogEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ScanLogEvent('$e'));
    req.port.send(null);
  }
}

@visibleForTesting
Future<void> tagEntry(TagRequest req) async {
  try {
    final exiftool = await resolveWorkerExiftool(req.exiftoolAvailable);
    final runner = buildWorkerRunner(req.bundleDir);
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
    await pumpEvents(req.port, stream, onError: ErrorEvent.new);
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

@visibleForTesting
Future<void> pruneEntry(PruneRequest req) async {
  try {
    final pruner = Pruner(trash: const SystemTrash());
    await pumpEvents(
      req.port,
      pruner.prune(req.roots, req.options),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

@visibleForTesting
Future<void> trashPathsEntry(TrashPathsRequest req) async {
  try {
    final pruner = Pruner(trash: const SystemTrash());
    await pumpEvents(
      req.port,
      pruner.trashPaths(req.paths, delete: req.delete),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

@visibleForTesting
Future<void> readImageMetaEntry(ReadImageMetaRequest req) async {
  try {
    final runner = buildWorkerRunner(req.bundleDir);
    await for (final meta in readImageMeta(req.paths, runner: runner)) {
      req.port.send(meta);
    }
  } on Object {
    // Best-effort: a failed exiftool read just leaves rows un-enriched.
  } finally {
    req.port.send(null);
  }
}

/// The shared on-disk cache directory for extracted previews (stable across a
/// session so re-opening a photo is instant). Lives under the system temp dir,
/// which is reachable from any isolate without a platform plugin.
@visibleForTesting
Directory previewCacheDir() =>
    Directory(p.join(Directory.systemTemp.path, 'stunda_preview_cache'));

@visibleForTesting
Future<void> hashFilesEntry(HashFilesRequest req) async {
  try {
    final runner = buildWorkerRunner(req.bundleDir);
    final cacheDir = previewCacheDir().path;
    for (final path in req.paths) {
      final hashed = await hashFile(path, runner: runner, cacheDir: cacheDir);
      // Skip undecodable files (RAW with no preview, corrupt images, …).
      if (hashed != null) req.port.send(hashed);
    }
  } on Object {
    // Best-effort: a failed worker just contributes no hashes.
  } finally {
    req.port.send(null);
  }
}

@visibleForTesting
Future<void> extractPreviewEntry(ExtractPreviewRequest req) async {
  String? result;
  try {
    final runner = buildWorkerRunner(req.bundleDir);
    result = await extractPreview(
      req.path,
      cacheDir: previewCacheDir().path,
      size: req.full ? PreviewSize.full : PreviewSize.thumb,
      runner: runner,
    );
  } on Object {
    result = null; // best-effort: a failed extract just keeps the placeholder
  } finally {
    req.port.send(result);
  }
}

@visibleForTesting
Future<void> fixDatesEntry(FixDatesRequest req) async {
  try {
    final exiftool = await resolveWorkerExiftool(req.exiftoolAvailable);
    final runner = buildWorkerRunner(req.bundleDir);
    final registry = BackendRegistry(
      runner: runner,
      exiftoolAvailable: exiftool,
    );
    final dater = Dater(exif: DispatchingExifBackend(registry), runner: runner);
    await pumpEvents(
      req.port,
      dater.fixDates(req.files, req.mode, dryRun: req.dryRun),
      onError: ErrorEvent.new,
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}
