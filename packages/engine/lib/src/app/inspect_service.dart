import '../data/ports/process_runner.dart';
import '../services/curated_exif.dart';
import '../services/file_meta.dart';

/// Everything the comparison viewer's info strip shows about one photo:
/// dimensions, capture date and GPS from [FileMeta], camera and exposure from
/// [CuratedExif].
class PhotoInfo {
  /// Creates a combined record for [path].
  const PhotoInfo({required this.path, required this.meta, required this.exif});

  /// The file this record describes.
  final String path;

  /// Dimensions, capture date and GPS.
  final FileMeta meta;

  /// Camera, lens and exposure settings.
  final CuratedExif exif;

  /// Flat JSON form used by the CLI `inspect` command and the MCP
  /// `describe_photos` tool. The two sources are merged rather than nested so a
  /// caller reads one object per photo.
  Map<String, Object?> toJson() => {
    ...meta.toJson(),
    ...exif.toJson()..remove('path'),
  };
}

/// Reads the viewer's info strip for [paths] in one batched pass per source.
///
/// The GUI shows this when you open a photo full-screen; exposing it headlessly
/// lets an agent answer "what camera shot this, how big is it, where and when"
/// without a window. Both underlying reads batch through exiftool, so N photos
/// cost a couple of spawns rather than N.
Future<List<PhotoInfo>> inspectPhotos(
  List<String> paths, {
  required ProcessRunner runner,
}) async {
  final metas = {
    await for (final m in readImageMeta(paths, runner: runner)) m.path: m,
  };
  final exifs = {
    await for (final e in readCuratedExif(paths, runner: runner)) e.path: e,
  };
  return [
    for (final path in paths)
      PhotoInfo(
        path: path,
        meta: metas[path] ?? FileMeta(path: path),
        exif: exifs[path] ?? CuratedExif(path: path),
      ),
  ];
}
