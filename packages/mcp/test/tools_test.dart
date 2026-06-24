import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_mcp/gpsphototag_mcp.dart';
// `image` resolves transitively via gpsphototag_engine; used here only to mint
// tiny decodable JPEG fixtures.
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// Returns canned results so tools that probe exiftool don't shell out.
class _FakeRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    if (executable == 'exiftool') return const ProcResult(0, '13.55', '');
    return const ProcResult(0, '', '');
  }
}

McpTool _tool(String name, {bool exiftoolAvailable = false}) => buildTools(
  runner: _FakeRunner(),
  exiftoolAvailable: exiftoolAvailable,
).firstWhere((t) => t.name == name);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mcp_tools'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes a tiny JPEG seeded with [dt] as DateTimeOriginal; returns its path.
  Future<String> seededJpeg(String name, DateTime dt) async {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
    await const JpegExifBackend().writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: dt,
    );
    return path;
  }

  group('tag_photos', () {
    test('tags a JPEG whose time matches the GPX track', () async {
      final naive = DateTime(2026, 6, 22, 12, 43, 38);
      final photo = await seededJpeg('a.jpg', naive);
      final gpx = '${tmp.path}/t.gpx';
      File(gpx).writeAsStringSync('''
<gpx version="1.1"><trk><trkseg>
  <trkpt lat="42.5" lon="18.1"><time>${naive.toUtc().toIso8601String()}</time></trkpt>
</trkseg></trk></gpx>''');

      final result = await _tool('tag_photos').run({
        'photos': [photo],
        'gpx': [gpx],
        'overwrite': true,
        'replace': true,
      });

      expect(result['ok'], isTrue);
      final summary = result['summary'] as Map<String, Object?>;
      expect(summary.values.fold<int>(0, (a, b) => a + (b as int)), 1);
      expect(result['count'], 1);
    });

    test('bad input: no photos found', () async {
      final result = await _tool('tag_photos').run({'photos': <String>[]});
      expect(result['ok'], isFalse);
      expect(result['code'], 'bad_input');
      expect(result['error'], contains('no photos'));
    });

    test('bad input: no location source', () async {
      final photo = await seededJpeg('b.jpg', DateTime(2026));
      final result = await _tool('tag_photos').run({
        'photos': [photo],
      });
      expect(result['ok'], isFalse);
      expect(result['code'], 'bad_input');
      expect(result['error'], contains('location source'));
    });
  });

  group('render_heatmap', () {
    test('bad input: photos and out required', () async {
      final result = await _tool('render_heatmap').run({'photos': <String>[]});
      expect(result['ok'], isFalse);
      expect(result['code'], 'bad_input');
    });
  });

  group('prune_raw', () {
    test('bad input: roots required', () async {
      final result = await _tool('prune_raw').run({'roots': <String>[]});
      expect(result['ok'], isFalse);
      expect(result['code'], 'bad_input');
    });

    test('dry_run reports an orphan RAW without deleting it', () async {
      final orphan = '${tmp.path}/orphan.raf';
      File(orphan).writeAsBytesSync([0, 1, 2, 3]);

      final result = await _tool('prune_raw').run({
        'roots': [tmp.path],
        'dry_run': true,
      });

      expect(result['ok'], isTrue);
      expect(File(orphan).existsSync(), isTrue);
      final items = result['items'] as List<Object?>;
      expect(items, hasLength(1));
      expect((items.single as Map<String, Object?>)['status'], 'dry_run');
    });
  });

  group('fix_dates', () {
    test('bad input: photos and mode required', () async {
      final result = await _tool('fix_dates').run({'photos': <String>[]});
      expect(result['ok'], isFalse);
      expect(result['code'], 'bad_input');
    });

    test('dry_run on a seeded JPEG reports without writing', () async {
      final photo = await seededJpeg('c.jpg', DateTime(2020, 1, 2, 3, 4, 5));
      final result = await _tool('fix_dates').run({
        'photos': [photo],
        'mode': 'file',
        'dry_run': true,
      });
      expect(result['ok'], isTrue);
      expect(result['count'], 1);
    });
  });

  group('check_toolkit', () {
    test('returns the toolkit list', () async {
      final result = await _tool('check_toolkit').run({});
      expect(result['ok'], isTrue);
      expect(result['tools'], isA<List<Object?>>());
    });
  });

  group('get_capabilities', () {
    test('reflects exiftoolAvailable=true', () async {
      final result = await _tool(
        'get_capabilities',
        exiftoolAvailable: true,
      ).run({});
      expect(result['exiftool_available'], isTrue);
      expect(
        (result['formats'] as Map<String, Object?>)['heic'],
        contains('exiftool'),
      );
    });

    test('reflects exiftoolAvailable=false', () async {
      final result = await _tool(
        'get_capabilities',
        exiftoolAvailable: false,
      ).run({});
      expect(result['exiftool_available'], isFalse);
      expect(
        (result['formats'] as Map<String, Object?>)['heic'],
        contains('unavailable'),
      );
    });
  });
}
