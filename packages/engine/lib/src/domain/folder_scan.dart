import 'package:meta/meta.dart';

/// How an unsupported (non-taggable, non-GPS) file is grouped for the UI.
///
/// The scanner buckets every file that is neither a taggable photo nor a GPS
/// source into one of these so the app can render grouped, deactivated rows
/// ("Images (N): tif, bmp …", "Videos (N): mov, mp4 …").
enum UnsupportedCategory {
  /// Image formats the engine does not tag (tif, bmp, gif, …).
  image,

  /// Video formats (mp4, mov, mkv, …).
  video,

  /// GPS/track formats the engine cannot parse (fit, tcx, kmz, …).
  gpsData,

  /// Everything else, including non-Google `.json`.
  other,
}

/// Extension → [UnsupportedCategory] for files we recognise but do not support.
///
/// Lower-case, no leading dot. Anything not listed falls into
/// [UnsupportedCategory.other].
const Map<String, UnsupportedCategory> kUnsupportedExtensions = {
  // Images we don't tag.
  'tif': UnsupportedCategory.image,
  'tiff': UnsupportedCategory.image,
  'bmp': UnsupportedCategory.image,
  'gif': UnsupportedCategory.image,
  'svg': UnsupportedCategory.image,
  'ico': UnsupportedCategory.image,
  'psd': UnsupportedCategory.image,
  'jp2': UnsupportedCategory.image,
  'avif': UnsupportedCategory.image,
  // Videos.
  'mp4': UnsupportedCategory.video,
  'mov': UnsupportedCategory.video,
  'm4v': UnsupportedCategory.video,
  'avi': UnsupportedCategory.video,
  'mkv': UnsupportedCategory.video,
  'webm': UnsupportedCategory.video,
  '3gp': UnsupportedCategory.video,
  'mts': UnsupportedCategory.video,
  'm2ts': UnsupportedCategory.video,
  'wmv': UnsupportedCategory.video,
  'flv': UnsupportedCategory.video,
  'mpg': UnsupportedCategory.video,
  'mpeg': UnsupportedCategory.video,
  // GPS data we can't parse.
  'fit': UnsupportedCategory.gpsData,
  'tcx': UnsupportedCategory.gpsData,
  'nmea': UnsupportedCategory.gpsData,
  'igc': UnsupportedCategory.gpsData,
  'loc': UnsupportedCategory.gpsData,
  'kmz': UnsupportedCategory.gpsData,
};

/// Categorises [ext] (lower-case, no dot) into an [UnsupportedCategory].
UnsupportedCategory categorizeUnsupported(String ext) =>
    kUnsupportedExtensions[ext] ?? UnsupportedCategory.other;

/// Running totals emitted while a folder scan is in flight.
///
/// A [FolderScanner] emits these (throttled) so a UI can show realtime
/// progress for a scan that may walk hundreds of thousands of files. All
/// fields are cumulative since the scan started.
@immutable
class ScanProgress {
  /// Creates a progress snapshot.
  const ScanProgress({
    this.files = 0,
    this.dirs = 0,
    this.photos = 0,
    this.tracks = 0,
    this.google = 0,
    this.unsupported = 0,
  });

  /// Total files classified so far.
  final int files;

  /// Total directories entered so far (including the roots).
  final int dirs;

  /// Files classified as taggable photos.
  final int photos;

  /// GPS track files seen (`.gpx` + `.kml`).
  final int tracks;

  /// Validated Google history candidates (`.json`) seen.
  final int google;

  /// Files that are neither photo, track, nor Google history.
  final int unsupported;

  /// JSON form for the CLI / GUI.
  Map<String, Object?> toJson() => {
    'files': files,
    'dirs': dirs,
    'photos': photos,
    'tracks': tracks,
    'google': google,
    'unsupported': unsupported,
  };
}

/// One unsupported file: its path and the category it was bucketed into.
@immutable
class UnsupportedFile {
  /// Creates an unsupported-file record.
  const UnsupportedFile(this.path, this.category);

  /// The file path.
  final String path;

  /// Which group it belongs to.
  final UnsupportedCategory category;

  /// JSON form.
  Map<String, Object?> toJson() => {'path': path, 'category': category.name};
}

/// The final result of recursively scanning one or more folders.
///
/// Counts ([files], [dirs], [byExtension], the `*Count` getters, and the
/// unsupported tallies) are **exact**. The [photos], [gpxFiles], [kmlFiles],
/// and [googleFiles] path lists are kept in full because downstream tagging
/// and source-pooling need them. The [unsupported] sample list is capped (see
/// [unsupportedPathCap]) to bound memory on huge trees — [unsupportedCount],
/// [unsupportedByCategory], and [unsupportedByExtension] stay exact even when
/// the sample list is truncated.
@immutable
class FolderScanResult {
  /// Creates a scan result.
  const FolderScanResult({
    required this.files,
    required this.dirs,
    required this.byExtension,
    required this.photos,
    required this.gpxFiles,
    required this.kmlFiles,
    required this.googleFiles,
    required this.unsupported,
    required this.unsupportedByExtension,
    required this.unsupportedByCategory,
    required int unsupportedTotal,
    // ignore: prefer_initializing_formals
  }) : _unsupportedTotal = unsupportedTotal;

  /// Maximum number of unsupported file samples retained in [unsupported].
  ///
  /// Counts stay exact past this cap; only the stored sample list is truncated.
  static const int unsupportedPathCap = 5000;

  /// Total files seen across all roots.
  final int files;

  /// Total directories entered (including the roots).
  final int dirs;

  /// File count per lower-case extension (without the dot) for every file.
  final Map<String, int> byExtension;

  /// Full list of taggable photo paths.
  final List<String> photos;

  /// Full list of `.gpx` track paths.
  final List<String> gpxFiles;

  /// Full list of `.kml` track paths (parsed via `parseGoogleKml`).
  final List<String> kmlFiles;

  /// Full list of validated Google history JSON paths.
  final List<String> googleFiles;

  /// Unsupported file samples (path + category), capped at
  /// [unsupportedPathCap].
  final List<UnsupportedFile> unsupported;

  /// Count per extension among unsupported files (exact, uncapped).
  final Map<String, int> unsupportedByExtension;

  /// Count per [UnsupportedCategory] among unsupported files (exact).
  final Map<UnsupportedCategory, int> unsupportedByCategory;

  /// Exact total of unsupported files, even when [unsupported] is truncated.
  final int _unsupportedTotal;

  /// Number of taggable photos.
  int get photoCount => photos.length;

  /// All GPS track paths (`.gpx` + `.kml`).
  List<String> get trackFiles => [...gpxFiles, ...kmlFiles];

  /// Number of `.gpx` files.
  int get gpxCount => gpxFiles.length;

  /// Number of `.kml` files.
  int get kmlCount => kmlFiles.length;

  /// Number of GPS track files (`.gpx` + `.kml`).
  int get trackCount => gpxFiles.length + kmlFiles.length;

  /// Number of validated Google history candidates.
  int get googleCount => googleFiles.length;

  /// Exact number of unsupported files (not the possibly-capped list length).
  int get unsupportedCount => _unsupportedTotal;

  /// Photo count per extension (the photo subset of [byExtension]).
  Map<String, int> get photosByFormat {
    final out = <String, int>{};
    for (final path in photos) {
      final ext = _extOf(path);
      out.update(ext, (n) => n + 1, ifAbsent: () => 1);
    }
    return out;
  }

  /// JSON form for the CLI / GUI.
  Map<String, Object?> toJson() => {
    'files': files,
    'dirs': dirs,
    'photoCount': photoCount,
    'gpxCount': gpxCount,
    'kmlCount': kmlCount,
    'trackCount': trackCount,
    'googleCount': googleCount,
    'unsupportedCount': unsupportedCount,
    'byExtension': byExtension,
    'unsupportedByExtension': unsupportedByExtension,
    'unsupportedByCategory': {
      for (final e in unsupportedByCategory.entries) e.key.name: e.value,
    },
    'photos': photos,
    'gpxFiles': gpxFiles,
    'kmlFiles': kmlFiles,
    'googleFiles': googleFiles,
    'unsupported': [for (final u in unsupported) u.toJson()],
    'unsupportedPathCapped': unsupported.length < _unsupportedTotal,
  };
}

String _extOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// A single observable event emitted during a folder scan.
///
/// Sealed so callers can `switch` exhaustively. The CLI serialises each via
/// [toJson]; the GUI routes them to a controller.
@immutable
sealed class ScanEvent {
  const ScanEvent();

  /// The `event` discriminator used in JSON output.
  String get kind;

  /// JSON form: one object per event.
  Map<String, Object?> toJson();
}

/// A throttled running-totals update.
final class ScanProgressEvent extends ScanEvent {
  /// Wraps [progress].
  const ScanProgressEvent(this.progress);

  /// The current running totals.
  final ScanProgress progress;

  @override
  String get kind => 'scanProgress';

  @override
  Map<String, Object?> toJson() => {'event': kind, ...progress.toJson()};
}

/// The scan finished; carries the full [result].
final class ScanDoneEvent extends ScanEvent {
  /// Wraps [result].
  const ScanDoneEvent(this.result);

  /// The final scan result.
  final FolderScanResult result;

  @override
  String get kind => 'scanDone';

  @override
  Map<String, Object?> toJson() => {'event': kind, ...result.toJson()};
}

/// A human-readable note emitted during a scan (e.g. an unreadable directory).
final class ScanLogEvent extends ScanEvent {
  /// Creates a log event.
  const ScanLogEvent(this.message);

  /// The message text.
  final String message;

  @override
  String get kind => 'scanLog';

  @override
  Map<String, Object?> toJson() => {'event': kind, 'message': message};
}
