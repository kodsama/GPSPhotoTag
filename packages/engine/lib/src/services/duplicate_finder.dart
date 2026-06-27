import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../data/photo_formats.dart';
import '../data/ports/process_runner.dart';
import 'image_quality.dart';
import 'keep_pipeline.dart';
import 'people_signals.dart';
import 'preview_extract.dart';

/// Perceptual (difference) hashing and duplicate grouping.
///
/// The pipeline is: decode an image to grayscale luma, reduce it to a compact
/// 64-bit [dHash], then group files whose hashes are within a Hamming-distance
/// [groupDuplicates] threshold. Every function here is pure (given decoded
/// pixels / records) so the whole detection model is unit-testable without I/O.

/// The dHash grid: a 9×8 luma sample yields 8×8 = 64 horizontal comparisons,
/// one bit each, for a 64-bit hash.
const int _hashWidth = 9;
const int _hashHeight = 8;

/// Computes a 64-bit difference hash (dHash) from a [_hashWidth]×[_hashHeight]
/// grid of grayscale luma samples.
///
/// [luma] must hold exactly `width * height` values in row-major order, each a
/// brightness 0–255. For every row, adjacent pixels are compared: a bit is set
/// when the left pixel is brighter than its right neighbour. Bits are packed
/// most-significant-first in row-major order, giving a hash that is stable under
/// small changes (compression, minor edits) but differs as content shifts.
int dHashFromLuma(
  List<int> luma, {
  int width = _hashWidth,
  int height = _hashHeight,
}) {
  if (luma.length != width * height) {
    throw ArgumentError(
      'luma length ${luma.length} != $width*$height (${width * height})',
    );
  }
  var hash = 0;
  for (var y = 0; y < height; y++) {
    final rowStart = y * width;
    for (var x = 0; x < width - 1; x++) {
      hash <<= 1;
      if (luma[rowStart + x] > luma[rowStart + x + 1]) hash |= 1;
    }
  }
  return hash;
}

/// Computes the dHash of a decoded [image] by downscaling it to
/// [_hashWidth]×[_hashHeight] grayscale and delegating to [dHashFromLuma].
int dHash(img.Image image) {
  final small = img.copyResize(
    image,
    width: _hashWidth,
    height: _hashHeight,
    interpolation: img.Interpolation.average,
  );
  final luma = <int>[];
  for (var y = 0; y < _hashHeight; y++) {
    for (var x = 0; x < _hashWidth; x++) {
      luma.add(img.getLuminance(small.getPixel(x, y)).round());
    }
  }
  return dHashFromLuma(luma);
}

/// The Hamming distance between two 64-bit hashes: the number of differing bits
/// (popcount of `a XOR b`). 0 means identical; larger means more different.
int hamming(int a, int b) {
  var x = a ^ b;
  var count = 0;
  while (x != 0) {
    // Clearing the lowest set bit each step counts exactly the set bits.
    x &= x - 1;
    count++;
  }
  return count;
}

/// Decodes [bytes] for [path] into a dHash, or null when the bytes cannot be
/// decoded (corrupt, unsupported, or empty). Never throws.
///
/// [bytes] should be the file's own bytes for natively-decodable formats
/// (jpg/png/webp/gif/bmp) or the embedded-preview JPEG bytes for RAW/HEIC. The
/// extension is not consulted: any decodable image bytes hash successfully.
int? hashImageBytes(String path, Uint8List bytes) {
  final decoded = _decode(bytes);
  return decoded == null ? null : dHash(decoded);
}

/// Decodes [bytes] to an image, or null when undecodable/empty. Never throws.
img.Image? _decode(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    return img.decodeImage(bytes);
  } on Object {
    // package:image can throw on malformed input; treat as undecodable.
    return null;
  }
}

/// A hashed file ready for grouping: its [path], perceptual [hash], pixel
/// dimensions, on-disk [fileSize], [basename], and whether it [isRaw].
///
/// Plain data so [groupDuplicates] is pure and isolate/CLI portable.
class HashedFile {
  /// Creates a hashed-file record.
  const HashedFile({
    required this.path,
    required this.hash,
    required this.width,
    required this.height,
    required this.fileSize,
    required this.basename,
    required this.isRaw,
    this.quality = ImageQuality.zero,
    this.peopleScore = 0,
  });

  /// The file path.
  final String path;

  /// The 64-bit perceptual hash.
  final int hash;

  /// Pixel width (0 when unknown).
  final int width;

  /// Pixel height (0 when unknown).
  final int height;

  /// On-disk size in bytes (0 when unknown).
  final int fileSize;

  /// Lower-cased basename without extension (the RAW-companion key).
  final String basename;

  /// Whether this is a RAW container.
  final bool isRaw;

  /// Composite + per-component quality scored from the decoded ~160 px
  /// thumbnail (see [qualityScore]). Defaults to [ImageQuality.zero] for
  /// records built without pixels (most tests).
  final ImageQuality quality;

  /// People/pet likelihood in 0..1 read from metadata (face regions, person
  /// names, subject/keyword hints) via [peopleScoreFromTags]; 0 when nothing in
  /// the metadata suggests people or pets. Drives the `people` keep-rule.
  final double peopleScore;

  /// Resolution (pixel area) used to pick the best of a group.
  int get resolution => width * height;

  /// JSON view of the record (dimensions, size, RAW-ness, quality, and the
  /// people/pet score).
  Map<String, Object> toJson() => {
    'path': path,
    'hash': hash,
    'width': width,
    'height': height,
    'fileSize': fileSize,
    'basename': basename,
    'isRaw': isRaw,
    'quality': quality.toJson(),
    'peopleScore': peopleScore,
  };
}

/// A detected duplicate group: a single [best] file to keep and the
/// [duplicates] that look like it.
class DuplicateGroup {
  /// Creates a group keeping [best] over [duplicates].
  const DuplicateGroup({required this.best, required this.duplicates});

  /// The member to keep, chosen by the keep-rule cascade ([chooseKeeper]).
  final HashedFile best;

  /// The other members that match [best] within the threshold.
  final List<HashedFile> duplicates;

  /// Total members in the group ([best] + [duplicates]).
  int get size => duplicates.length + 1;
}

/// Whether [a] and [b] are RAW companions: same basename but different RAW-ness
/// (e.g. `DSCF1.RAF` + `DSCF1.JPG`). Such pairs are partners, never duplicates,
/// even when their preview hashes match.
bool _areCompanions(HashedFile a, HashedFile b) =>
    a.basename == b.basename && a.isRaw != b.isRaw;

/// Groups [records] whose perceptual hashes are within [threshold] Hamming
/// distance into [DuplicateGroup]s. Pure (no I/O).
///
/// - `threshold` is the "similarity level": 0 means only bit-identical hashes
///   group together; larger values group looser near-matches.
/// - **RAW-companion exclusion**: two files sharing a basename but differing in
///   RAW-ness (a RAW + its JPG/HEIC sibling) are never placed in the same group,
///   even if their preview hashes match — they are partners, not duplicates.
/// - Each group's [DuplicateGroup.best] is chosen by [chooseKeeper] running the
///   given [pipeline] (default [KeepPipeline.standard]); the rest become its
///   duplicates.
/// - Singletons are dropped: a group needs at least two members.
///
/// Grouping is greedy single-linkage by seed: each not-yet-grouped record seeds
/// a group and pulls in every other ungrouped record within [threshold] (minus
/// companions). This is order-stable because [records] order is preserved.
List<DuplicateGroup> groupDuplicates(
  List<HashedFile> records, {
  required int threshold,
  KeepPipeline pipeline = KeepPipeline.standard,
}) {
  final used = List<bool>.filled(records.length, false);
  final groups = <DuplicateGroup>[];

  for (var i = 0; i < records.length; i++) {
    if (used[i]) continue;
    final seed = records[i];
    final members = <HashedFile>[seed];
    used[i] = true;
    for (var j = i + 1; j < records.length; j++) {
      if (used[j]) continue;
      final other = records[j];
      if (_areCompanions(seed, other)) continue;
      if (hamming(seed.hash, other.hash) > threshold) continue;
      // A candidate must also not be a companion of any member already pulled
      // in, so a JPG never joins a group seeded by a near-twin of its own RAW.
      if (members.any((m) => _areCompanions(m, other))) continue;
      members.add(other);
      used[j] = true;
    }
    if (members.length < 2) continue;
    final best = chooseKeeper(members, pipeline);
    final duplicates = [
      for (final m in members)
        if (!identical(m, best)) m,
    ];
    groups.add(DuplicateGroup(best: best, duplicates: duplicates));
  }
  return groups;
}

/// The lower-cased basename without extension of [path] — the RAW-companion key
/// used by [HashedFile.basename]. Reuses the engine's extension stripping.
String basenameKey(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash < 0 ? path : path.substring(slash + 1);
  final ext = PhotoFormats.extOf(base);
  if (ext.isEmpty) return base.toLowerCase();
  return base.substring(0, base.length - ext.length - 1).toLowerCase();
}

/// Hashes a single image [path] into a [HashedFile], or null when it has no
/// decodable pixels (so callers can `.whereType` non-null). Never throws.
///
/// Natively-decodable formats (jpg/png/webp/gif/bmp) are decoded from their own
/// bytes. RAW/HEIC are decoded from the embedded JPEG preview extracted via
/// [extractPreview] (using the injected [runner] + [cacheDir]); a RAW/HEIC with
/// no usable embedded image yields null. Pixel dimensions come from the decoded
/// image; [HashedFile.fileSize] is the source file's on-disk size.
Future<HashedFile?> hashFile(
  String path, {
  required ProcessRunner runner,
  required String cacheDir,
}) async {
  final isRaw = PhotoFormats.isRaw(path);
  final ext = PhotoFormats.extOf(path);
  final needsPreview = isRaw || PhotoFormats.heic.contains(ext);

  Uint8List? bytes;
  try {
    if (needsPreview) {
      final preview = await extractPreview(
        path,
        cacheDir: cacheDir,
        size: PreviewSize.full,
        runner: runner,
      );
      if (preview == null) return null;
      bytes = await File(preview).readAsBytes();
    } else {
      bytes = await File(path).readAsBytes();
    }
  } on Object {
    return null; // unreadable file / failed extraction → skip
  }

  final decoded = _decode(bytes);
  if (decoded == null) return null;

  return HashedFile(
    path: path,
    hash: dHash(decoded),
    width: decoded.width,
    height: decoded.height,
    // The source file exists (we just read it / extracted its preview), so the
    // length read is safe.
    fileSize: File(path).lengthSync(),
    basename: basenameKey(path),
    isRaw: isRaw,
    // Quality is scored from the same decoded thumbnail used for the hash.
    quality: qualityScore(decoded),
  );
}

/// The exiftool args that extract one embedded image tag for EVERY source in
/// [paths] in a single process: `-b -m -W <tmpDir>/%f_%t.%s -<tag> PATHS…`.
///
/// `-b` writes the binary image to disk (not stdout); `-m` ignores minor
/// warnings so a source lacking [tag] never fails the batch; `-W %f_%t.%s`
/// names each output `{basename}_{tag}.{ext}` under [tmpDir]. One exiftool spawn
/// covers the whole chunk instead of one spawn per file.
List<String> buildBatchExtractArgs(
  List<String> paths,
  String tmpDir,
  String tag,
) => ['-b', '-m', '-W', '$tmpDir/%f_%t.%s', '-$tag', ...paths];

/// The exiftool args that read pixel dimensions AND the people/pet signal tags
/// for EVERY source in [paths] in one process, mirroring [readImageMeta]'s fast
/// batched JSON read.
///
/// `-fast2` skips MakerNotes/trailer (much faster on files with big trailers);
/// `-json -n` emit numeric width/height keyed by `SourceFile`. The same call
/// also requests [kPeopleSignalTags] (face regions, person names, subject /
/// keyword hints) so the Tier-1 `people` score costs no extra exiftool spawn.
List<String> buildBatchDimensionArgs(List<String> paths) => [
  '-fast2',
  '-json',
  '-n',
  '-ImageWidth',
  '-ImageHeight',
  for (final tag in kPeopleSignalTags) '-$tag',
  ...paths,
];

/// The name exiftool writes for [source] + [tag] under `-W %f_%t.%s`:
/// `{basename-without-ext}_{tag}.jpg` (embedded previews are JPEG).
String _batchOutputName(String source, String tag) =>
    '${p.basenameWithoutExtension(source)}_$tag.jpg';

/// Per-source metadata read from the batched JSON: original pixel dimensions
/// plus the Tier-1 [peopleScore].
typedef _Meta = ({int width, int height, double peopleScore});

/// Batch-hashes a whole [paths] slice into [HashedFile]s, minimising exiftool
/// spawns: a fixed number of extractions for the entire slice (not per file).
///
/// The fast path decodes a *small embedded thumbnail* (≈160 px) rather than the
/// multi-MP source, which is orders of magnitude cheaper:
/// 1. One `exiftool -ThumbnailImage` over every path writes each file's small
///    embedded thumbnail into a temp dir under [tmpDir] ([buildBatchExtractArgs]).
/// 2. One `exiftool -PreviewImage` over ONLY the paths that produced no
///    thumbnail (RAW/HEIC, thumb-less screenshots) writes their larger preview.
/// 3. One `exiftool -fast2 -json` reads original pixel dimensions for the whole
///    slice ([buildBatchDimensionArgs]) — no full-resolution decode.
/// 4. Each path is hashed from its extracted thumbnail/preview; a path with
///    neither falls back to decoding the source bytes directly (rare).
///
/// So N files cost 3 exiftool spawns total instead of N. Width/height come from
/// the batched JSON (falling back to the decoded image's own size only when JSON
/// lacks them); [HashedFile.fileSize] is the source's on-disk length.
/// Unreadable/undecodable files are skipped (never throw). [onFileDone] fires
/// once per input path (hashed or skipped) so a worker can tick progress.
Future<List<HashedFile>> hashFilesBatch(
  List<String> paths, {
  required ProcessRunner runner,
  required String tmpDir,
  void Function()? onFileDone,
}) async {
  if (paths.isEmpty) return const [];
  await Directory(tmpDir).create(recursive: true);
  final dir = await Directory(tmpDir).createTemp('hashbatch_');
  try {
    // Pass 1: the small embedded thumbnail for every path, in one spawn.
    await _safeRun(
      runner,
      buildBatchExtractArgs(paths, dir.path, 'ThumbnailImage'),
    );
    final thumbs = _collectOutputs(paths, dir.path, 'ThumbnailImage');

    // Pass 2: the larger preview, but ONLY for paths with no thumbnail.
    final noThumb = [
      for (final path in paths)
        if (!thumbs.containsKey(path)) path,
    ];
    var previews = const <String, String>{};
    if (noThumb.isNotEmpty) {
      await _safeRun(
        runner,
        buildBatchExtractArgs(noThumb, dir.path, 'PreviewImage'),
      );
      previews = _collectOutputs(noThumb, dir.path, 'PreviewImage');
    }

    // One batched read of original dimensions + people signals for the slice.
    final meta = await _readBatchMeta(runner, paths);

    final results = <HashedFile>[];
    for (final path in paths) {
      final extracted = thumbs[path] ?? previews[path];
      final hashed = _hashFromExtract(path, extracted, meta[path]);
      if (hashed != null) results.add(hashed);
      onFileDone?.call();
    }
    return results;
  } finally {
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Runs [args] through [runner], swallowing a launch failure so a single bad
/// chunk never aborts the batch (callers treat "no output" as "no thumbnail").
Future<void> _safeRun(ProcessRunner runner, List<String> args) async {
  try {
    await runner.run('exiftool', args);
  } on Object {
    // exiftool missing / failed to launch → no files written; handled by the
    // fallback decode of the source.
  }
}

/// Maps each source in [paths] to the on-disk extract exiftool wrote for [tag]
/// under [dir] (`{basename}_{tag}.jpg`), keeping only non-empty files. Sources
/// that produced nothing are simply absent from the map.
Map<String, String> _collectOutputs(
  List<String> paths,
  String dir,
  String tag,
) {
  final out = <String, String>{};
  for (final path in paths) {
    final candidate = p.join(dir, _batchOutputName(path, tag));
    final file = File(candidate);
    if (file.existsSync() && file.lengthSync() > 0) out[path] = candidate;
  }
  return out;
}

/// Reads original pixel dimensions and the Tier-1 people score for [paths] in
/// one batched exiftool JSON call, keyed by source path. Tolerant: a failed
/// call or a missing entry just leaves a path absent (its [HashedFile] then
/// falls back to the decoded size and a zero people score). Within an entry,
/// missing width/height are recorded as 0 (the [_hashFromExtract] sentinel for
/// "use the decoded size") so a present people score is never dropped just
/// because dimensions were absent.
Future<Map<String, _Meta>> _readBatchMeta(
  ProcessRunner runner,
  List<String> paths,
) async {
  final ProcResult result;
  try {
    result = await runner.run('exiftool', buildBatchDimensionArgs(paths));
  } on Object {
    return const {};
  }
  final meta = <String, _Meta>{};
  final decoded = _tryDecodeJsonList(result.stdout);
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final source = entry['SourceFile'];
    if (source is! String) continue;
    meta[source] = (
      width: _asInt(entry['ImageWidth']) ?? 0,
      height: _asInt(entry['ImageHeight']) ?? 0,
      peopleScore: peopleScoreFromTags(entry),
    );
  }
  return meta;
}

/// Builds a [HashedFile] for [path] from its [extracted] thumbnail/preview (or,
/// when null, by decoding the source itself — the slow fallback). Returns null
/// when nothing decodes. Dimensions prefer the batched [meta] (a width/height of
/// 0 means "unknown" → use the decoded image's own size); the Tier-1 people
/// score comes from the same [meta]. Never throws.
HashedFile? _hashFromExtract(String path, String? extracted, _Meta? meta) {
  final Uint8List bytes;
  try {
    bytes = File(extracted ?? path).readAsBytesSync();
  } on Object {
    return null; // unreadable
  }
  final decoded = _decode(bytes);
  if (decoded == null) return null;

  final int fileSize;
  try {
    fileSize = File(path).lengthSync();
  } on Object {
    return null; // source vanished between extract and hash
  }

  final w = meta?.width ?? 0;
  final h = meta?.height ?? 0;
  return HashedFile(
    path: path,
    hash: dHash(decoded),
    width: w > 0 ? w : decoded.width,
    height: h > 0 ? h : decoded.height,
    fileSize: fileSize,
    basename: basenameKey(path),
    isRaw: PhotoFormats.isRaw(path),
    // Reuse the already-decoded thumbnail to score quality (no re-decode).
    quality: qualityScore(decoded),
    peopleScore: meta?.peopleScore ?? 0,
  );
}

List<dynamic> _tryDecodeJsonList(String text) {
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
