import 'dart:io';

import 'package:path/path.dart' as p;

import 'photo_formats.dart';

/// Resolves user-supplied inputs (files, directories, globs) into concrete file
/// lists. Directories are walked recursively; results are de-duplicated and
/// sorted so runs are deterministic.
abstract final class Collectors {
  /// Expands [inputs] into a sorted, de-duplicated list of taggable photos.
  static List<String> photos(Iterable<String> inputs) =>
      _expand(inputs, PhotoFormats.isPhoto);

  /// Expands [inputs] into GPX files (`.gpx`).
  static List<String> gpx(Iterable<String> inputs) =>
      _expand(inputs, (path) => PhotoFormats.extOf(path) == 'gpx');

  /// Expands [inputs] into Google history files (`.json`, `.kml`).
  static List<String> googleHistory(Iterable<String> inputs) => _expand(
    inputs,
    (path) => const {'json', 'kml'}.contains(PhotoFormats.extOf(path)),
  );

  static List<String> _expand(
    Iterable<String> inputs,
    bool Function(String path) keep,
  ) {
    final out = <String>{};
    for (final raw in inputs) {
      final entity = FileSystemEntity.typeSync(raw);
      if (entity == FileSystemEntityType.directory) {
        for (final f in Directory(raw).listSync(recursive: true)) {
          if (f is File && keep(f.path)) out.add(p.absolute(f.path));
        }
      } else if (entity == FileSystemEntityType.file) {
        if (keep(raw)) out.add(p.absolute(raw));
      }
      // Non-existent paths are silently ignored here; the caller validates and
      // reports an empty result.
    }
    final list = out.toList()..sort();
    return list;
  }
}
