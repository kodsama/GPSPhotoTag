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
