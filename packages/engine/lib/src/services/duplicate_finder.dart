import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../data/photo_formats.dart';
import '../data/ports/process_runner.dart';
import 'image_quality.dart';
import 'keep_pipeline.dart';
import 'people_detector.dart';
import 'people_signals.dart';
import 'preview_extract.dart';

/// Perceptual (DCT) hashing, a colour signature, and duplicate grouping.
///
/// The pipeline is: decode an image to a small thumbnail, derive two compact
/// per-image signatures from it — a 256-bit DCT [pHash] (structure) and a coarse
/// HSV [colorSignature] (palette) — then group files whose combined
/// [imageSimilarity] is at least the [groupDuplicates] cutoff. Every function
/// here is pure (given decoded pixels / records) so the whole detection model is
/// unit-testable without I/O.
///
/// The 256-bit pHash gives a meaningful full-range structural distance (unlike a
/// 64-bit dHash, where any distance beyond ~15 bits stops being informative), and
/// the colour signature catches palette differences a luma-only hash misses.

/// The pHash grid: the thumbnail is reduced to [_dctSize]×[_dctSize] grayscale,
/// a 2D DCT is taken, and the top-left [_lowFreqSize]×[_lowFreqSize] low-frequency
/// block (minus the DC term) is thresholded against its median into 256 bits.
const int _dctSize = 32;
const int _lowFreqSize = 16;

/// The number of bits in a [pHash]: the 16×16 low-frequency block = 256 bits,
/// stored as 4×64-bit words.
const int pHashBits = _lowFreqSize * _lowFreqSize;

/// Precomputed DCT-II basis cosines: `_dctCos[k][n] = cos(π·(2n+1)·k / 2N)` for
/// an N=[_dctSize] transform, so [dct1d]/[dct2d] avoid recomputing them per call.
final List<List<double>> _dctCos = _buildDctCos(_dctSize);

List<List<double>> _buildDctCos(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        math.cos(((2 * i + 1) * k * math.pi) / (2 * n)),
    ],
];

/// The 1-D DCT-II of [input] (length [_dctSize]) using the precomputed basis.
/// Pure; used row- and column-wise by [dct2d].
List<double> dct1d(List<double> input) {
  final n = input.length;
  final out = List<double>.filled(n, 0);
  for (var k = 0; k < n; k++) {
    final cosK = _dctCos[k];
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += input[i] * cosK[i];
    }
    out[k] = sum;
  }
  return out;
}

/// The separable 2-D DCT-II of a [_dctSize]×[_dctSize] grayscale [plane]
/// (row-major). Applies [dct1d] to every row then every column. Pure.
List<double> dct2d(List<double> plane) {
  if (plane.length != _dctSize * _dctSize) {
    throw ArgumentError(
      'plane length ${plane.length} != $_dctSize*$_dctSize '
      '(${_dctSize * _dctSize})',
    );
  }
  final rows = List<double>.filled(_dctSize * _dctSize, 0);
  final row = List<double>.filled(_dctSize, 0);
  for (var y = 0; y < _dctSize; y++) {
    for (var x = 0; x < _dctSize; x++) {
      row[x] = plane[y * _dctSize + x];
    }
    final t = dct1d(row);
    for (var x = 0; x < _dctSize; x++) {
      rows[y * _dctSize + x] = t[x];
    }
  }
  final out = List<double>.filled(_dctSize * _dctSize, 0);
  final col = List<double>.filled(_dctSize, 0);
  for (var x = 0; x < _dctSize; x++) {
    for (var y = 0; y < _dctSize; y++) {
      col[y] = rows[y * _dctSize + x];
    }
    final t = dct1d(col);
    for (var y = 0; y < _dctSize; y++) {
      out[y * _dctSize + x] = t[y];
    }
  }
  return out;
}

/// Computes the 256-bit DCT perceptual hash from a [_dctSize]×[_dctSize] grid of
/// grayscale luma samples, returned as 4×64-bit words (most-significant bit of
/// the block first).
///
/// [luma] must hold exactly [_dctSize]² values in row-major order. The 2-D DCT
/// is taken, the top-left [_lowFreqSize]×[_lowFreqSize] low-frequency coefficients
/// (excluding the [0,0] DC term, which only encodes overall brightness) are
/// thresholded against their median: a bit is set when the coefficient is above
/// the median. This is stable under compression, resize, and brightness/gamma
/// shifts (the DC term is dropped) but changes as structure changes.
List<int> pHashFromLuma(List<double> luma) {
  final coeffs = dct2d(luma);
  // Collect the low-frequency block, excluding DC, to find its median.
  final block = <double>[];
  for (var y = 0; y < _lowFreqSize; y++) {
    for (var x = 0; x < _lowFreqSize; x++) {
      if (x == 0 && y == 0) continue; // DC term
      block.add(coeffs[y * _dctSize + x]);
    }
  }
  final sorted = List<double>.of(block)..sort();
  // Median of the 255 non-DC coefficients.
  final median = sorted[sorted.length ~/ 2];

  final words = List<int>.filled(4, 0);
  var bit = 0;
  for (var y = 0; y < _lowFreqSize; y++) {
    for (var x = 0; x < _lowFreqSize; x++) {
      // The DC bit (position 0) is always 0: DC is excluded from the signal.
      final on = (x == 0 && y == 0) ? false : coeffs[y * _dctSize + x] > median;
      if (on) words[bit ~/ 64] |= 1 << (63 - (bit % 64));
      bit++;
    }
  }
  return words;
}

/// Computes the 256-bit [pHashFromLuma] of a decoded [image] by downscaling it to
/// [_dctSize]×[_dctSize] grayscale.
List<int> pHash(img.Image image) {
  final small = img.copyResize(
    image,
    width: _dctSize,
    height: _dctSize,
    interpolation: img.Interpolation.average,
  );
  final luma = List<double>.filled(_dctSize * _dctSize, 0);
  var i = 0;
  for (var y = 0; y < _dctSize; y++) {
    for (var x = 0; x < _dctSize; x++) {
      luma[i++] = img.getLuminance(small.getPixel(x, y)).toDouble();
    }
  }
  return pHashFromLuma(luma);
}

/// The Hamming distance between two [pHash]es (4×64-bit words): the number of
/// differing bits across all 256 positions. 0 means identical structure.
int hammingPHash(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  var count = 0;
  for (var i = 0; i < n; i++) {
    var x = a[i] ^ b[i];
    while (x != 0) {
      x &= x - 1;
      count++;
    }
  }
  return count;
}

/// The coarse HSV colour histogram: hue is split into [_hueBins], with a
/// dedicated low-saturation ("grey") bin per [_valBins] value level so washed-out
/// and dark images are still distinguished. Length = `_hueBins*_satBins + _valBins`.
const int _hueBins = 8;
const int _satBins = 2;
const int _valBins = 3;

/// The fixed length of a [colorSignature]: chromatic (hue×sat) bins plus the
/// achromatic (low-saturation) value bins.
const int colorSignatureLength = _hueBins * _satBins + _valBins;

/// A normalised coarse HSV colour histogram of [image] (a cheap palette
/// descriptor): every pixel is binned by hue and saturation, or — when nearly
/// grey — into a value bin, then the counts are L1-normalised so they sum to 1.
/// A black image puts all its mass in the darkest value bin; a grey one spreads
/// across the value bins; a colourful one fills the chromatic bins. Pure.
List<double> colorSignature(img.Image image) {
  final bins = List<double>.filled(colorSignatureLength, 0);
  final n = image.width * image.height;
  if (n == 0) return bins;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final px = image.getPixel(x, y);
      final (h, s, v) = _rgbToHsv(px.r / 255, px.g / 255, px.b / 255);
      if (s < 0.2) {
        // Achromatic: bin by brightness.
        final vb = (v * _valBins).clamp(0, _valBins - 1).floor();
        bins[_hueBins * _satBins + vb] += 1;
      } else {
        final hb = (h / 360 * _hueBins).clamp(0, _hueBins - 1).floor();
        final sb = (s * _satBins).clamp(0, _satBins - 1).floor();
        bins[hb * _satBins + sb] += 1;
      }
    }
  }
  for (var i = 0; i < bins.length; i++) {
    bins[i] /= n;
  }
  return bins;
}

/// RGB (each 0..1) → HSV with hue in 0..360, saturation and value in 0..1.
(double, double, double) _rgbToHsv(double r, double g, double b) {
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final delta = maxC - minC;
  double h;
  if (delta == 0) {
    h = 0;
  } else if (maxC == r) {
    h = 60 * (((g - b) / delta) % 6);
  } else if (maxC == g) {
    h = 60 * (((b - r) / delta) + 2);
  } else {
    h = 60 * (((r - g) / delta) + 4);
  }
  if (h < 0) h += 360;
  final s = maxC == 0 ? 0.0 : delta / maxC;
  return (h, s, maxC);
}

/// The distance in 0..1 between two normalised colour signatures: half the L1
/// (total-variation) distance between the two histograms, which lands in 0..1
/// for distributions that each sum to 1 (0 = identical palette, 1 = disjoint).
double colorDistance(List<double> a, List<double> b) {
  final n = a.length < b.length ? a.length : b.length;
  if (n == 0) return 0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return (sum / 2).clamp(0.0, 1.0);
}

/// The structural weight in [imageSimilarity]; the colour weight is `1 - this`.
/// Structure dominates (the DCT pHash is the stronger duplicate signal); colour
/// is a tie-breaker that separates same-structure / different-palette frames.
const double _structuralWeight = 0.7;

/// The combined perceptual similarity of [a] and [b] in 0..1 (1 = identical):
/// a weighted blend of the structural pHash agreement ([_structuralWeight]) and
/// the colour-signature agreement (`1 - _structuralWeight`).
///
/// Structural agreement is `1 - hammingFraction` over the 256-bit pHash; colour
/// agreement is `1 - colorDistance`. A missing signature on either side
/// contributes a neutral (0) agreement for that component. Pure.
double imageSimilarity(HashedFile a, HashedFile b) {
  final structural = (a.pHash.isEmpty || b.pHash.isEmpty)
      ? 0.0
      : 1 - hammingPHash(a.pHash, b.pHash) / pHashBits;
  final colour = (a.colorSig.isEmpty || b.colorSig.isEmpty)
      ? 0.0
      : 1 - colorDistance(a.colorSig, b.colorSig);
  return (_structuralWeight * structural + (1 - _structuralWeight) * colour)
      .clamp(0.0, 1.0);
}

/// Decodes [bytes] for [path] into a [pHash], or null when the bytes cannot be
/// decoded (corrupt, unsupported, or empty). Never throws.
///
/// [bytes] should be the file's own bytes for natively-decodable formats
/// (jpg/png/webp/gif/bmp) or the embedded-preview JPEG bytes for RAW/HEIC. The
/// extension is not consulted: any decodable image bytes hash successfully.
List<int>? hashImageBytes(String path, Uint8List bytes) {
  final decoded = _decode(bytes);
  return decoded == null ? null : pHash(decoded);
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

/// A hashed file ready for grouping: its [path], the 256-bit structural [pHash]
/// and coarse [colorSig], pixel dimensions, on-disk [fileSize], [basename], and
/// whether it [isRaw].
///
/// Plain data (the signatures are plain `List<int>`/`List<double>`) so
/// [groupDuplicates] is pure and the record is isolate/CLI portable.
class HashedFile {
  /// Creates a hashed-file record. The signatures default to empty so records
  /// built without pixels (most tests, keep-rule scoring) need not supply them;
  /// such a record contributes neutral similarity in [imageSimilarity].
  const HashedFile({
    required this.path,
    required this.width,
    required this.height,
    required this.fileSize,
    required this.basename,
    required this.isRaw,
    this.pHash = const [],
    this.colorSig = const [],
    this.quality = ImageQuality.zero,
    this.peopleScore = 0,
  });

  /// The file path.
  final String path;

  /// The 256-bit DCT perceptual hash as 4×64-bit words (empty when unknown).
  final List<int> pHash;

  /// The normalised coarse HSV colour signature (empty when unknown).
  final List<double> colorSig;

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

  /// A copy of this record with [peopleScore] replaced — used to fold a Tier-2
  /// detection result onto a record whose Tier-1 metadata score was 0.
  HashedFile withPeopleScore(double peopleScore) => HashedFile(
    path: path,
    pHash: pHash,
    colorSig: colorSig,
    width: width,
    height: height,
    fileSize: fileSize,
    basename: basename,
    isRaw: isRaw,
    quality: quality,
    peopleScore: peopleScore,
  );

  /// JSON view of the record (signatures, dimensions, size, RAW-ness, quality,
  /// and the people/pet score).
  Map<String, Object> toJson() => {
    'path': path,
    'pHash': pHash,
    'colorSig': colorSig,
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

/// Groups [records] whose combined [imageSimilarity] is at least [minSimilarity]
/// into [DuplicateGroup]s. Pure (no I/O).
///
/// - `minSimilarity` is the cutoff in 0..1: 1.0 groups only ~identical images;
///   lower values group looser near-matches. The app's slider maps its
///   looseness percent to this cutoff across a trustworthy band.
/// - **RAW-companion exclusion**: two files sharing a basename but differing in
///   RAW-ness (a RAW + its JPG/HEIC sibling) are never placed in the same group,
///   even if their preview signatures match — they are partners, not duplicates.
/// - Each group's [DuplicateGroup.best] is chosen by [chooseKeeper] running the
///   given [pipeline] (default [KeepPipeline.standard]); the rest become its
///   duplicates.
/// - Singletons are dropped: a group needs at least two members.
///
/// Grouping is greedy single-linkage by seed: each not-yet-grouped record seeds
/// a group and pulls in every other ungrouped record at or above [minSimilarity]
/// (minus companions). This is order-stable because [records] order is preserved.
List<DuplicateGroup> groupDuplicates(
  List<HashedFile> records, {
  required double minSimilarity,
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
      if (imageSimilarity(seed, other) < minSimilarity) continue;
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
    pHash: pHash(decoded),
    colorSig: colorSignature(decoded),
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
  PeopleDetector detector = const NoopPeopleDetector(),
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
      if (hashed != null) {
        results.add(await _withTier2(hashed.file, hashed.decoded, detector));
      }
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

/// A hashed file plus the decoded thumbnail it was built from, so a caller can
/// run Tier-2 detection over the SAME pixels without re-decoding.
typedef _HashedWithPixels = ({HashedFile file, img.Image decoded});

/// Builds a [HashedFile] for [path] from its [extracted] thumbnail/preview (or,
/// when null, by decoding the source itself — the slow fallback). Returns null
/// when nothing decodes. Dimensions prefer the batched [meta] (a width/height of
/// 0 means "unknown" → use the decoded image's own size); the Tier-1 people
/// score comes from the same [meta]. Also returns the decoded image so the
/// caller can run Tier-2 over it. Never throws.
_HashedWithPixels? _hashFromExtract(
  String path,
  String? extracted,
  _Meta? meta,
) {
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
  return (
    file: HashedFile(
      path: path,
      pHash: pHash(decoded),
      colorSig: colorSignature(decoded),
      width: w > 0 ? w : decoded.width,
      height: h > 0 ? h : decoded.height,
      fileSize: fileSize,
      basename: basenameKey(path),
      isRaw: PhotoFormats.isRaw(path),
      // Reuse the already-decoded thumbnail to score quality (no re-decode).
      quality: qualityScore(decoded),
      peopleScore: meta?.peopleScore ?? 0,
    ),
    decoded: decoded,
  );
}

/// The Tier-2 fallback: when [file] carries NO Tier-1 people score (metadata was
/// silent) and [detector] is available, score the already-[decoded] thumbnail
/// and return [file] with that [HashedFile.peopleScore]. Otherwise (a Tier-1
/// score is already present, no detector, or the detector can't decide) [file]
/// is returned unchanged. Never throws — a null/failed detection leaves Tier-1.
Future<HashedFile> _withTier2(
  HashedFile file,
  img.Image decoded,
  PeopleDetector detector,
) async {
  if (file.peopleScore != 0 || !detector.isAvailable) return file;
  final score = await detector.scoreDecoded(decoded);
  if (score == null || score <= 0) return file;
  return file.withPeopleScore(score);
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
