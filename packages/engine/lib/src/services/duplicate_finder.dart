import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../data/photo_formats.dart';
import '../data/ports/process_runner.dart';
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

  /// Resolution (pixel area) used to pick the best of a group.
  int get resolution => width * height;
}

/// A detected duplicate group: a single [best] file to keep and the
/// [duplicates] that look like it.
class DuplicateGroup {
  /// Creates a group keeping [best] over [duplicates].
  const DuplicateGroup({required this.best, required this.duplicates});

  /// The highest-quality member (highest resolution, then largest file, then
  /// path) — the one to keep.
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

/// Picks the "best" of [members]: highest resolution, then largest file size,
/// then the lexicographically smallest path (deterministic tie-break).
HashedFile _pickBest(List<HashedFile> members) {
  var best = members.first;
  for (final m in members.skip(1)) {
    if (_isBetter(m, best)) best = m;
  }
  return best;
}

bool _isBetter(HashedFile a, HashedFile b) {
  if (a.resolution != b.resolution) return a.resolution > b.resolution;
  if (a.fileSize != b.fileSize) return a.fileSize > b.fileSize;
  return a.path.compareTo(b.path) < 0;
}

/// Groups [records] whose perceptual hashes are within [threshold] Hamming
/// distance into [DuplicateGroup]s. Pure (no I/O).
///
/// - `threshold` is the "similarity level": 0 means only bit-identical hashes
///   group together; larger values group looser near-matches.
/// - **RAW-companion exclusion**: two files sharing a basename but differing in
///   RAW-ness (a RAW + its JPG/HEIC sibling) are never placed in the same group,
///   even if their preview hashes match — they are partners, not duplicates.
/// - Each group's [DuplicateGroup.best] is the highest-resolution member (ties
///   broken by larger file size, then path); the rest become its duplicates.
/// - Singletons are dropped: a group needs at least two members.
///
/// Grouping is greedy single-linkage by seed: each not-yet-grouped record seeds
/// a group and pulls in every other ungrouped record within [threshold] (minus
/// companions). This is order-stable because [records] order is preserved.
List<DuplicateGroup> groupDuplicates(
  List<HashedFile> records, {
  required int threshold,
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
    final best = _pickBest(members);
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
  );
}
