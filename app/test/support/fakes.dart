import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/engine/engine_runner.dart';
import 'package:stunda/src/i18n/app_localizations.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// An English [Translator] for unit tests: resolves keys through the bundled
/// compile-time English map and interpolates `{placeholders}`, exactly like the
/// runtime fallback. Lets pure model/label functions be asserted in English.
String enTr(String key, [Map<String, Object?>? params]) {
  final template = kEnglishStrings[key] ?? key;
  if (params == null || params.isEmpty) return template;
  return template.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (m) =>
        params.containsKey(m.group(1)) ? '${params[m.group(1)]}' : m.group(0)!,
  );
}

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
    Map<String, CuratedExif>? curatedExif,
  }) : _events = events ?? _success(),
       _scanEvents = scanEvents ?? _scanSuccess(),
       _imageMeta = imageMeta ?? const {},
       _curatedExif = curatedExif ?? const {};

  /// Canned per-path image metadata returned by [readImageMeta].
  final Map<String, FileMeta> _imageMeta;

  /// Canned per-path curated EXIF returned by [readCuratedExif].
  final Map<String, CuratedExif> _curatedExif;

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

  /// Names of the operations invoked, in order (`tag`, `prune`, ...).
  final List<String> calls = [];

  /// The [TagOptions] passed to the last [tag] call, for assertions.
  TagOptions? lastTagOptions;

  /// Path lists passed to the last [tag] call, for exclusion assertions.
  List<String>? lastTagPhotos;
  List<String>? lastTagGpx;

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

  /// The roots passed to the most recent [scan] call, for assertions.
  List<String>? lastScanRoots;

  @override
  Stream<ScanEvent> scan(List<String> roots) async* {
    calls.add('scan');
    lastScanRoots = roots;
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

  /// Paths passed to the last [readCuratedExif] call, for assertions.
  List<String>? lastCuratedExifPaths;

  @override
  Stream<CuratedExif> readCuratedExif(List<String> paths) async* {
    calls.add('readCuratedExif');
    lastCuratedExifPaths = paths;
    for (final path in paths) {
      yield _curatedExif[path] ?? CuratedExif(path: path);
    }
  }

  /// Per-source extracted preview paths returned by [extractPreview]; an absent
  /// path yields null (no embedded preview).
  final Map<String, String?> previews = {};

  /// How many times [extractPreview] actually ran (to prove memoization).
  int extractPreviewCalls = 0;

  /// The `full` flag from the most recent [extractPreview] call (proves the
  /// miniature requests the high-res preview).
  final List<bool> extractFullFlags = [];

  @override
  Future<String?> extractPreview(String path, {bool full = false}) async {
    calls.add('extractPreview');
    extractPreviewCalls++;
    extractFullFlags.add(full);
    return previews[path];
  }

  /// Canned duplicate groups returned by [findDuplicates].
  List<DuplicateGroup> duplicateGroups = const [];

  /// The min-similarity cutoff passed to the last [findDuplicates] call.
  double? lastDuplicateMinSimilarity;

  /// Paths passed to the last [findDuplicates] call.
  List<String>? lastDuplicatePaths;

  /// When set, [findDuplicates] waits on this before returning, so a test can
  /// observe the in-flight `findingDuplicates` state.
  Completer<void>? duplicatesGate;

  /// The most recent `onProgress` callback handed to [findDuplicates], so a
  /// test can drive ticks and observe the controller's live hashing state.
  void Function(int done, int total)? lastOnProgress;

  /// The metric passed to the last [findDuplicates] call.
  SimilarityMetric? lastDuplicateMetric;

  /// Whether this fake reports the Smart metric as available (drives the
  /// controller's "fell back to Fast" note in tests).
  bool smartAvailableValue = true;

  @override
  bool get smartAvailable => smartAvailableValue;

  @override
  Future<List<DuplicateGroup>> findDuplicates(
    List<String> paths, {
    required double minSimilarity,
    SimilarityMetric metric = SimilarityMetric.fast,
    void Function(int done, int total)? onProgress,
  }) async {
    calls.add('findDuplicates');
    lastDuplicateMinSimilarity = minSimilarity;
    lastDuplicatePaths = paths;
    lastDuplicateMetric = metric;
    lastOnProgress = onProgress;
    if (duplicatesGate != null) await duplicatesGate!.future;
    return duplicateGroups;
  }

  /// Canned hashed files returned by [hashFiles] (carrying quality scores).
  List<HashedFile> hashedFiles = const [];

  /// Paths passed to the last [hashFiles] call.
  List<String>? lastHashFilesPaths;

  /// Whether the last [hashFiles] call requested embeddings.
  bool? lastHashFilesEmbed;

  @override
  Future<List<HashedFile>> hashFiles(
    List<String> paths, {
    bool embed = false,
    void Function(int done, int total)? onProgress,
  }) async {
    calls.add('hashFiles');
    lastHashFilesPaths = paths;
    lastHashFilesEmbed = embed;
    lastOnProgress = onProgress;
    if (duplicatesGate != null) await duplicatesGate!.future;
    return hashedFiles;
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
  Stream<CuratedExif> readCuratedExif(List<String> paths) =>
      Stream<CuratedExif>.error(StateError('readCuratedExif blew up'));

  @override
  Future<String?> extractPreview(String path, {bool full = false}) async =>
      throw StateError('extractPreview blew up');

  @override
  bool get smartAvailable => false;

  @override
  Future<List<DuplicateGroup>> findDuplicates(
    List<String> paths, {
    required double minSimilarity,
    SimilarityMetric metric = SimilarityMetric.fast,
    void Function(int done, int total)? onProgress,
  }) async => throw StateError('findDuplicates blew up');

  @override
  Future<List<HashedFile>> hashFiles(
    List<String> paths, {
    bool embed = false,
    void Function(int done, int total)? onProgress,
  }) async => throw StateError('hashFiles blew up');
}

/// An in-memory [PhotoLibrary] for mobile controller tests: enumerates the
/// seeded [assets], exports a fake proxy path per asset, and records the ids
/// passed to [delete]/[writeGps] so the trash + tag wiring can be asserted
/// without a device, a plugin, or a platform channel.
class FakePhotoLibrary implements PhotoLibrary {
  FakePhotoLibrary(this.assets);

  /// The library contents this fake reports from [enumerate].
  List<LibraryAsset> assets;

  /// Asset ids passed to the most recent [delete] call.
  List<String>? deletedIds;

  /// (id, lat, lng) tuples passed to [writeGps], in call order.
  final List<(String, double, double)> gpsWrites = [];

  /// Ids whose [exportProxy] should throw (simulating an un-exportable asset).
  final Set<String> exportFailures = {};

  /// When set, [delete] throws this (simulating a native delete failure).
  Object? deleteError;

  /// When set, [writeGps] throws this (simulating a native GPS-write failure).
  Object? writeGpsError;

  /// Full-resolution bytes returned by [fullBytes], keyed by asset id; an absent
  /// id yields empty bytes (so the viewer shows the proxy placeholder).
  final Map<String, Uint8List> fullBytesById = {};

  /// The fake proxy path for an asset id (the engine-facing temp path).
  static String proxyPathFor(String id) => '/proxies/$id.jpg';

  @override
  Future<List<LibraryAsset>> enumerate() async => assets;

  @override
  Future<String> exportProxy(String id, int maxEdge) async {
    if (exportFailures.contains(id)) throw StateError('export failed: $id');
    return proxyPathFor(id);
  }

  @override
  Future<Uint8List> thumbnail(String id, int edge) async => Uint8List(0);

  @override
  Future<Uint8List> fullBytes(String id) async =>
      fullBytesById[id] ?? Uint8List(0);

  @override
  Future<void> writeGps(String id, double latitude, double longitude) async {
    if (writeGpsError != null) throw writeGpsError!;
    gpsWrites.add((id, latitude, longitude));
  }

  @override
  Future<void> delete(List<String> ids) async {
    if (deleteError != null) throw deleteError!;
    deletedIds = ids;
  }
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
