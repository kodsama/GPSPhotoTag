import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that writes a PreviewImage JPEG (the [_stripes] pattern)
/// the way exiftool's `-W` would, simulating an embedded RAW/HEIC preview.
class _PreviewRunner implements ProcessRunner {
  _PreviewRunner({this.writePreview = true});

  /// When false, the source "has no embedded preview" (writes nothing).
  final bool writePreview;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    if (!writePreview) return const ProcResult(0, '', '');
    final wIndex = args.indexOf('-W');
    final template = args[wIndex + 1];
    final dir = p.dirname(template);
    final source = args.last;
    final stem = p.basenameWithoutExtension(source);
    File(
      p.join(dir, '${stem}_PreviewImage.jpg'),
    ).writeAsBytesSync(img.encodeJpg(_stripes(32, 32)));
    return const ProcResult(0, '', '');
  }
}

/// A [ProcessRunner] that emulates the batch hashing contract: it records every
/// call, writes embedded thumbnails/previews the way `exiftool -b -W` would, and
/// answers the `-json` dimension read.
///
/// [thumbs]/[previews] map a source basename (with extension) to the JPEG bytes
/// to write for `-ThumbnailImage` / `-PreviewImage`; absent entries simulate a
/// source lacking that embedded image. [dims] maps a source PATH to the original
/// width/height the JSON read reports.
class _BatchRunner implements ProcessRunner {
  _BatchRunner({
    this.thumbs = const {},
    this.previews = const {},
    this.dims = const {},
    this.peopleTags = const {},
    this.dimensionStdout,
  });

  final Map<String, List<int>> thumbs;
  final Map<String, List<int>> previews;
  final Map<String, (int, int)> dims;

  /// Extra people-signal tags to fold into the `-json` entry for a source PATH
  /// (e.g. `{path: {'RegionName': 'Alice'}}`), simulating face/keyword metadata.
  final Map<String, Map<String, Object?>> peopleTags;

  /// When set, the `-json` dimension read returns this raw stdout verbatim
  /// (used to exercise malformed JSON and non-int width/height values).
  final String? dimensionStdout;

  /// Every args list passed to [run], in order.
  final List<List<String>> calls = [];

  /// Args of calls that requested a given extract tag.
  List<List<String>> extractCallsFor(String tag) => [
    for (final c in calls)
      if (c.contains('-$tag')) c,
  ];

  /// Args of the batched JSON dimension reads.
  List<List<String>> get dimensionCalls => [
    for (final c in calls)
      if (c.contains('-json')) c,
  ];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);

    if (args.contains('-json')) {
      if (dimensionStdout != null) return ProcResult(0, dimensionStdout!, '');
      final sources = args
          .where((a) => !a.startsWith('-') && dims.containsKey(a))
          .toList();
      final entries = [
        for (final src in sources)
          {
            'SourceFile': src,
            'ImageWidth': dims[src]!.$1,
            'ImageHeight': dims[src]!.$2,
            ...?peopleTags[src],
          },
      ];
      return ProcResult(0, jsonEncode(entries), '');
    }

    // An extract call: parse the -W template + the requested tag, write outputs.
    final wIndex = args.indexOf('-W');
    if (wIndex < 0) return const ProcResult(0, '', '');
    final dir = p.dirname(args[wIndex + 1]);
    final tag = args
        .firstWhere(
          (a) => a == '-ThumbnailImage' || a == '-PreviewImage',
          orElse: () => '',
        )
        .replaceFirst('-', '');
    if (tag.isEmpty) return const ProcResult(0, '', '');
    final table = tag == 'ThumbnailImage' ? thumbs : previews;
    final sources = args.where(
      (a) => !a.startsWith('-') && a != args[wIndex + 1],
    );
    for (final src in sources) {
      final bytes = table[p.basename(src)];
      if (bytes == null) continue;
      final stem = p.basenameWithoutExtension(src);
      File(p.join(dir, '${stem}_$tag.jpg')).writeAsBytesSync(bytes);
    }
    return const ProcResult(0, '', '');
  }
}

/// A 256-bit pHash (4×64-bit words) with the first [setBits] high bits set, so
/// two such hashes differ by a known number of bits — letting grouping tests
/// dial [imageSimilarity] precisely.
List<int> _pHashWithBits(int setBits) {
  final words = List<int>.filled(4, 0);
  for (var b = 0; b < setBits; b++) {
    words[b ~/ 64] |= 1 << (63 - (b % 64));
  }
  return words;
}

/// A normalised colour signature with all its mass in one bin, so two equal
/// signatures have colour distance 0 (and identical palettes contribute the
/// maximum colour agreement to [imageSimilarity]).
List<double> _flatColorSig() => [
  1.0,
  for (var i = 1; i < colorSignatureLength; i++) 0.0,
];

/// Builds a [HashedFile] with sensible defaults so each test sets only what it
/// cares about. [bits] is how many leading pHash bits are set (controls the
/// structural distance between two records).
HashedFile hf(
  String path, {
  int bits = 0,
  List<double>? colorSig,
  List<double> embedding = const [],
  int width = 100,
  int height = 100,
  int fileSize = 1000,
  String? basename,
  bool isRaw = false,
}) => HashedFile(
  path: path,
  pHash: _pHashWithBits(bits),
  colorSig: colorSig ?? _flatColorSig(),
  embedding: embedding,
  width: width,
  height: height,
  fileSize: fileSize,
  basename: basename ?? basenameKey(path),
  isRaw: isRaw,
);

void main() {
  group('dct1d / dct2d', () {
    test('a constant signal concentrates all energy in the DC coefficient', () {
      final flat = List<double>.filled(32, 5);
      final out = dct1d(flat);
      // DC term holds the energy; every other coefficient is ~0.
      expect(out[0], greaterThan(0));
      for (var k = 1; k < 32; k++) {
        expect(out[k], closeTo(0, 1e-9));
      }
    });

    test('a flat 2-D plane is all-DC after the 2-D transform', () {
      final plane = List<double>.filled(32 * 32, 7);
      final coeffs = dct2d(plane);
      expect(coeffs[0], greaterThan(0)); // DC
      // Any non-DC low-frequency coefficient is ~0 for a constant field.
      expect(coeffs[1], closeTo(0, 1e-6));
      expect(coeffs[32], closeTo(0, 1e-6));
    });

    test('rejects a plane of the wrong length', () {
      expect(() => dct2d(const [1, 2, 3]), throwsArgumentError);
    });
  });

  group('pHashFromLuma', () {
    test('a flat field hashes deterministically (same input → same hash)', () {
      // Every non-DC coefficient is ~0, so the hash is dominated by float noise
      // around the median — but it is still fully deterministic, which is all
      // grouping needs (two identical inputs must collide).
      expect(
        pHashFromLuma(List<double>.filled(32 * 32, 128)),
        pHashFromLuma(List<double>.filled(32 * 32, 128)),
      );
    });

    test('returns four 64-bit words (256 bits total)', () {
      final luma = [for (var i = 0; i < 32 * 32; i++) (i % 8) * 32.0];
      final hash = pHashFromLuma(luma);
      expect(hash, hasLength(4));
      // A structured pattern sets a non-trivial number of bits.
      expect(hammingPHash(hash, const [0, 0, 0, 0]), greaterThan(0));
    });

    test('the DC bit (position 0) is never set', () {
      // A bright top-left ramp has a large DC, yet the DC bit stays 0.
      final luma = [for (var i = 0; i < 32 * 32; i++) i.toDouble()];
      final hash = pHashFromLuma(luma);
      expect(hash[0] & (1 << 63), 0);
    });
  });

  group('pHash on synthetic images', () {
    test('identical images produce equal hashes', () {
      expect(pHash(_stripes(64, 64)), pHash(_stripes(64, 64)));
    });

    test('a flat vs a striped image differ in bits', () {
      final flat = img.Image(width: 64, height: 64)
        ..clear(img.ColorRgb8(128, 128, 128));
      final striped = _stripes(64, 64);
      expect(hammingPHash(pHash(flat), pHash(striped)), greaterThan(0));
    });

    test('robust to a brightness shift (the DC term is excluded)', () {
      // A +30 brightness offset shifts mainly the DC term (excluded from the
      // hash), so only a small fraction of the 256 structural bits move — far
      // fewer than the ~128 an unrelated image would.
      final base = _stripes(64, 64, low: 20, high: 200);
      final brighter = _stripes(64, 64, low: 50, high: 230);
      expect(hammingPHash(pHash(base), pHash(brighter)), lessThan(32));
    });
  });

  group('hammingPHash', () {
    test('equal hashes have distance 0', () {
      expect(hammingPHash(_pHashWithBits(40), _pHashWithBits(40)), 0);
    });

    test('counts differing bits across all four words', () {
      // bits 0..63 set vs bits 0..127 set differ in bits 64..127 (64 bits).
      expect(hammingPHash(_pHashWithBits(64), _pHashWithBits(128)), 64);
    });

    test('tolerates differing lengths (compares the common prefix)', () {
      expect(hammingPHash(const [0xFF], const [0x0F, 0xFF]), 4);
    });
  });

  group('colorSignature / colorDistance', () {
    test('has the fixed length and sums to ~1 (normalised)', () {
      final sig = colorSignature(_stripes(32, 32));
      expect(sig, hasLength(colorSignatureLength));
      expect(sig.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });

    test('an empty image yields an all-zero signature', () {
      final sig = colorSignature(img.Image(width: 0, height: 0));
      expect(sig.every((v) => v == 0), isTrue);
    });

    test('identical palettes have distance 0', () {
      final red = img.Image(width: 16, height: 16)
        ..clear(img.ColorRgb8(220, 10, 10));
      expect(
        colorDistance(colorSignature(red), colorSignature(red)),
        closeTo(0, 1e-9),
      );
    });

    test('disjoint palettes (red vs green) are far apart', () {
      final red = img.Image(width: 16, height: 16)
        ..clear(img.ColorRgb8(220, 10, 10));
      final green = img.Image(width: 16, height: 16)
        ..clear(img.ColorRgb8(10, 220, 10));
      expect(
        colorDistance(colorSignature(red), colorSignature(green)),
        greaterThan(0.5),
      );
    });

    test('a black image bins into the darkest achromatic value bin', () {
      final black = img.Image(width: 8, height: 8)
        ..clear(img.ColorRgb8(0, 0, 0));
      final grey = img.Image(width: 8, height: 8)
        ..clear(img.ColorRgb8(128, 128, 128));
      // Both achromatic but different brightness → a non-zero distance.
      expect(
        colorDistance(colorSignature(black), colorSignature(grey)),
        greaterThan(0),
      );
    });

    test('empty inputs give distance 0', () {
      expect(colorDistance(const [], const []), 0);
    });
  });

  group('imageSimilarity', () {
    test('identical signatures score 1.0', () {
      final a = hf('/a.jpg');
      final b = hf('/b.jpg');
      expect(imageSimilarity(a, b), closeTo(1, 1e-9));
    });

    test('a resized/recompressed near-copy scores high', () {
      // A few differing structural bits, same palette.
      final a = hf('/a.jpg', bits: 0);
      final b = hf('/b.jpg', bits: 4);
      expect(imageSimilarity(a, b), greaterThan(0.98));
    });

    test('a different-palette same-structure frame drops via colour', () {
      final a = hf('/a.jpg', colorSig: _oneHot(0));
      final b = hf('/b.jpg', colorSig: _oneHot(3));
      // Structure identical (1.0 * 0.7) but palette disjoint (0 * 0.3).
      expect(imageSimilarity(a, b), closeTo(0.7, 1e-9));
    });

    test('an unrelated image (far structure + palette) scores low', () {
      final a = hf('/a.jpg', bits: 0, colorSig: _oneHot(0));
      final b = hf('/b.jpg', bits: 200, colorSig: _oneHot(5));
      expect(imageSimilarity(a, b), lessThan(0.55));
    });

    test('a brightness-shifted real image still scores high', () {
      final base = _hashedImage('/a.jpg', _stripes(64, 64, low: 20, high: 200));
      final bright = _hashedImage(
        '/b.jpg',
        _stripes(64, 64, low: 50, high: 230),
      );
      // pHash drops the DC (brightness) term and the palettes are both grey, so
      // a brightness shift leaves the pair clearly similar.
      expect(imageSimilarity(base, bright), greaterThan(0.9));
    });

    test('a missing signature contributes neutral agreement', () {
      const bare = HashedFile(
        path: '/x.jpg',
        width: 10,
        height: 10,
        fileSize: 1,
        basename: 'x',
        isRaw: false,
      );
      // No pHash and no colorSig → both components neutral → similarity 0.
      expect(imageSimilarity(bare, hf('/y.jpg')), closeTo(0, 1e-9));
    });
  });

  group('embeddingSimilarity', () {
    test('identical embeddings score 1.0', () {
      final a = hf('/a.jpg', embedding: [1, 0, 0]);
      final b = hf('/b.jpg', embedding: [2, 0, 0]); // same direction
      expect(embeddingSimilarity(a, b), closeTo(1, 1e-9));
    });

    test('orthogonal embeddings score 0.5 (cosine 0)', () {
      final a = hf('/a.jpg', embedding: [1, 0]);
      final b = hf('/b.jpg', embedding: [0, 1]);
      expect(embeddingSimilarity(a, b), closeTo(0.5, 1e-9));
    });

    test('opposite embeddings score 0.0', () {
      final a = hf('/a.jpg', embedding: [1, 0]);
      final b = hf('/b.jpg', embedding: [-1, 0]);
      expect(embeddingSimilarity(a, b), closeTo(0, 1e-9));
    });

    test('a missing embedding on either side yields 0 (never groups)', () {
      final withVec = hf('/a.jpg', embedding: [1, 0]);
      final without = hf('/b.jpg');
      expect(embeddingSimilarity(withVec, without), 0);
      expect(embeddingSimilarity(without, withVec), 0);
    });
  });

  group('similarityFor (metric dispatch)', () {
    test('fast uses the perceptual+colour metric', () {
      final a = hf('/a.jpg');
      final b = hf('/b.jpg');
      expect(similarityFor(a, b, SimilarityMetric.fast), imageSimilarity(a, b));
    });

    test('smart uses the embedding metric', () {
      final a = hf('/a.jpg', embedding: [1, 0]);
      final b = hf('/b.jpg', embedding: [1, 0]);
      expect(
        similarityFor(a, b, SimilarityMetric.smart),
        embeddingSimilarity(a, b),
      );
    });
  });

  group('groupDuplicates with the Smart metric', () {
    test('groups by embedding, ignoring perceptual differences', () {
      // Structurally far apart (200-bit pHash gap) but same embedding direction:
      // Fast would not group them, Smart should.
      final a = hf('/a.jpg', bits: 0, embedding: [1, 0, 0]);
      final b = hf('/b.jpg', bits: 200, embedding: [1, 0, 0]);
      final fast = groupDuplicates(
        [a, b],
        minSimilarity: 0.55,
        metric: SimilarityMetric.fast,
      );
      expect(fast, isEmpty); // far apart for the perceptual metric
      final smart = groupDuplicates(
        [a, b],
        minSimilarity: 0.9,
        metric: SimilarityMetric.smart,
      );
      expect(smart, hasLength(1));
      expect(smart.single.size, 2);
    });

    test('records without embeddings never group under Smart (→ fallback)', () {
      // Two perceptually-identical files but no embeddings: under Smart the
      // similarity is 0, so nothing groups (the caller would fall back to Fast).
      final groups = groupDuplicates(
        [hf('/a.jpg'), hf('/b.jpg')],
        minSimilarity: 0.55,
        metric: SimilarityMetric.smart,
      );
      expect(groups, isEmpty);
    });
  });

  group('HashedFile.withEmbedding', () {
    test('replaces the embedding, preserving every other field', () {
      final base = hf('/a.jpg', bits: 3);
      final out = base.withEmbedding([0.5, 0.5]);
      expect(out.embedding, [0.5, 0.5]);
      expect(out.path, base.path);
      expect(out.pHash, base.pHash);
      expect(out.colorSig, base.colorSig);
      expect(out.width, base.width);
      expect(out.fileSize, base.fileSize);
    });
  });

  group('HashedFile.withOriginal', () {
    test('restores original dimensions/size, preserving hash + quality', () {
      final proxy = hf('/proxy.jpg', bits: 3);
      final out = proxy.withOriginal(
        width: 4032,
        height: 3024,
        fileSize: 5000000,
        basename: 'img_0042',
      );
      // Substituted originals.
      expect(out.width, 4032);
      expect(out.height, 3024);
      expect(out.resolution, 4032 * 3024);
      expect(out.fileSize, 5000000);
      expect(out.basename, 'img_0042');
      // Everything pixel-derived is preserved.
      expect(out.path, proxy.path);
      expect(out.pHash, proxy.pHash);
      expect(out.colorSig, proxy.colorSig);
      expect(out.embedding, proxy.embedding);
      expect(out.quality, proxy.quality);
      expect(out.peopleScore, proxy.peopleScore);
    });

    test('keeps the existing basename when none is given', () {
      final proxy = hf('/proxy.jpg', bits: 3);
      final out = proxy.withOriginal(width: 1, height: 2, fileSize: 3);
      expect(out.basename, proxy.basename);
    });
  });

  group('hashImageBytes', () {
    test('hashes decodable PNG bytes into a 256-bit pHash', () {
      final png = Uint8List.fromList(img.encodePng(_stripes(16, 16)));
      final hash = hashImageBytes('/x.png', png);
      expect(hash, isNotNull);
      expect(hash, hasLength(4));
    });

    test('returns null for empty bytes', () {
      expect(hashImageBytes('/x.png', Uint8List(0)), isNull);
    });

    test('returns null for undecodable bytes (never throws)', () {
      final junk = Uint8List.fromList(List<int>.filled(32, 0x55));
      expect(hashImageBytes('/x.jpg', junk), isNull);
    });
  });

  group('basenameKey', () {
    test('strips directory and extension, lower-cases', () {
      expect(basenameKey('/a/b/DSCF1.RAF'), 'dscf1');
      expect(basenameKey(r'C:\photos\IMG_2.JPG'), 'img_2');
    });

    test('handles a name without extension', () {
      expect(basenameKey('/a/README'), 'readme');
    });
  });

  group('groupDuplicates', () {
    test('groups identical signatures', () {
      final groups = groupDuplicates([
        hf('/a.jpg'),
        hf('/b.jpg'),
      ], minSimilarity: 1.0);
      expect(groups, hasLength(1));
      expect(groups.single.size, 2);
    });

    test('groups near signatures above the cutoff but not below', () {
      // bits:8 differ → similarity ≈ 1 - 0.7*8/256 ≈ 0.978.
      final near = groupDuplicates([
        hf('/a.jpg', bits: 0),
        hf('/b.jpg', bits: 8),
      ], minSimilarity: 0.97);
      expect(near, hasLength(1));

      final beyond = groupDuplicates([
        hf('/a.jpg', bits: 0),
        hf('/b.jpg', bits: 8),
      ], minSimilarity: 0.99);
      expect(beyond, isEmpty);
    });

    test('drops singletons', () {
      final groups = groupDuplicates([
        hf('/a.jpg', bits: 0),
        hf('/b.jpg', bits: 200, colorSig: _oneHot(5)),
      ], minSimilarity: 0.9);
      expect(groups, isEmpty);
    });

    test('never groups a RAW with its same-name JPG companion', () {
      final groups = groupDuplicates([
        hf('/DSCF1.RAF', isRaw: true, basename: 'dscf1'),
        hf('/DSCF1.JPG', isRaw: false, basename: 'dscf1'),
      ], minSimilarity: 1.0);
      expect(groups, isEmpty);
    });

    test('a JPG never joins a group seeded by a near-twin of its own RAW', () {
      final groups = groupDuplicates([
        hf('/DSCF1.RAF', isRaw: true, basename: 'dscf1'),
        hf('/OTHER.JPG', isRaw: false, basename: 'other'),
        hf('/DSCF1.JPG', isRaw: false, basename: 'dscf1'),
      ], minSimilarity: 1.0);
      expect(groups, hasLength(1));
      final paths = [
        groups.single.best.path,
        ...groups.single.duplicates.map((d) => d.path),
      ];
      expect(paths, isNot(contains('/DSCF1.JPG')));
    });

    test('two RAWs with the same basename DO group (not companions)', () {
      final groups = groupDuplicates([
        hf('/x/DSCF1.RAF', isRaw: true, basename: 'dscf1'),
        hf('/y/DSCF1.RAF', isRaw: true, basename: 'dscf1'),
      ], minSimilarity: 1.0);
      expect(groups, hasLength(1));
    });

    test('best picks highest resolution', () {
      final groups = groupDuplicates([
        hf('/small.jpg', width: 10, height: 10),
        hf('/big.jpg', width: 100, height: 100),
      ], minSimilarity: 1.0);
      expect(groups.single.best.path, '/big.jpg');
    });

    test('best tie-breaks on file size then path', () {
      final bySize = groupDuplicates([
        hf('/a.jpg', width: 10, height: 10, fileSize: 100),
        hf('/b.jpg', width: 10, height: 10, fileSize: 999),
      ], minSimilarity: 1.0);
      expect(bySize.single.best.path, '/b.jpg');

      final byPath = groupDuplicates([
        hf('/z.jpg', width: 10, height: 10, fileSize: 100),
        hf('/a.jpg', width: 10, height: 10, fileSize: 100),
      ], minSimilarity: 1.0);
      expect(byPath.single.best.path, '/a.jpg');
    });

    test('monotonicity: a lower cutoff never groups fewer files', () {
      final records = [
        hf('/a.jpg', bits: 0),
        hf('/b.jpg', bits: 8), // ~0.978 vs a
        hf('/c.jpg', bits: 16), // ~0.956 vs a
      ];
      final tight = _grouped(groupDuplicates(records, minSimilarity: 0.97));
      final loose = _grouped(groupDuplicates(records, minSimilarity: 0.95));
      expect(tight, lessThanOrEqualTo(loose));
      expect(loose, 3);
    });

    test('preserves order and handles an empty input', () {
      expect(groupDuplicates(const [], minSimilarity: 0.5), isEmpty);
    });

    test('a custom pipeline changes which member is kept', () {
      final crisp = HashedFile(
        path: '/crisp.jpg',
        pHash: _pHashWithBits(0),
        colorSig: _flatColorSig(),
        width: 100,
        height: 100,
        fileSize: 100,
        basename: 'crisp',
        isRaw: false,
        quality: const ImageQuality(
          sharpness: 0.9,
          contrast: 0.9,
          colorfulness: 0.9,
          composite: 0.9,
        ),
      );
      final dull = HashedFile(
        path: '/dull.jpg',
        pHash: _pHashWithBits(0),
        colorSig: _flatColorSig(),
        width: 100,
        height: 100,
        fileSize: 999,
        basename: 'dull',
        isRaw: false,
        quality: const ImageQuality(
          sharpness: 0.1,
          contrast: 0.1,
          colorfulness: 0.1,
          composite: 0.1,
        ),
      );
      final byQuality = groupDuplicates(
        [dull, crisp],
        minSimilarity: 1.0,
        pipeline: const KeepPipeline([KeepStep(KeepRule.quality)]),
      );
      expect(byQuality.single.best.path, '/crisp.jpg');

      final byTieBreak = groupDuplicates(
        [crisp, dull],
        minSimilarity: 1.0,
        pipeline: const KeepPipeline([
          KeepStep(KeepRule.quality, enabled: false),
        ]),
      );
      expect(byTieBreak.single.best.path, '/dull.jpg');
    });
  });

  group('HashedFile.toJson', () {
    test('serializes signatures, dimensions, size, RAW-ness, and quality', () {
      final json = hf(
        '/a.jpg',
        bits: 4,
        embedding: [0.1, 0.2],
        width: 40,
        height: 30,
        fileSize: 50,
      ).toJson();
      expect(json['path'], '/a.jpg');
      expect(json['pHash'], isA<List<int>>());
      expect(json['colorSig'], isA<List<double>>());
      expect(json['embedding'], [0.1, 0.2]);
      expect(json['width'], 40);
      expect(json['height'], 30);
      expect(json['fileSize'], 50);
      expect(json['isRaw'], false);
      expect(json['quality'], isA<Map<String, double>>());
      expect(json['peopleScore'], 0);
    });
  });

  group('hashFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hashfile'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('hashes a natively-decodable JPEG with dimensions and size', () async {
      final path = p.join(tmp.path, 'a.jpg');
      File(path).writeAsBytesSync(img.encodeJpg(_stripes(40, 30)));
      final hashed = await hashFile(
        path,
        runner: _PreviewRunner(),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      expect(hashed, isNotNull);
      expect(hashed!.width, 40);
      expect(hashed.height, 30);
      expect(hashed.fileSize, greaterThan(0));
      expect(hashed.isRaw, isFalse);
      expect(hashed.basename, 'a');
      // Both signatures are computed from the decoded image.
      expect(hashed.pHash, hasLength(4));
      expect(hashed.colorSig, hasLength(colorSignatureLength));
      expect(hashed.quality.composite, greaterThan(0));
    });

    test('hashes a RAW via its extracted embedded preview', () async {
      final path = p.join(tmp.path, 'DSCF1.raf');
      File(path).writeAsBytesSync([1, 2, 3]); // RAW container bytes (opaque)
      final hashed = await hashFile(
        path,
        runner: _PreviewRunner(),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      expect(hashed, isNotNull);
      expect(hashed!.isRaw, isTrue);
      expect(hashed.width, 32);
    });

    test('returns null for a RAW with no embedded preview', () async {
      final path = p.join(tmp.path, 'b.nef');
      File(path).writeAsBytesSync([9, 9, 9]);
      final hashed = await hashFile(
        path,
        runner: _PreviewRunner(writePreview: false),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      expect(hashed, isNull);
    });

    test('returns null for a missing file (never throws)', () async {
      final hashed = await hashFile(
        p.join(tmp.path, 'nope.jpg'),
        runner: _PreviewRunner(),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      expect(hashed, isNull);
    });

    test('returns null for undecodable bytes', () async {
      final path = p.join(tmp.path, 'junk.png');
      File(path).writeAsBytesSync(List<int>.filled(16, 0x42));
      final hashed = await hashFile(
        path,
        runner: _PreviewRunner(),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      expect(hashed, isNull);
    });
  });

  group('buildBatchExtractArgs', () {
    test('extracts one tag for every source in a single arg list', () {
      final args = buildBatchExtractArgs(
        ['/a/x.raf', '/a/y.heic'],
        '/tmp/out',
        'ThumbnailImage',
      );
      expect(args, containsAll(['-b', '-m', '-W', '/tmp/out/%f_%t.%s']));
      expect(args, contains('-ThumbnailImage'));
      expect(args.where((a) => !a.startsWith('-')), [
        '/tmp/out/%f_%t.%s',
        '/a/x.raf',
        '/a/y.heic',
      ]);
    });
  });

  group('buildBatchDimensionArgs', () {
    test('reads numeric width/height for every source via -fast2 -json', () {
      final args = buildBatchDimensionArgs(['/a/x.jpg', '/a/y.jpg']);
      expect(
        args,
        containsAll([
          '-fast2',
          '-json',
          '-n',
          '-ImageWidth',
          '-ImageHeight',
          '/a/x.jpg',
          '/a/y.jpg',
        ]),
      );
    });

    test('also requests every people-signal tag (one spawn, no extra)', () {
      final args = buildBatchDimensionArgs(['/a/x.jpg']);
      for (final tag in kPeopleSignalTags) {
        expect(args, contains('-$tag'));
      }
    });
  });

  group('hashFilesBatch', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hashbatch'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Writes [n] opaque source files so each has an on-disk size, returns paths.
    List<String> writeSources(List<String> names) => [
      for (final name in names)
        (File(p.join(tmp.path, name))..writeAsBytesSync([1, 2, 3])).path,
    ];

    test(
      'ONE thumbnail extraction + ONE dimension read for the whole chunk',
      () async {
        final paths = writeSources(['a.raf', 'b.raf', 'c.raf']);
        final thumbJpeg = img.encodeJpg(_stripes(16, 16));
        final runner = _BatchRunner(
          thumbs: {'a.raf': thumbJpeg, 'b.raf': thumbJpeg, 'c.raf': thumbJpeg},
          dims: {for (final pth in paths) pth: (4000, 3000)},
        );

        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );

        expect(out, hasLength(3));
        expect(runner.extractCallsFor('ThumbnailImage'), hasLength(1));
        expect(runner.extractCallsFor('PreviewImage'), isEmpty);
        expect(runner.dimensionCalls, hasLength(1));
      },
    );

    test(
      'dimensions come from the batched JSON, not the thumbnail size',
      () async {
        final paths = writeSources(['a.cr2']);
        final runner = _BatchRunner(
          thumbs: {'a.cr2': img.encodeJpg(_stripes(16, 16))},
          dims: {paths.first: (6000, 4000)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out.single.width, 6000);
        expect(out.single.height, 4000);
        expect(out.single.fileSize, greaterThan(0));
        expect(out.single.isRaw, isTrue);
      },
    );

    test(
      'prefers the thumbnail; falls back to preview only when none',
      () async {
        final paths = writeSources(['thumbed.raf', 'previewed.raf']);
        final runner = _BatchRunner(
          thumbs: {'thumbed.raf': img.encodeJpg(_stripes(16, 16))},
          previews: {'previewed.raf': img.encodeJpg(_stripes(64, 64))},
          dims: {for (final pth in paths) pth: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out.map((h) => h.path), unorderedEquals(paths));
        final previewCalls = runner.extractCallsFor('PreviewImage');
        expect(previewCalls, hasLength(1));
        expect(previewCalls.single, contains(paths[1]));
        expect(previewCalls.single, isNot(contains(paths[0])));
      },
    );

    test(
      'falls back to decoding the source when no embedded image exists',
      () async {
        final path = p.join(tmp.path, 'plain.jpg');
        File(path).writeAsBytesSync(img.encodeJpg(_stripes(40, 24)));
        final runner = _BatchRunner(dims: {path: (40, 24)});

        final out = await hashFilesBatch(
          [path],
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out, hasLength(1));
        expect(out.single.width, 40);
        expect(out.single.pHash, hasLength(4));
      },
    );

    test(
      'skips a file with neither embedded image nor decodable source',
      () async {
        final path = p.join(tmp.path, 'broken.raf');
        File(path).writeAsBytesSync([9, 9, 9]); // not a decodable image
        final runner = _BatchRunner();
        final ticks = <int>[];

        final out = await hashFilesBatch(
          [path],
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          onFileDone: () => ticks.add(1),
        );
        expect(out, isEmpty);
        expect(ticks, hasLength(1));
      },
    );

    test(
      'maps outputs back to sources by basename and ticks per file',
      () async {
        final paths = writeSources(['one.heic', 'two.heic']);
        final runner = _BatchRunner(
          thumbs: {
            'one.heic': img.encodeJpg(_stripes(16, 16)),
            'two.heic': img.encodeJpg(_stripes(16, 16, phase: 4)),
          },
          dims: {for (final pth in paths) pth: (200, 150)},
        );
        var ticks = 0;
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          onFileDone: () => ticks++,
        );
        expect(out.map((h) => h.path), paths);
        expect(ticks, 2);
      },
    );

    test('scores quality + a colour signature from the thumbnail', () async {
      final paths = writeSources(['a.raf']);
      final runner = _BatchRunner(
        thumbs: {'a.raf': img.encodeJpg(_stripes(32, 32))},
        dims: {paths.first: (4000, 3000)},
      );
      final out = await hashFilesBatch(
        paths,
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      expect(out.single.quality.composite, greaterThan(0));
      expect(out.single.colorSig, hasLength(colorSignatureLength));
    });

    test('empty input does nothing and returns empty', () async {
      final runner = _BatchRunner();
      final out = await hashFilesBatch(
        const [],
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      expect(out, isEmpty);
      expect(runner.calls, isEmpty);
    });

    test(
      'falls back to the thumbnail size when JSON lacks dimensions',
      () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(48, 36))},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out.single.width, 48);
        expect(out.single.height, 36);
      },
    );

    test('tolerates malformed dimension JSON (uses decoded size)', () async {
      final paths = writeSources(['a.raf']);
      final runner = _BatchRunner(
        thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
        dimensionStdout: 'not valid json',
      );
      final out = await hashFilesBatch(
        paths,
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      expect(out.single.width, 20);
    });

    test('parses non-int width/height (num and string) from JSON', () async {
      final paths = writeSources(['a.raf']);
      final runner = _BatchRunner(
        thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
        dimensionStdout: jsonEncode([
          {
            'SourceFile': paths.first,
            'ImageWidth': 5000.0,
            'ImageHeight': '4000',
          },
        ]),
      );
      final out = await hashFilesBatch(
        paths,
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      expect(out.single.width, 5000);
      expect(out.single.height, 4000);
    });

    test('reads the Tier-1 people score from the batched JSON', () async {
      final paths = writeSources(['face.raf', 'scenery.raf']);
      final runner = _BatchRunner(
        thumbs: {
          'face.raf': img.encodeJpg(_stripes(20, 20)),
          'scenery.raf': img.encodeJpg(_stripes(20, 20, phase: 4)),
        },
        dims: {for (final pth in paths) pth: (100, 100)},
        peopleTags: {
          paths[0]: {'RegionName': 'Alice'},
        },
      );
      final out = await hashFilesBatch(
        paths,
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      final byPath = {for (final h in out) h.path: h};
      expect(byPath[paths[0]]!.peopleScore, 1.0);
      expect(byPath[paths[1]]!.peopleScore, 0.0);
    });

    test('records a people score even when JSON lacks dimensions', () async {
      final paths = writeSources(['a.raf']);
      final runner = _BatchRunner(
        thumbs: {'a.raf': img.encodeJpg(_stripes(28, 28))},
        dimensionStdout: jsonEncode([
          {'SourceFile': paths.first, 'PersonInImage': 'Bob'},
        ]),
      );
      final out = await hashFilesBatch(
        paths,
        runner: runner,
        tmpDir: p.join(tmp.path, 'work'),
      );
      expect(out.single.width, 28);
      expect(out.single.peopleScore, 1.0);
    });

    group('Tier-2 detector fallback', () {
      test(
        'fills peopleScore from the detector when Tier-1 metadata is silent',
        () async {
          final paths = writeSources(['a.raf']);
          final runner = _BatchRunner(
            thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
            dims: {paths.first: (100, 100)},
          );
          final out = await hashFilesBatch(
            paths,
            runner: runner,
            tmpDir: p.join(tmp.path, 'work'),
            detector: _FakeDetector(0.77),
          );
          expect(out.single.peopleScore, closeTo(0.77, 1e-9));
        },
      );

      test('does NOT override an existing Tier-1 score', () async {
        final paths = writeSources(['face.raf']);
        final runner = _BatchRunner(
          thumbs: {'face.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
          peopleTags: {
            paths[0]: {'RegionName': 'Alice'},
          },
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          detector: _FakeDetector(0.2),
        );
        expect(out.single.peopleScore, 1.0);
      });

      test('an unavailable detector leaves Tier-1 (0) unchanged', () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          detector: _FakeDetector(0.9, available: false),
        );
        expect(out.single.peopleScore, 0.0);
      });

      test(
        'a null/zero detection result leaves Tier-1 (0) unchanged',
        () async {
          final paths = writeSources(['a.raf', 'b.raf']);
          final runner = _BatchRunner(
            thumbs: {
              'a.raf': img.encodeJpg(_stripes(20, 20)),
              'b.raf': img.encodeJpg(_stripes(20, 20, phase: 4)),
            },
            dims: {for (final pth in paths) pth: (100, 100)},
          );
          final out = await hashFilesBatch(
            paths,
            runner: runner,
            tmpDir: p.join(tmp.path, 'work'),
            detector: _FakeDetector(null),
          );
          for (final h in out) {
            expect(h.peopleScore, 0.0);
          }
        },
      );

      test('the default detector is the no-op (no Tier-2)', () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out.single.peopleScore, 0.0);
      });
    });

    group('Smart embedding', () {
      test('folds an available embedder vector onto the record', () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          embedder: _FakeEmbedder([0.1, 0.2, 0.3]),
        );
        expect(out.single.embedding, [0.1, 0.2, 0.3]);
      });

      test('an unavailable embedder leaves the embedding empty', () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          embedder: _FakeEmbedder([0.1], available: false),
        );
        expect(out.single.embedding, isEmpty);
      });

      test('a null/empty embed result leaves the embedding empty', () async {
        final paths = writeSources(['a.raf', 'b.raf']);
        final runner = _BatchRunner(
          thumbs: {
            'a.raf': img.encodeJpg(_stripes(20, 20)),
            'b.raf': img.encodeJpg(_stripes(20, 20, phase: 4)),
          },
          dims: {for (final pth in paths) pth: (100, 100)},
        );
        final nullOut = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
          embedder: _FakeEmbedder(null),
        );
        for (final h in nullOut) {
          expect(h.embedding, isEmpty);
        }
        final emptyOut = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work2'),
          embedder: _FakeEmbedder(const []),
        );
        for (final h in emptyOut) {
          expect(h.embedding, isEmpty);
        }
      });

      test('the default embedder is the no-op (no embedding)', () async {
        final paths = writeSources(['a.raf']);
        final runner = _BatchRunner(
          thumbs: {'a.raf': img.encodeJpg(_stripes(20, 20))},
          dims: {paths.first: (100, 100)},
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        expect(out.single.embedding, isEmpty);
      });
    });
  });
}

/// A [PeopleDetector] that returns a fixed [_score] for any image, used to drive
/// the Tier-2 fallback branches without a model.
class _FakeDetector implements PeopleDetector {
  _FakeDetector(this._score, {this.available = true});

  final double? _score;
  final bool available;

  @override
  bool get isAvailable => available;

  @override
  Future<double?> scoreImage(Uint8List imageBytes) async => _score;

  @override
  Future<double?> scoreDecoded(img.Image image) async => _score;
}

/// An [ImageEmbedder] that returns a fixed [_vector] for any image, used to
/// drive the Smart-embedding fold without a model.
class _FakeEmbedder implements ImageEmbedder {
  _FakeEmbedder(this._vector, {this.available = true});

  final List<double>? _vector;
  final bool available;

  @override
  bool get isAvailable => available;

  @override
  Future<List<double>?> embedDecoded(img.Image image) async => _vector;
}

/// A [HashedFile] whose signatures are computed from a real decoded [image].
HashedFile _hashedImage(String path, img.Image image) => HashedFile(
  path: path,
  pHash: pHash(image),
  colorSig: colorSignature(image),
  width: image.width,
  height: image.height,
  fileSize: 1,
  basename: basenameKey(path),
  isRaw: false,
);

/// A one-hot normalised colour signature with all mass in [bin], so two such
/// signatures with different bins are maximally distant (palette-disjoint).
List<double> _oneHot(int bin) => [
  for (var i = 0; i < colorSignatureLength; i++) i == bin ? 1.0 : 0.0,
];

/// Total number of files that ended up in any group.
int _grouped(List<DuplicateGroup> groups) =>
    groups.fold(0, (sum, g) => sum + g.size);

/// A vertical-stripe pattern (alternating bright/dark columns) so neighbouring
/// pixels differ — exercising real structure in the pHash. [phase] shifts the
/// stripes horizontally; [low]/[high] set the dark/bright levels (raise both to
/// simulate a brightness shift).
img.Image _stripes(
  int w,
  int h, {
  int phase = 0,
  int low = 20,
  int high = 230,
}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (((x + phase) ~/ 8) % 2 == 0) ? high : low;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}
