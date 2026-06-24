import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';

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

  /// Tags [photos] using GPS read from [gpxFiles] and [googleFiles].
  @override
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> googleFiles,
    required TagOptions options,
  }) => _spawn(
    _tagEntry,
    (port) => _TagRequest(
      port: port,
      photos: photos,
      gpxFiles: gpxFiles,
      googleFiles: googleFiles,
      options: options,
      exiftoolAvailable: exiftoolAvailable,
      bundleDir: exiftoolBundleDir,
    ),
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
  );

  /// Prunes orphan RAW files under [roots].
  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) => _spawn(
    _pruneEntry,
    (port) => _PruneRequest(port: port, roots: roots, options: options),
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
  );

  /// Spawns a worker via [entry], wiring its [SendPort] into the request built
  /// by [makeRequest], and re-emits everything it sends until the null sentinel.
  Stream<EngineEvent> _spawn<R>(
    void Function(R) entry,
    R Function(SendPort) makeRequest,
  ) {
    final controller = StreamController<EngineEvent>.broadcast();
    final receive = ReceivePort();
    Isolate? isolate;

    receive.listen((message) {
      if (message == null) {
        controller.close();
        receive.close();
        isolate?.kill(priority: Isolate.immediate);
        return;
      }
      if (message is EngineEvent) controller.add(message);
    });

    Isolate.spawn(entry, makeRequest(receive.sendPort)).then(
      (spawned) => isolate = spawned,
      onError: (Object e, StackTrace _) {
        controller.add(ErrorEvent('failed to start worker: $e'));
        controller.close();
        receive.close();
      },
    );

    return controller.stream;
  }
}

// --- Request payloads (plain data, isolate-sendable) ----------------------

class _TagRequest {
  const _TagRequest({
    required this.port,
    required this.photos,
    required this.gpxFiles,
    required this.googleFiles,
    required this.options,
    required this.exiftoolAvailable,
    required this.bundleDir,
  });

  final SendPort port;
  final List<String> photos;
  final List<String> gpxFiles;
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

/// Reads and parses every GPX file into a flat, time-sorted point list.
List<TimedPoint> _loadGpx(List<String> files) {
  final points = <TimedPoint>[];
  for (final path in files) {
    points.addAll(parseGpx(File(path).readAsStringSync()));
  }
  points.sort();
  return points;
}

/// Reads and parses every Google history file into a flat point list.
List<TimedPoint> _loadGoogle(List<String> files) {
  final points = <TimedPoint>[];
  for (final path in files) {
    points.addAll(parseGoogleAuto(File(path).readAsStringSync()));
  }
  points.sort();
  return points;
}

/// Pipes [events] to [port], then sends the null sentinel; converts a thrown
/// error into an [ErrorEvent] before the sentinel.
Future<void> _pump(SendPort port, Stream<EngineEvent> events) async {
  try {
    await for (final event in events) {
      port.send(event);
    }
  } on Object catch (e) {
    port.send(ErrorEvent('$e'));
  } finally {
    port.send(null);
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
    final gpx = _loadGpx(req.gpxFiles);
    final google = _loadGoogle(req.googleFiles);
    final stream = TagService(
      registry: registry,
    ).tag(photos: req.photos, gpx: gpx, google: google, options: req.options);
    await _pump(req.port, stream);
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
    await _pump(req.port, service.render(req.photos, req.options));
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}

Future<void> _pruneEntry(_PruneRequest req) async {
  try {
    final pruner = Pruner(trash: const SystemTrash());
    await _pump(req.port, pruner.prune(req.roots, req.options));
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
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
    );
  } on Object catch (e) {
    req.port.send(ErrorEvent('$e'));
    req.port.send(null);
  }
}
