import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/ports/process_runner.dart';

/// Which embedded JPEG to pull out of a RAW/HEIC file.
///
/// [thumb] wants a small, fast-to-load image for a list miniature; [full] wants
/// the largest available preview for a fullscreen view. The two differ only in
/// which embedded tag is preferred (see [_tagsFor]) and which produced file is
/// picked when several are written (see [_pickOutput]).
enum PreviewSize {
  /// A small embedded thumbnail (list/miniature use).
  thumb,

  /// The largest embedded preview (fullscreen use).
  full,
}

/// The exiftool tags that can hold an embedded JPEG, in selection-priority order
/// per [PreviewSize].
///
/// - [PreviewSize.full] prefers the full-size `PreviewImage`, then `JpgFromRaw`
///   (present on Canon/Nikon), then the small `ThumbnailImage`.
/// - [PreviewSize.thumb] prefers the small `ThumbnailImage`, then `PreviewImage`.
List<String> _tagsFor(PreviewSize size) => switch (size) {
  PreviewSize.full => const ['PreviewImage', 'JpgFromRaw', 'ThumbnailImage'],
  PreviewSize.thumb => const ['ThumbnailImage', 'PreviewImage'],
};

/// Builds the exiftool arguments that write every candidate embedded image of
/// [source] into [outDir], one file per tag.
///
/// Uses `-b -W <outDir>/%f_%t.%s` so exiftool writes the *binary* image to disk
/// (named like `DSCF0637_PreviewImage.jpg`) instead of to stdout — the engine's
/// [ProcessRunner] returns stdout as a String, which would corrupt binary. `-m`
/// ignores minor warnings so a missing tag never fails the whole call.
List<String> buildExtractArgs(String source, String outDir, PreviewSize size) =>
    [
      '-b',
      '-m',
      '-W',
      '$outDir/%f_%t.%s',
      for (final tag in _tagsFor(size)) '-$tag',
      source,
    ];

/// Picks the best produced file for [size] from [candidates] (paths exiftool
/// actually wrote), or null when nothing was produced.
///
/// "full" picks the largest file on disk (the full-size preview dwarfs the
/// thumbnail); "thumb" honours the tag preference order, falling back to the
/// largest if no preferred tag was written. Selection is pure given the file
/// sizes, so it is unit-testable with a size lookup.
String? _pickOutput(
  String source,
  PreviewSize size,
  List<String> candidates,
  int Function(String) sizeOf,
) {
  final existing = [
    for (final c in candidates)
      if (sizeOf(c) > 0) c,
  ];
  if (existing.isEmpty) return null;

  if (size == PreviewSize.full) {
    // Largest wins: PreviewImage/JpgFromRaw are multi-MB, ThumbnailImage is KB.
    existing.sort((a, b) => sizeOf(b).compareTo(sizeOf(a)));
    return existing.first;
  }

  // thumb: prefer the smallest non-trivial image (the dedicated thumbnail),
  // which keeps list miniatures fast to decode.
  existing.sort((a, b) => sizeOf(a).compareTo(sizeOf(b)));
  return existing.first;
}

/// The on-disk file name exiftool writes for [source] + [tag] under `-W
/// %f_%t.%s`: `{basename-without-ext}_{tag}.{ext}`. The extension is `jpg`
/// because every embedded preview we request is JPEG.
String _outputNameFor(String source, String tag) {
  final stem = p.basenameWithoutExtension(source);
  return '${stem}_$tag.jpg';
}

/// The stable cache path for [source] at [size] under [cacheDir].
///
/// Keyed by the source's absolute path + size so two files with the same
/// basename in different folders never collide. Freshness is checked against the
/// source mtime by [extractPreview]; this only computes the location.
String cachePathFor(String source, String cacheDir, PreviewSize size) {
  final stem = p.basenameWithoutExtension(source);
  final hash = source.hashCode.toUnsigned(32).toRadixString(16);
  return p.join(cacheDir, '${stem}_${hash}_${size.name}.jpg');
}

/// Extracts an embedded JPEG preview of [source] into [cacheDir], returning the
/// cached file path (or null when [source] carries no usable embedded image).
///
/// Caches by source path + mtime: if the cached file already exists and is newer
/// than [source], re-extraction is skipped and the cached path is returned
/// immediately. Otherwise exiftool writes every candidate embedded image into a
/// temp subdirectory (via [buildExtractArgs]), the best one is selected for
/// [size] (via [_pickOutput]), copied to the stable cache path, and the temp
/// files are cleaned up.
///
/// [runner] is injected so the arg-building + selection logic is testable
/// without a real exiftool.
Future<String?> extractPreview(
  String source, {
  required String cacheDir,
  required PreviewSize size,
  required ProcessRunner runner,
}) async {
  final src = File(source);
  if (!src.existsSync()) return null;

  await Directory(cacheDir).create(recursive: true);
  final cachePath = cachePathFor(source, cacheDir, size);
  final cached = File(cachePath);

  // Cache hit: the extracted JPEG exists and is not older than the source.
  // ("Not older" rather than strictly newer so an extract written in the same
  // instant as the source still counts as fresh.)
  if (cached.existsSync() &&
      !cached.lastModifiedSync().isBefore(src.lastModifiedSync())) {
    return cachePath;
  }

  // Extract into a private temp dir so partial output never pollutes the cache.
  final tmp = await Directory(cacheDir).createTemp('extract_${size.name}_');
  try {
    await runner.run('exiftool', buildExtractArgs(source, tmp.path, size));

    final candidates = [
      for (final tag in _tagsFor(size))
        p.join(tmp.path, _outputNameFor(source, tag)),
    ];
    final picked = _pickOutput(
      source,
      size,
      candidates,
      (path) => File(path).existsSync() ? File(path).lengthSync() : 0,
    );
    if (picked == null) return null;

    await File(picked).copy(cachePath);
    return cachePath;
  } finally {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }
}
