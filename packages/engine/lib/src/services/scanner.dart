import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/photo_formats.dart';
import '../domain/folder_scan.dart';

/// Bytes of a `.json` file read when sniffing for Google location history.
const int _jsonSniffBytes = 64 * 1024;

/// Markers that identify a `.json` file as Google location history.
const _googleMarkers = [
  '"locations"',
  '"semanticSegments"',
  '"timelineObjects"',
];

/// Recursively scans a mix of folders and individual files, classifying every
/// file and streaming progress.
///
/// Each root may be a DIRECTORY (walked recursively as below) or a single FILE
/// (classified directly). This lets a library be assembled from several folders
/// and/or hand-picked images and GPS files. A file that appears under more than
/// one root — for example a file root that also lives inside a directory root —
/// is counted exactly once.
///
/// Designed for trees with hundreds of thousands of files in arbitrary nesting
/// (years/months, split jpg/raw/gps folders, or all mixed). A bounded worker
/// pool reads directories concurrently — the walk is I/O-bound — and running
/// totals are emitted as throttled [ScanProgressEvent]s so a UI stays
/// responsive. In the app this runs off the UI isolate.
///
/// Files classify as: taggable photo ([PhotoFormats.isPhoto]); GPS track
/// (`.gpx` and `.kml`, both parseable downstream); validated Google history
/// (`.json` whose first ~64KB contains a known location marker); otherwise an
/// [UnsupportedFile] bucketed by [categorizeUnsupported] (a `.json` without a
/// marker becomes [UnsupportedCategory.other]).
class FolderScanner {
  /// Creates a scanner.
  ///
  /// [concurrency] bounds how many directories are listed at once; [throttle]
  /// is the minimum gap between [ScanProgressEvent]s.
  FolderScanner({
    this.concurrency = 8,
    this.throttle = const Duration(milliseconds: 150),
  });

  /// Maximum number of directories listed concurrently.
  final int concurrency;

  /// Minimum interval between progress events.
  final Duration throttle;

  /// Scans [roots] (each a directory or a single file) and streams events.
  ///
  /// Emits throttled [ScanProgressEvent]s while walking, a [ScanLogEvent] for
  /// each unreadable directory (skipped, never fatal), and a final
  /// [ScanDoneEvent] carrying the complete [FolderScanResult]. A file that
  /// appears under more than one root is counted once.
  Stream<ScanEvent> scan(List<String> roots) {
    final controller = StreamController<ScanEvent>();
    _run(roots, controller);
    return controller.stream;
  }

  Future<void> _run(
    List<String> roots,
    StreamController<ScanEvent> controller,
  ) async {
    final state = _ScanState();
    // Split roots into directories (walked) and individual files (classified
    // directly). A root whose type can't be read (nonexistent, permission) is
    // tolerated: it contributes nothing and never aborts the scan.
    final queue = <String>[];
    final fileRoots = <String>[];
    for (final root in roots) {
      final type = FileSystemEntity.typeSync(root, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        queue.add(root);
      } else if (type == FileSystemEntityType.file) {
        fileRoots.add(root);
      } else {
        // Nonexistent, a broken link, or a special file: tolerated, never fatal.
        controller.add(ScanLogEvent('skipped missing path: $root'));
      }
    }
    for (final path in fileRoots) {
      await state.classify(path);
    }
    var active = 0;
    final completer = Completer<void>();
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

    void maybeEmitProgress({bool force = false}) {
      final now = DateTime.now();
      if (force || now.difference(lastEmit) >= throttle) {
        lastEmit = now;
        controller.add(ScanProgressEvent(state.snapshot()));
      }
    }

    void pump() {
      while (active < concurrency && queue.isNotEmpty) {
        final dir = queue.removeLast();
        active++;
        unawaited(
          _scanDir(dir, state, queue, controller).whenComplete(() {
            active--;
            maybeEmitProgress();
            if (active == 0 && queue.isEmpty) {
              if (!completer.isCompleted) completer.complete();
            } else {
              pump();
            }
          }),
        );
      }
    }

    if (queue.isEmpty) {
      completer.complete();
    } else {
      pump();
    }

    await completer.future;
    maybeEmitProgress(force: true);
    controller.add(ScanDoneEvent(state.toResult()));
    await controller.close();
  }

  Future<void> _scanDir(
    String dir,
    _ScanState state,
    List<String> queue,
    StreamController<ScanEvent> controller,
  ) async {
    state.dirs++;
    try {
      final entries = Directory(dir).list(followLinks: false);
      await for (final entity in entries) {
        if (entity is Directory) {
          queue.add(entity.path);
        } else if (entity is File) {
          await state.classify(entity.path);
        }
      }
    } on FileSystemException catch (e) {
      controller.add(ScanLogEvent('skipped unreadable directory: $dir ($e)'));
    }
  }
}

/// Whether the head of [path] (a `.json` file) looks like Google history.
///
/// Reads at most [_jsonSniffBytes] and checks for any [_googleMarkers]. Returns
/// false on read errors so an unreadable JSON falls into "other" rather than
/// aborting the scan.
Future<bool> _looksLikeGoogleJson(String path) async {
  try {
    final bytes = <int>[];
    await for (final chunk in File(path).openRead(0, _jsonSniffBytes)) {
      bytes.addAll(chunk);
    }
    final head = utf8.decode(bytes, allowMalformed: true);
    return _googleMarkers.any(head.contains);
  } on FileSystemException {
    return false;
  }
}

/// Mutable accumulator shared across the worker pool.
class _ScanState {
  int files = 0;
  int dirs = 0;
  int unsupportedTotal = 0;
  final byExtension = <String, int>{};
  final unsupportedByExtension = <String, int>{};
  final unsupportedByCategory = <UnsupportedCategory, int>{};
  final photos = <String>[];
  final gpxFiles = <String>[];
  final kmlFiles = <String>[];
  final googleFiles = <String>[];
  final unsupported = <UnsupportedFile>[];

  /// Paths already classified, so a file reachable from more than one root
  /// (e.g. a file root that also lives inside a directory root) counts once.
  final _seen = <String>{};

  Future<void> classify(String path) async {
    if (!_seen.add(path)) return;
    files++;
    final ext = PhotoFormats.extOf(path);
    byExtension.update(ext, (n) => n + 1, ifAbsent: () => 1);

    if (PhotoFormats.isPhoto(path)) {
      photos.add(path);
    } else if (ext == 'gpx') {
      gpxFiles.add(path);
    } else if (ext == 'kml') {
      kmlFiles.add(path);
    } else if (ext == 'json' && await _looksLikeGoogleJson(path)) {
      googleFiles.add(path);
    } else {
      _addUnsupported(path, ext);
    }
  }

  void _addUnsupported(String path, String ext) {
    unsupportedTotal++;
    unsupportedByExtension.update(ext, (n) => n + 1, ifAbsent: () => 1);
    final category = categorizeUnsupported(ext);
    unsupportedByCategory.update(category, (n) => n + 1, ifAbsent: () => 1);
    if (unsupported.length < FolderScanResult.unsupportedPathCap) {
      unsupported.add(UnsupportedFile(path, category));
    }
  }

  ScanProgress snapshot() => ScanProgress(
    files: files,
    dirs: dirs,
    photos: photos.length,
    tracks: gpxFiles.length + kmlFiles.length,
    google: googleFiles.length,
    unsupported: unsupportedTotal,
  );

  FolderScanResult toResult() => FolderScanResult(
    files: files,
    dirs: dirs,
    byExtension: byExtension,
    photos: photos,
    gpxFiles: gpxFiles,
    kmlFiles: kmlFiles,
    googleFiles: googleFiles,
    unsupported: unsupported,
    unsupportedByExtension: unsupportedByExtension,
    unsupportedByCategory: unsupportedByCategory,
    unsupportedTotal: unsupportedTotal,
  );
}
