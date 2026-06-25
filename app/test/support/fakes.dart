import 'dart:async';
import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/engine/engine_runner.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A scripted [EngineRunner] that returns a canned [EngineEvent] stream for
/// every operation without spawning a single isolate. Each method records that
/// it was called so tests can assert the wiring, and yields whatever events the
/// constructor was handed (defaulting to a one-item success run).
class FakeEngineRunner implements EngineRunner {
  FakeEngineRunner({
    List<EngineEvent>? events,
    List<ScanEvent>? scanEvents,
    this.keepOpen = false,
    Map<String, FileMeta>? imageMeta,
  }) : _events = events ?? _success(),
       _scanEvents = scanEvents ?? _scanSuccess(),
       _imageMeta = imageMeta ?? const {};

  /// Canned per-path image metadata returned by [readImageMeta].
  final Map<String, FileMeta> _imageMeta;

  final List<EngineEvent> _events;
  final List<ScanEvent> _scanEvents;

  /// When true the returned stream stays open after the scripted events, so the
  /// controller's `running` state (and the live progress UI) persists for
  /// assertions. Tests gate completion via [release].
  final bool keepOpen;
  final _gate = Completer<void>();

  /// Lets a [keepOpen] stream finish (fires onDone in the controller).
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  /// Names of the operations invoked, in order (`tag`, `map`, `prune`, ...).
  final List<String> calls = [];

  /// The [TagOptions] passed to the last [tag] call, for assertions.
  TagOptions? lastTagOptions;

  /// Path lists passed to the last [tag] call, for exclusion assertions.
  List<String>? lastTagPhotos;
  List<String>? lastTagGpx;

  /// The photos passed to the last [map] call, for exclusion assertions.
  List<String>? lastMapPhotos;

  /// The paths passed to the last [trashPaths] call, for assertions.
  List<String>? lastTrashedPaths;

  static List<EngineEvent> _success() => [
    const LogEvent('working'),
    const ProgressEvent(done: 1, total: 1),
    const ItemEvent(
      PhotoRow(
        path: '/photos/a.jpg',
        status: PhotoStatus.tagged,
        location: LocationResult(
          latitude: 42.5,
          longitude: 18.1,
          source: GpsSource.gpx,
          method: GpsMethod.exact,
        ),
      ),
    ),
    const DoneEvent({'tagged': 1}),
  ];

  static List<ScanEvent> _scanSuccess() => [
    const ScanProgressEvent(ScanProgress(files: 1, photos: 1)),
    ScanDoneEvent(fakeScan(photos: const ['/library/a.jpg'])),
  ];

  Stream<EngineEvent> _emit() async* {
    for (final event in _events) {
      yield event;
    }
    if (keepOpen) await _gate.future;
  }

  @override
  Stream<ScanEvent> scan(List<String> roots) async* {
    calls.add('scan');
    for (final event in _scanEvents) {
      yield event;
    }
    if (keepOpen) await _gate.future;
  }

  @override
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> kmlFiles,
    required List<String> googleFiles,
    required TagOptions options,
  }) {
    calls.add('tag');
    lastTagOptions = options;
    lastTagPhotos = photos;
    lastTagGpx = gpxFiles;
    return _emit();
  }

  @override
  Stream<EngineEvent> map({
    required List<String> photos,
    required MapOptions options,
  }) {
    calls.add('map');
    lastMapPhotos = photos;
    // Write a tiny real PNG so result_step's Image.file has a file to point at.
    File(
      options.outputPng,
    ).writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));
    return _emit();
  }

  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) {
    calls.add('prune');
    return _emit();
  }

  @override
  Stream<EngineEvent> trashPaths(List<String> paths, {bool delete = false}) {
    calls.add('trashPaths');
    lastTrashedPaths = paths;
    return _emit();
  }

  @override
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  }) {
    calls.add('fixDates');
    return _emit();
  }

  /// Paths passed to the last [readImageMeta] call, for assertions.
  List<String>? lastImageMetaPaths;

  @override
  Stream<FileMeta> readImageMeta(List<String> paths) async* {
    calls.add('readImageMeta');
    lastImageMetaPaths = paths;
    for (final path in paths) {
      yield _imageMeta[path] ?? FileMeta(path: path);
    }
  }

  /// Per-source extracted preview paths returned by [extractPreview]; an absent
  /// path yields null (no embedded preview).
  final Map<String, String?> previews = {};

  /// How many times [extractPreview] actually ran (to prove memoization).
  int extractPreviewCalls = 0;

  @override
  Future<String?> extractPreview(String path, {bool full = false}) async {
    calls.add('extractPreview');
    extractPreviewCalls++;
    return previews[path];
  }
}

/// An [EngineRunner] whose streams emit a stream-level error (rather than an
/// [ErrorEvent]), exercising the controller's `onError` handling.
class ThrowingEngineRunner implements EngineRunner {
  Stream<EngineEvent> _boom() =>
      Stream<EngineEvent>.error(StateError('stream blew up'));

  @override
  Stream<ScanEvent> scan(List<String> roots) =>
      Stream<ScanEvent>.error(StateError('scan blew up'));

  @override
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> kmlFiles,
    required List<String> googleFiles,
    required TagOptions options,
  }) => _boom();

  @override
  Stream<EngineEvent> map({
    required List<String> photos,
    required MapOptions options,
  }) => _boom();

  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) => _boom();

  @override
  Stream<EngineEvent> trashPaths(List<String> paths, {bool delete = false}) =>
      _boom();

  @override
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  }) => _boom();

  @override
  Stream<FileMeta> readImageMeta(List<String> paths) =>
      Stream<FileMeta>.error(StateError('readImageMeta blew up'));

  @override
  Future<String?> extractPreview(String path, {bool full = false}) async =>
      throw StateError('extractPreview blew up');
}

/// Builds a [FolderScanResult] for tests with controllable tallies.
///
/// Defaults to a tiny library with one JPG and no GPS sources. Pass explicit
/// path/count lists to exercise readiness and content-panel rendering.
FolderScanResult fakeScan({
  List<String> photos = const ['/library/a.jpg'],
  List<String> gpxFiles = const [],
  List<String> kmlFiles = const [],
  List<String> googleFiles = const [],
  List<UnsupportedFile> unsupported = const [],
  int dirs = 1,
}) {
  final byExt = <String, int>{};
  for (final path in photos) {
    final ext = PhotoFormats.extOf(path);
    byExt.update(ext, (n) => n + 1, ifAbsent: () => 1);
  }
  final unsByExt = <String, int>{};
  final unsByCat = <UnsupportedCategory, int>{};
  for (final u in unsupported) {
    final dot = u.path.lastIndexOf('.');
    final ext = dot < 0 ? '' : u.path.substring(dot + 1).toLowerCase();
    unsByExt.update(ext, (n) => n + 1, ifAbsent: () => 1);
    unsByCat.update(u.category, (n) => n + 1, ifAbsent: () => 1);
  }
  return FolderScanResult(
    files:
        photos.length +
        gpxFiles.length +
        kmlFiles.length +
        googleFiles.length +
        unsupported.length,
    dirs: dirs,
    byExtension: byExt,
    photos: photos,
    gpxFiles: gpxFiles,
    kmlFiles: kmlFiles,
    googleFiles: googleFiles,
    unsupported: unsupported,
    unsupportedByExtension: unsByExt,
    unsupportedByCategory: unsByCat,
    unsupportedTotal: unsupported.length,
  );
}

/// Writes a tiny synthetic JPEG carrying [dateTimeOriginal] and returns its
/// path. Used so tagging finds a real photo on disk.
Future<String> writeJpegWithDate(
  Directory dir,
  String name, {
  DateTime? dateTimeOriginal,
}) async {
  final path = p.join(dir.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
  if (dateTimeOriginal != null) {
    await const JpegExifBackend().writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: dateTimeOriginal,
    );
  }
  return path;
}

/// Writes a minimal one-point GPX file and returns its path.
String writeGpx(
  Directory dir,
  String name,
  DateTime time, {
  double lat = 42.5,
  double lon = 18.1,
}) {
  final path = p.join(dir.path, name);
  final iso = time.toUtc().toIso8601String();
  File(path).writeAsStringSync('''
<?xml version="1.0"?>
<gpx version="1.1" creator="test">
  <trk><trkseg>
    <trkpt lat="$lat" lon="$lon"><time>$iso</time></trkpt>
  </trkseg></trk>
</gpx>
''');
  return path;
}
