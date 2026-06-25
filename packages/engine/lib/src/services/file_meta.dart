import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

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
/// -GPSLatitude PATHS`, parses the JSON array, and yields one [FileMeta] per
/// path in request order. `hasGps` is true when `GPSLatitude` is present and
/// non-empty; the date comes from `DateTimeOriginal` falling back to
/// `CreateDate`, parsed as a naive [DateTime]. Missing fields are tolerated; a
/// path exiftool omits entirely still yields a bare [FileMeta].
Stream<FileMeta> readImageMeta(
  List<String> paths, {
  required ProcessRunner runner,
  int chunk = 300,
}) async* {
  for (var i = 0; i < paths.length; i += chunk) {
    final end = (i + chunk < paths.length) ? i + chunk : paths.length;
    final batch = paths.sublist(i, end);
    final result = await runner.run('exiftool', [
      '-json',
      '-n',
      '-ImageWidth',
      '-ImageHeight',
      '-DateTimeOriginal',
      '-CreateDate',
      '-GPSLatitude',
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
  final gps = fields['GPSLatitude'];
  final hasGps = gps != null && '$gps'.trim().isNotEmpty;
  return FileMeta(
    path: path,
    hasGps: hasGps,
    width: _asInt(fields['ImageWidth']),
    height: _asInt(fields['ImageHeight']),
    date: _parseExifDate(fields['DateTimeOriginal'] ?? fields['CreateDate']),
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

/// Parses an exiftool date string into a naive [DateTime].
///
/// exiftool emits `YYYY:MM:DD HH:MM:SS` (optionally with sub-seconds and a zone
/// suffix); we normalise the date separators and strip any timezone so the
/// result is the wall-clock capture time, matching the rest of the engine.
DateTime? _parseExifDate(Object? value) {
  if (value is! String) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  // Convert leading "YYYY:MM:DD" to "YYYY-MM-DD" without touching the time.
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})').firstMatch(text);
  if (m != null) {
    text = '${m[1]}-${m[2]}-${m[3]}${text.substring(m.end)}';
  }
  // Drop any trailing timezone designator so the time is read as naive.
  text = text.replaceFirst(RegExp(r'(Z|[+-]\d{2}:?\d{2})$'), '').trim();
  return DateTime.tryParse(text.replaceFirst(' ', 'T'));
}
