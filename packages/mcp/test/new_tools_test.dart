import 'dart:convert';
import 'dart:io';

// `image` resolves transitively via stunda_engine; used here only to mint
// tiny decodable fixtures.
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda_mcp/stunda_mcp.dart';
import 'package:test/test.dart';

/// Fails every spawn, so hashing decodes source bytes and GPS reads throw —
/// the no-exiftool environment a plain `dart run` sees.
class _FailingRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(1, '', 'exiftool not found');
}

/// Returns one GPS point per photo in exiftool `-json` form.
class _GpsRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final photos = args.where((a) => !a.startsWith('-')).toList();
    return ProcResult(
      0,
      jsonEncode([
        for (final path in photos)
          {
            'SourceFile': path,
            'GPSLatitude': 59.33,
            'GPSLongitude': 18.07,
            'DateTimeOriginal': '2026:09:09 10:00:00',
          },
      ]),
      '',
    );
  }
}

McpTool _tool(String name, {ProcessRunner? runner}) =>
    buildTools(runner: runner ?? _FailingRunner())
        .firstWhere((t) => t.name == name);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mcp_new_tools_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String at(String name) => p.join(tmp.path, name);

  /// A deterministic-noise JPEG so two files can be byte-identical.
  void jpeg(String name, int seed) {
    final image = img.Image(width: 48, height: 48);
    var x = seed * 2654435761 & 0xffffffff;
    for (final pixel in image) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      pixel.setRgb((x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
    }
    File(at(name)).writeAsBytesSync(img.encodeJpg(image));
  }

  test('the catalog exposes a tool for every engine capability', () {
    expect(
      buildTools().map((t) => t.name),
      containsAll([
        'tag_photos',
        'render_heatmap',
        'prune_raw',
        'fix_dates',
        'scan_library',
        'list_photos',
        'find_duplicates',
        'shrink_library',
        'list_providers',
        'list_sources',
        'check_toolkit',
        'get_capabilities',
      ]),
    );
  });

  test('every tool declares an object input schema', () {
    for (final tool in buildTools()) {
      expect(tool.inputSchema['type'], 'object', reason: tool.name);
      expect(tool.description, isNotEmpty, reason: tool.name);
    }
  });

  group('scan_library', () {
    test('reports counts and hides path lists by default', () async {
      jpeg('a.jpg', 1);
      File(at('notes.txt')).writeAsStringSync('hi');

      final out = await _tool('scan_library').run({
        'roots': [tmp.path],
      });

      expect(out['ok'], isTrue);
      expect(out['photoCount'], 1);
      expect(out['unsupportedCount'], 1);
      expect(out.containsKey('photos'), isFalse);
    });

    test('paths=true includes the full lists', () async {
      jpeg('a.jpg', 2);

      final out = await _tool('scan_library').run({
        'roots': [tmp.path],
        'paths': true,
      });

      expect((out['photos']! as List).single, endsWith('a.jpg'));
    });

    test('missing roots is bad_input', () async {
      final out = await _tool('scan_library').run({'roots': <String>[]});

      expect(out['ok'], isFalse);
      expect(out['code'], 'bad_input');
    });
  });

  group('list_photos', () {
    test('returns coordinates and capture time per photo', () async {
      jpeg('a.jpg', 3);

      final out = await _tool('list_photos', runner: _GpsRunner()).run({
        'photos': [tmp.path],
      });

      expect(out['ok'], isTrue);
      expect(out['count'], 1);
      final first = (out['photos']! as List).first as Map<String, Object?>;
      expect(first['lat'], closeTo(59.33, 1e-9));
      expect(first['taken_at'], '2026:09:09 10:00:00');
    });

    test('no photos found is bad_input', () async {
      final out = await _tool('list_photos').run({
        'photos': [tmp.path],
      });

      expect(out['code'], 'bad_input');
    });

    test('an exiftool failure surfaces as missing_toolkit', () async {
      jpeg('a.jpg', 4);

      final out = await _tool('list_photos').run({
        'photos': [tmp.path],
      });

      expect(out['ok'], isFalse);
      expect(out['code'], 'missing_toolkit');
    });
  });

  group('find_duplicates', () {
    test('reports a duplicate group without removing anything', () async {
      jpeg('a.jpg', 5);
      File(at('copy.jpg'))
          .writeAsBytesSync(File(at('a.jpg')).readAsBytesSync());

      final out = await _tool('find_duplicates').run({
        'roots': [tmp.path],
      });

      expect(out['ok'], isTrue);
      expect(out['summary'], {'kept': 1, 'dry_run': 1});
      expect(File(at('copy.jpg')).existsSync(), isTrue);
    });

    test('apply with delete removes the non-kept copy', () async {
      jpeg('a.jpg', 6);
      File(at('copy.jpg'))
          .writeAsBytesSync(File(at('a.jpg')).readAsBytesSync());

      final out = await _tool('find_duplicates').run({
        'roots': [tmp.path],
        'apply': true,
        'delete': true,
      });

      expect(out['summary'], {'kept': 1, 'pruned_deleted': 1});
      expect(Directory(tmp.path).listSync().whereType<File>(), hasLength(1));
    });

    test('missing roots is bad_input', () async {
      expect(
        (await _tool('find_duplicates').run({'roots': <String>[]}))['code'],
        'bad_input',
      );
    });

    test('an out-of-range min_similarity is bad_input', () async {
      final out = await _tool('find_duplicates').run({
        'roots': [tmp.path],
        'min_similarity': 4,
      });

      expect(out['code'], 'bad_input');
    });

    test('the smart metric is accepted and degrades without a model', () async {
      jpeg('a.jpg', 7);
      File(at('copy.jpg'))
          .writeAsBytesSync(File(at('a.jpg')).readAsBytesSync());

      final out = await _tool('find_duplicates').run({
        'roots': [tmp.path],
        'metric': 'smart',
      });

      expect(out['ok'], isTrue);
      expect(out['summary'], {'kept': 1, 'dry_run': 1});
    });
  });

  group('shrink_library', () {
    test('stages orphans and reports without removing', () async {
      File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]);

      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': ['orphans'],
      });

      expect(out['ok'], isTrue);
      expect(out['summary'], {'dry_run': 1});
      expect(File(at('lonely.raf')).existsSync(), isTrue);
    });

    test('apply with delete removes the staged file', () async {
      File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]);

      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': ['orphans'],
        'apply': true,
        'delete': true,
      });

      expect(out['summary'], {'pruned_deleted': 1});
      expect(File(at('lonely.raf')).existsSync(), isFalse);
    });

    test('the pairs stage honours pair_drop', () async {
      jpeg('pair.jpg', 8);
      File(at('pair.raf')).writeAsBytesSync([0, 0, 0]);

      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': ['pairs'],
        'pair_drop': 'photo',
        'min_similarity': 0.8,
        'quality_threshold': 0.2,
        'metric': 'fast',
      });

      final items = out['items']! as List;
      expect(items, hasLength(1));
      expect(
        (items.single as Map<String, Object?>)['path'],
        endsWith('pair.jpg'),
      );
    });

    test('missing roots is bad_input', () async {
      expect(
        (await _tool('shrink_library').run({
          'roots': <String>[],
          'stages': ['orphans'],
        }))['code'],
        'bad_input',
      );
    });

    test('an empty stage list is bad_input', () async {
      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': <String>[],
      });

      expect(out['code'], 'bad_input');
      expect(out['error'], contains('at least one stage'));
    });

    test('an unknown stage names itself in the error', () async {
      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': ['blurry'],
      });

      expect(out['code'], 'bad_input');
      expect(out['error'], contains('blurry'));
    });

    test('an unknown pair_drop is bad_input', () async {
      final out = await _tool('shrink_library').run({
        'roots': [tmp.path],
        'stages': ['pairs'],
        'pair_drop': 'jpeg',
      });

      expect(out['code'], 'bad_input');
      expect(out['error'], contains('pair_drop'));
    });
  });

  group('prune_raw direction', () {
    setUp(() {
      jpeg('solo.jpg', 9);
      jpeg('pair.jpg', 10);
      File(at('pair.raf')).writeAsBytesSync([0]);
      File(at('orphan.raf')).writeAsBytesSync([0]);
    });

    test('defaults to orphan RAWs', () async {
      final out = await _tool('prune_raw').run({
        'roots': [tmp.path],
        'dry_run': true,
      });

      expect(
        (out['items']! as List).map(
          (e) => p.basename((e as Map<String, Object?>)['path']! as String),
        ),
        ['orphan.raf'],
      );
    });

    test('orphan-images targets the photo side', () async {
      final out = await _tool('prune_raw').run({
        'roots': [tmp.path],
        'direction': 'orphan-images',
        'dry_run': true,
      });

      expect(
        (out['items']! as List).map(
          (e) => p.basename((e as Map<String, Object?>)['path']! as String),
        ),
        ['solo.jpg'],
      );
    });

    test('an unknown direction is bad_input', () async {
      final out = await _tool('prune_raw').run({
        'roots': [tmp.path],
        'direction': 'sideways',
      });

      expect(out['code'], 'bad_input');
    });
  });

  group('catalogs', () {
    test('list_providers returns the tile and geocoder catalog', () async {
      final out = await _tool('list_providers').run({});

      expect(out['ok'], isTrue);
      expect(
        (out['providers']! as List).map((e) => (e as Map)['id']),
        containsAll(['carto_light', 'osm', 'nominatim']),
      );
    });

    test('list_sources matches what get_capabilities advertises', () async {
      final sources = await _tool('list_sources').run({});
      final caps = await _tool('get_capabilities').run({});

      expect(
        (sources['sources']! as List).map((e) => (e as Map)['id']),
        containsAll(caps['sources']! as List),
      );
    });
  });
}
