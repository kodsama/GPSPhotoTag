import 'dart:convert';

import 'package:meta/meta.dart';

import '../data/ports/process_runner.dart';

/// A curated set of camera/exposure EXIF tags for the big-preview viewer.
///
/// Holds only the human-interesting fields the info strip shows — camera
/// [make]/[model], [lens], [iso], [exposure] (shutter), [fNumber] aperture, and
/// [focalLength]. Every field is optional because most files carry only some of
/// them. Plain, Flutter-free data so it crosses the isolate/CLI boundary as JSON
/// and the parsing is unit-testable with a fake runner.
@immutable
class CuratedExif {
  /// Creates a curated-EXIF record for [path].
  const CuratedExif({
    required this.path,
    this.make,
    this.model,
    this.lens,
    this.iso,
    this.exposure,
    this.fNumber,
    this.focalLength,
  });

  /// Builds a record from a decoded exiftool entry [fields] for [path].
  factory CuratedExif.fromFields(String path, Map<String, Object?>? fields) {
    if (fields == null) return CuratedExif(path: path);
    return CuratedExif(
      path: path,
      make: _str(fields['Make']),
      model: _str(fields['Model']),
      lens: _str(fields['LensModel']),
      iso: _str(fields['ISO']),
      exposure: _str(fields['ExposureTime'] ?? fields['ShutterSpeed']),
      fNumber: _str(fields['FNumber']),
      focalLength: _str(fields['FocalLength']),
    );
  }

  /// The file this metadata describes.
  final String path;

  /// Camera manufacturer (EXIF `Make`), when present.
  final String? make;

  /// Camera model (EXIF `Model`), when present.
  final String? model;

  /// Lens model (EXIF `LensModel`), when present.
  final String? lens;

  /// ISO sensitivity (EXIF `ISO`), when present.
  final String? iso;

  /// Exposure/shutter time (EXIF `ExposureTime` || `ShutterSpeed`), e.g. `1/250`.
  final String? exposure;

  /// Aperture f-number (EXIF `FNumber`), e.g. `2.8`.
  final String? fNumber;

  /// Focal length (EXIF `FocalLength`), e.g. `35 mm`.
  final String? focalLength;

  /// Whether any curated field is populated.
  bool get isEmpty =>
      make == null &&
      model == null &&
      lens == null &&
      iso == null &&
      exposure == null &&
      fNumber == null &&
      focalLength == null;

  /// JSON form (for crossing isolate/CLI boundaries).
  Map<String, Object?> toJson() => {
    'path': path,
    'make': make,
    'model': model,
    'lens': lens,
    'iso': iso,
    'exposure': exposure,
    'fNumber': fNumber,
    'focalLength': focalLength,
  };

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}

/// Batch-reads the curated EXIF set for [paths] via exiftool, yielding one
/// [CuratedExif] per path in request order.
///
/// Runs exiftool once per [chunk]:
/// `exiftool -json -Make -Model -LensModel -ISO -ExposureTime -ShutterSpeed
/// -FNumber -FocalLength PATHS`, parses the JSON array, and yields a record per
/// requested path (a bare record for any path exiftool omits). Missing fields
/// are tolerated. Mirrors `readImageMeta`'s shape so the same isolate fan-out
/// can drive it.
Stream<CuratedExif> readCuratedExif(
  List<String> paths, {
  required ProcessRunner runner,
  int chunk = 64,
}) async* {
  for (var i = 0; i < paths.length; i += chunk) {
    final end = (i + chunk < paths.length) ? i + chunk : paths.length;
    final batch = paths.sublist(i, end);
    final result = await runner.run('exiftool', [
      '-fast2',
      '-json',
      '-Make',
      '-Model',
      '-LensModel',
      '-ISO',
      '-ExposureTime',
      '-ShutterSpeed',
      '-FNumber',
      '-FocalLength',
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
      yield CuratedExif.fromFields(path, byPath[path]);
    }
  }
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
