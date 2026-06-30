import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../data/exif/exif_utils.dart';
import '../data/ports/process_runner.dart';
import '../data/sources/google_source.dart';
import '../data/sources/gpx_source.dart';
import '../domain/timed_point.dart';

/// Per-file metadata shown in the drill-down dialog.
///
/// Carries just enough to render an informative row: whether the file has GPS,
/// image [width]/[height] and capture [date], or — for a GPS source file — its
/// [pointCount] and the [spanStart]–[spanEnd] of its points. Every field beyond
/// [path] is optional because metadata streams in progressively and some files
/// legitimately lack a given field.
@immutable
class FileMeta {
  /// Creates a metadata record for [path].
  const FileMeta({
    required this.path,
    this.hasGps = false,
    this.latitude,
    this.longitude,
    this.width,
    this.height,
    this.date,
    this.pointCount,
    this.spanStart,
    this.spanEnd,
  });

  /// The file this metadata describes.
  final String path;

  /// Whether the file carries GPS coordinates (image) or any points (source).
  final bool hasGps;

  /// Image GPS latitude in signed decimal degrees, when present.
  final double? latitude;

  /// Image GPS longitude in signed decimal degrees, when present.
  final double? longitude;

  /// Image pixel width, when known.
  final int? width;

  /// Image pixel height, when known.
  final int? height;

  /// Image capture date (DateTimeOriginal || CreateDate), parsed naive.
  final DateTime? date;

  /// Number of parsed points, for a GPS source file.
  final int? pointCount;

  /// Earliest point time, for a GPS source file.
  final DateTime? spanStart;

  /// Latest point time, for a GPS source file.
  final DateTime? spanEnd;

  /// JSON form (for crossing isolate/CLI boundaries).
  Map<String, Object?> toJson() => {
    'path': path,
    'hasGps': hasGps,
    'latitude': latitude,
    'longitude': longitude,
    'width': width,
    'height': height,
    'date': date?.toIso8601String(),
    'pointCount': pointCount,
    'spanStart': spanStart?.toIso8601String(),
    'spanEnd': spanEnd?.toIso8601String(),
  };
}

/// Batch-reads image metadata for [paths] via exiftool, yielding progressively.
///
/// Runs exiftool once per [chunk] of paths through the injected [runner]:
/// `exiftool -json -n -ImageWidth -ImageHeight -DateTimeOriginal -CreateDate
/// -GPSLatitude -GPSLongitude PATHS`, parses the JSON array, and yields one
/// [FileMeta] per path in request order. `hasGps` is true (and
/// [FileMeta.latitude]/[FileMeta.longitude] populated, numeric via `-n`) only
/// when BOTH coordinates are present; the date comes from `DateTimeOriginal`
/// falling back to `CreateDate`, parsed as a naive [DateTime]. Missing fields
/// are tolerated; a path exiftool omits entirely still yields a bare [FileMeta].
Stream<FileMeta> readImageMeta(
  List<String> paths, {
  required ProcessRunner runner,
  int chunk = 64,
}) async* {
  for (var i = 0; i < paths.length; i += chunk) {
    final end = (i + chunk < paths.length) ? i + chunk : paths.length;
    final batch = paths.sublist(i, end);
    final result = await runner.run('exiftool', [
      // -fast2 skips MakerNotes and the trailer — without it, files with a
      // large embedded trailer (e.g. Pixel Motion Photos *.MP.jpg) make
      // exiftool scan the whole multi-MB file, ~30x slower.
      '-fast2',
      '-json',
      '-n',
      '-ImageWidth',
      '-ImageHeight',
      '-DateTimeOriginal',
      '-CreateDate',
      '-GPSLatitude',
      '-GPSLongitude',
      ...batch,
    ]);

    final byPath = <String, Map<String, Object?>>{};
    final decoded = _tryDecodeList(result.stdout);
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final source = entry['SourceFile'];
      if (source is String) byPath[source] = entry.cast<String, Object?>();
    }

    for (final path in batch) {
      yield _metaFrom(path, byPath[path]);
    }
  }
}

FileMeta _metaFrom(String path, Map<String, Object?>? fields) {
  if (fields == null) return FileMeta(path: path);
  final lat = _asDouble(fields['GPSLatitude']);
  final lon = _asDouble(fields['GPSLongitude']);
  final hasGps = lat != null && lon != null;
  return FileMeta(
    path: path,
    hasGps: hasGps,
    latitude: hasGps ? lat : null,
    longitude: hasGps ? lon : null,
    width: _asInt(fields['ImageWidth']),
    height: _asInt(fields['ImageHeight']),
    date: parseExifDateTimeNaive(
      fields['DateTimeOriginal'] ?? fields['CreateDate'],
    ),
  );
}

/// Reads a GPS source file ([path]) into a [FileMeta] with point count + span.
///
/// Dispatches by extension: `.gpx` via [parseGpx], `.kml` via [parseGoogleKml],
/// `.json` via [parseGoogleAuto]. Returns `pointCount`, `spanStart`/`spanEnd`
/// (min/max point time) and `hasGps = true` whenever at least one point parses.
/// Unreadable or malformed files yield a bare [FileMeta] (zero points).
FileMeta gpsFileMeta(String path) {
  final List<TimedPoint> points;
  try {
    final content = File(path).readAsStringSync();
    points = _parseFor(path, content);
  } on FileSystemException {
    return FileMeta(path: path);
  } on FormatException {
    return FileMeta(path: path);
  }
  if (points.isEmpty) {
    return FileMeta(path: path, pointCount: 0);
  }
  // parseGpx/parseGoogle* return time-sorted points, so first/last are the span.
  return FileMeta(
    path: path,
    hasGps: true,
    pointCount: points.length,
    spanStart: points.first.time,
    spanEnd: points.last.time,
  );
}

List<TimedPoint> _parseFor(String path, String content) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.gpx')) return parseGpx(content);
  if (lower.endsWith('.kml')) return parseGoogleKml(content);
  return parseGoogleAuto(content);
}

List<dynamic> _tryDecodeList(String text) {
  if (text.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? decoded : const [];
  } on FormatException {
    return const [];
  }
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final s = v.trim();
    return s.isEmpty ? null : double.tryParse(s);
  }
  return null;
}

