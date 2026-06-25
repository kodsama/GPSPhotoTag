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

/// Recursively scans folders, classifying every file and streaming progress.
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

  /// Scans [roots] recursively and streams classification events.
  ///
  /// Emits throttled [ScanProgressEvent]s while walking, a [ScanLogEvent] for
  /// each unreadable directory (skipped, never fatal), and a final
  /// [ScanDoneEvent] carrying the complete [FolderScanResult].
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
    final queue = <String>[...roots];
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

  Future<void> classify(String path) async {
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
