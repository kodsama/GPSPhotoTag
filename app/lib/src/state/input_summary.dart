import 'package:gpsphototag_engine/gpsphototag_engine.dart';

/// A parsed snapshot of the chosen photo folder: counts by format, the detected
/// GPS source files, and the inclusive date span of the photos (when known).
class InputSummary {
  /// Creates a summary over the expanded [photos], [gpxFiles] and
  /// [googleFiles], with per-format [countsByFormat] and an optional date span.
  const InputSummary({
    required this.folder,
    required this.photos,
    required this.gpxFiles,
    required this.googleFiles,
    required this.countsByFormat,
    this.earliest,
    this.latest,
  });

  /// An empty summary (nothing picked yet).
  const InputSummary.empty()
    : folder = null,
      photos = const [],
      gpxFiles = const [],
      googleFiles = const [],
      countsByFormat = const {},
      earliest = null,
      latest = null;

  /// The picked folder, or null when nothing is selected.
  final String? folder;

  /// All taggable photo paths found under the folder, sorted.
  final List<String> photos;

  /// GPX track files found under the folder.
  final List<String> gpxFiles;

  /// Google location-history files found under the folder.
  final List<String> googleFiles;

  /// Photo count per lower-case extension (e.g. `{jpg: 12, raf: 3}`).
  final Map<String, int> countsByFormat;

  /// Earliest photo capture time, if any timestamps were read.
  final DateTime? earliest;

  /// Latest photo capture time, if any timestamps were read.
  final DateTime? latest;

  /// Total taggable photos found.
  int get photoCount => photos.length;

  /// Whether any photo was found.
  bool get hasPhotos => photos.isNotEmpty;

  /// Builds a summary from already-expanded path lists, deriving format counts.
  factory InputSummary.from({
    required String folder,
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> googleFiles,
    DateTime? earliest,
    DateTime? latest,
  }) {
    final counts = <String, int>{};
    for (final path in photos) {
      final ext = PhotoFormats.extOf(path);
      counts.update(ext, (n) => n + 1, ifAbsent: () => 1);
    }
    return InputSummary(
      folder: folder,
      photos: photos,
      gpxFiles: gpxFiles,
      googleFiles: googleFiles,
      countsByFormat: counts,
      earliest: earliest,
      latest: latest,
    );
  }
}
