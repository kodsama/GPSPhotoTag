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
    this.dimensionStdout,
  });

  final Map<String, List<int>> thumbs;
  final Map<String, List<int>> previews;
  final Map<String, (int, int)> dims;

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

/// Builds a [HashedFile] with sensible defaults so each test sets only what it
/// cares about.
HashedFile hf(
  String path,
  int hash, {
  int width = 100,
  int height = 100,
  int fileSize = 1000,
  String? basename,
  bool isRaw = false,
}) => HashedFile(
  path: path,
  hash: hash,
  width: width,
  height: height,
  fileSize: fileSize,
  basename: basename ?? basenameKey(path),
  isRaw: isRaw,
);

void main() {
  group('dHashFromLuma', () {
    test('sets a bit when the left pixel is brighter than its right', () {
      // A single bright pixel at the top-left of an otherwise dark row → the
      // first comparison (col0 > col1) sets the most-significant bit.
      final luma = List<int>.filled(9 * 8, 0);
      luma[0] = 255;
      final hash = dHashFromLuma(luma);
      // The top-left comparison is the highest of the 64 bits.
      expect(hash & (1 << 63), isNot(0));
    });

    test('a flat image yields an all-zero hash', () {
      expect(dHashFromLuma(List<int>.filled(9 * 8, 128)), 0);
    });

    test('rejects a luma list of the wrong length', () {
      expect(() => dHashFromLuma(const [1, 2, 3]), throwsArgumentError);
    });

    test('honours custom grid dimensions', () {
      // 3x2 grid → 2 comparisons per row, 2 rows = 4 bits.
      final hash = dHashFromLuma(
        const [
          9, 0, 0, // row 0: 9>0 set, 0>0 clear → 10
          0, 0, 9, // row 1: 0>0 clear, 0>9 clear → 00
        ],
        width: 3,
        height: 2,
      );
      expect(hash, 0x8); // 1000
    });
  });

  group('dHash on synthetic images', () {
    test('identical images produce equal hashes', () {
      final a = _stripes(64, 64);
      final b = _stripes(64, 64);
      expect(dHash(a), dHash(b));
    });

    test('a flat vs a striped image differ in bits', () {
      final flat = img.Image(width: 64, height: 64)
        ..clear(img.ColorRgb8(128, 128, 128));
      final striped = _stripes(64, 64);
      // The flat image sets no horizontal-comparison bits; the striped one sets
      // several, so the hashes differ.
      expect(hamming(dHash(flat), dHash(striped)), greaterThan(0));
    });

    test('a horizontally-shifted image differs from the original', () {
      final striped = _stripes(64, 64);
      // Shifting the stripes by half a period inverts the bright/dark ordering
      // across the horizontal comparisons, so the dHash changes.
      final shifted = _stripes(64, 64, phase: 4);
      expect(dHash(striped), isNot(dHash(shifted)));
    });
  });

  group('hamming', () {
    test('equal hashes have distance 0', () {
      expect(hamming(0xDEADBEEF, 0xDEADBEEF), 0);
    });

    test('counts differing bits', () {
      expect(hamming(0x0, 0xF), 4);
      expect(hamming(0x1, 0x0), 1);
    });

    test('is symmetric', () {
      expect(hamming(0xAB, 0xCD), hamming(0xCD, 0xAB));
    });
  });

  group('hashImageBytes', () {
    test('hashes decodable PNG bytes', () {
      final png = Uint8List.fromList(img.encodePng(_stripes(16, 16)));
      expect(hashImageBytes('/x.png', png), isNotNull);
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
    test('groups identical hashes', () {
      final groups = groupDuplicates([
        hf('/a.jpg', 0xFF),
        hf('/b.jpg', 0xFF),
      ], threshold: 0);
      expect(groups, hasLength(1));
      expect(groups.single.size, 2);
    });

    test('groups near hashes within the threshold but not beyond', () {
      // 0xF0 vs 0xF1 differ by 1 bit.
      final near = groupDuplicates([
        hf('/a.jpg', 0xF0),
        hf('/b.jpg', 0xF1),
      ], threshold: 1);
      expect(near, hasLength(1));

      final beyond = groupDuplicates([
        hf('/a.jpg', 0xF0),
        hf('/b.jpg', 0xF1),
      ], threshold: 0);
      expect(beyond, isEmpty);
    });

    test('drops singletons', () {
      final groups = groupDuplicates([
        hf('/a.jpg', 0x1),
        hf('/b.jpg', 0xFFFF),
      ], threshold: 0);
      expect(groups, isEmpty);
    });

    test('never groups a RAW with its same-name JPG companion', () {
      // Same basename, same hash, but one is RAW → companions, not duplicates.
      final groups = groupDuplicates([
        hf('/DSCF1.RAF', 0xAA, isRaw: true, basename: 'dscf1'),
        hf('/DSCF1.JPG', 0xAA, isRaw: false, basename: 'dscf1'),
      ], threshold: 0);
      expect(groups, isEmpty);
    });

    test('a JPG never joins a group seeded by a near-twin of its own RAW', () {
      // RAF seeds; a different JPG matches it AND the companion JPG also matches
      // — the companion must still be excluded from the RAF's group.
      final groups = groupDuplicates([
        hf('/DSCF1.RAF', 0xAA, isRaw: true, basename: 'dscf1'),
        hf('/OTHER.JPG', 0xAA, isRaw: false, basename: 'other'),
        hf('/DSCF1.JPG', 0xAA, isRaw: false, basename: 'dscf1'),
      ], threshold: 0);
      expect(groups, hasLength(1));
      final paths = [
        groups.single.best.path,
        ...groups.single.duplicates.map((d) => d.path),
      ];
      expect(paths, isNot(contains('/DSCF1.JPG')));
    });

    test('two RAWs with the same basename DO group (not companions)', () {
      final groups = groupDuplicates([
        hf('/x/DSCF1.RAF', 0xAA, isRaw: true, basename: 'dscf1'),
        hf('/y/DSCF1.RAF', 0xAA, isRaw: true, basename: 'dscf1'),
      ], threshold: 0);
      expect(groups, hasLength(1));
    });

    test('best picks highest resolution', () {
      final groups = groupDuplicates([
        hf('/small.jpg', 0xAA, width: 10, height: 10),
        hf('/big.jpg', 0xAA, width: 100, height: 100),
      ], threshold: 0);
      expect(groups.single.best.path, '/big.jpg');
    });

    test('best tie-breaks on file size then path', () {
      final bySize = groupDuplicates([
        hf('/a.jpg', 0xAA, width: 10, height: 10, fileSize: 100),
        hf('/b.jpg', 0xAA, width: 10, height: 10, fileSize: 999),
      ], threshold: 0);
      expect(bySize.single.best.path, '/b.jpg');

      final byPath = groupDuplicates([
        hf('/z.jpg', 0xAA, width: 10, height: 10, fileSize: 100),
        hf('/a.jpg', 0xAA, width: 10, height: 10, fileSize: 100),
      ], threshold: 0);
      expect(byPath.single.best.path, '/a.jpg');
    });

    test('threshold monotonicity: looser never groups fewer files', () {
      final records = [
        hf('/a.jpg', 0x00),
        hf('/b.jpg', 0x01), // 1 bit
        hf('/c.jpg', 0x03), // 2 bits from a
      ];
      final tight = _grouped(groupDuplicates(records, threshold: 1));
      final loose = _grouped(groupDuplicates(records, threshold: 2));
      expect(tight, lessThanOrEqualTo(loose));
      expect(loose, 3);
    });

    test('preserves order and handles an empty input', () {
      expect(groupDuplicates(const [], threshold: 5), isEmpty);
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
      // Dimensions come from the 32×32 preview, not the opaque RAW container.
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
      // Both sources ride on the same call (one spawn for the whole chunk).
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
        // Batching: exactly ONE thumbnail extract for the 3 files (not 3), one
        // dimension read, and ZERO preview extracts (all had thumbnails).
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
        // The thumb is 16×16 but the recorded resolution is the original 6000×4000.
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
        // The preview pass ran exactly once, over ONLY the thumb-less file.
        final previewCalls = runner.extractCallsFor('PreviewImage');
        expect(previewCalls, hasLength(1));
        expect(previewCalls.single, contains(paths[1]));
        expect(previewCalls.single, isNot(contains(paths[0])));
      },
    );

    test(
      'falls back to decoding the source when no embedded image exists',
      () async {
        // A real decodable JPEG on disk, but exiftool extracts nothing for it.
        final path = p.join(tmp.path, 'plain.jpg');
        File(path).writeAsBytesSync(img.encodeJpg(_stripes(40, 24)));
        final runner = _BatchRunner(dims: {path: (40, 24)});

        final out = await hashFilesBatch(
          [path],
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        // Hashed from the source bytes themselves (the slow fallback path).
        expect(out, hasLength(1));
        expect(out.single.width, 40);
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
        // Still ticked once for the skipped file so progress reaches the total.
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
        expect(out.map((h) => h.path), paths); // mapped back to each source
        expect(ticks, 2); // one tick per input file
      },
    );

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
          // No dims entry for the path → JSON omits it.
        );
        final out = await hashFilesBatch(
          paths,
          runner: runner,
          tmpDir: p.join(tmp.path, 'work'),
        );
        // Width/height come from the decoded thumbnail itself.
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
      // ImageWidth as a JSON number (double) and ImageHeight as a string.
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
  });
}

/// Total number of files that ended up in any group.
int _grouped(List<DuplicateGroup> groups) =>
    groups.fold(0, (sum, g) => sum + g.size);

/// A vertical-stripe pattern (alternating bright/dark columns) so neighbouring
/// pixels differ — exercising real horizontal-comparison bits in the dHash.
/// [phase] shifts the stripes horizontally.
img.Image _stripes(int w, int h, {int phase = 0}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // 8-pixel period: bright for half, dark for half.
      final v = (((x + phase) ~/ 8) % 2 == 0) ? 230 : 20;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}
