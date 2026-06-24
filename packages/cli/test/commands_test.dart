import 'dart:convert';
import 'dart:io';

import 'package:gpsphototag_cli/src/exit_codes.dart';
import 'package:gpsphototag_cli/src/runner.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_capture.dart';

void main() {
  late Directory tmp;
  late BufferSink buf;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cli_cmd_test');
    buf = BufferSink();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<int> run(List<String> args) async =>
      (await buildRunner(sink: buf).run(args)) ?? 0;

  /// Last non-empty JSON line emitted (commands emit one object per line).
  Map<String, Object?> lastJsonLine() {
    final lines =
        buf.text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return jsonDecode(lines.last) as Map<String, Object?>;
  }

  group('info', () {
    test('--json emits valid JSON with expected keys; exit 0', () async {
      final code = await run(['--json', 'info']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      expect(json['name'], 'gpsphototag');
      expect(json['version'], isA<String>());
      expect(json['platform'], isA<String>());
      expect(json['formats'], isA<Map<String, Object?>>());
      expect(json['sources'], contains('gpx'));
    });

    test('human mode prints a version line', () async {
      final code = await run(['info']);
      expect(code, ExitCodes.ok);
      expect(buf.text, contains('gpsphototag'));
    });
  });

  group('list-sources / list-providers', () {
    test('list-sources --json has a sources array', () async {
      final code = await run(['--json', 'list-sources']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      final sources = json['sources'] as List<Object?>;
      expect(sources, isNotEmpty);
      expect((sources.first as Map)['id'], 'gpx');
    });

    test('list-sources human mode lists ids', () async {
      await run(['list-sources']);
      expect(buf.text, contains('gpx'));
    });

    test('list-providers --json has a providers array', () async {
      final code = await run(['--json', 'list-providers']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      final providers = json['providers'] as List<Object?>;
      expect(providers, isNotEmpty);
      expect((providers.first as Map).containsKey('id'), isTrue);
    });
  });

  group('schema', () {
    test('emits valid JSON with commands and exitCodes; exit 0', () async {
      final code = await run(['schema']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      expect(json['tool'], 'gpsphototag');
      expect(json['commands'], isA<Map<String, Object?>>());
      expect((json['commands'] as Map).containsKey('tag'), isTrue);
      expect((json['exitCodes'] as Map)['0'], isA<String>());
    });
  });

  group('check', () {
    test('--json reports a tools array; exit 0', () async {
      final code = await run(['--json', 'check']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      expect(json['tools'], isA<List<Object?>>());
      expect(json['tools'], isNotEmpty);
    });

    test('human mode prints a tool line', () async {
      final code = await run(['check']);
      expect(code, ExitCodes.ok);
      expect(buf.text.toLowerCase(), contains('exiftool'));
    });
  });

  group('tag', () {
    /// Writes a JPEG carrying [time] as DateTimeOriginal (and dummy GPS).
    Future<String> seedPhoto(String name, DateTime time) async {
      final path = p.join(tmp.path, name);
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend()
          .writeGps(path, latitude: 1, longitude: 1, dateTimeOriginal: time);
      return path;
    }

    /// Writes a GPX file covering [utc] with a distinctive coordinate.
    String seedGpx(DateTime utc, {double lat = 42.5, double lon = 18.5}) {
      final path = p.join(tmp.path, 'track.gpx');
      final iso = utc.toIso8601String();
      File(path).writeAsStringSync('''
<gpx version="1.1"><trk><trkseg>
<trkpt lat="$lat" lon="$lon"><time>$iso</time></trkpt>
</trkseg></trk></gpx>''');
      return path;
    }

    test('tags a photo from a matching GPX point; GPS readable after', () async {
      // Naive EXIF time becomes UTC via the host's local zone (no offset).
      final naive = DateTime(2026, 6, 22, 12, 0, 0);
      final photo = await seedPhoto('img.jpg', naive);
      final gpx = seedGpx(naive.toUtc());

      final code = await run([
        '--json',
        'tag',
        '-p',
        tmp.path,
        '-g',
        gpx,
        '--overwrite',
        '--replace',
      ]);

      expect(code, ExitCodes.ok);
      final done = lastJsonLine();
      expect(done['event'], 'done');
      expect((done['summary'] as Map)['tagged'], 1);

      final meta = await const JpegExifBackend().read(photo);
      expect(meta.hasGps, isTrue);
    });

    test('no photos -> bad_input (exit 3)', () async {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      final code = await run(['--json', 'tag', '-p', empty.path, '--overwrite']);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['code'], 'bad_input');
    });

    test('no location source -> bad_input (exit 3)', () async {
      await seedPhoto('img.jpg', DateTime(2026, 6, 22, 12));
      final code = await run(['--json', 'tag', '-p', tmp.path, '--overwrite']);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['message'], contains('location source'));
    });

    test('bad --max-time-diff -> bad_input (exit 3)', () async {
      await seedPhoto('img.jpg', DateTime(2026, 6, 22, 12));
      final code = await run([
        '--json',
        'tag',
        '-p',
        tmp.path,
        '--overwrite',
        '--max-time-diff',
        'notanumber',
      ]);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['message'], contains('max-time-diff'));
    });
  });

  group('prune-raw', () {
    test('dry-run reports an orphan without trashing it; exit 0', () async {
      final orphan = File(p.join(tmp.path, 'A.RAF'))..writeAsStringSync('raw');
      File(p.join(tmp.path, 'B.RAF')).writeAsStringSync('raw');
      File(p.join(tmp.path, 'B.JPG')).writeAsStringSync('jpg');

      final code = await run([
        '--json',
        'prune-raw',
        '-p',
        tmp.path,
        '--dry-run',
      ]);

      expect(code, ExitCodes.ok);
      // The orphan must still exist (dry-run trashes nothing).
      expect(orphan.existsSync(), isTrue);

      final lines = buf.text
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      final item =
          lines.firstWhere((e) => e['event'] == 'item', orElse: () => {});
      expect(item['status'], 'dry_run');
      expect(item['path'], endsWith('A.RAF'));

      final done = lines.last;
      expect(done['event'], 'done');
      expect((done['summary'] as Map)['dry_run'], 1);
    });

    test('no roots -> bad_input (exit 3)', () async {
      final code = await run(['--json', 'prune-raw']);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['code'], 'bad_input');
    });
  });

  group('fix-dates', () {
    test('exif mode dry-run on a dated photo; exit 0', () async {
      final path = p.join(tmp.path, 'img.jpg');
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend().writeGps(path,
          latitude: 1, longitude: 1, dateTimeOriginal: DateTime(2026, 6, 22, 12));

      final code = await run([
        '--json',
        'fix-dates',
        '-p',
        tmp.path,
        '--mode',
        'exif',
        '--dry-run',
      ]);

      expect(code, ExitCodes.ok);
      final done = lastJsonLine();
      expect(done['event'], 'done');
    });

    test('no photos -> bad_input (exit 3)', () async {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      final code = await run(
          ['--json', 'fix-dates', '-p', empty.path, '--mode', 'exif']);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['code'], 'bad_input');
    });
  });

  group('map', () {
    test('no photos -> bad_input (exit 3)', () async {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      final code = await run([
        '--json',
        'map',
        '-p',
        empty.path,
        '-o',
        p.join(tmp.path, 'out.png'),
      ]);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['code'], 'bad_input');
    });

    test('missing --out -> bad_input (exit 3)', () async {
      final path = p.join(tmp.path, 'img.jpg');
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend().writeGps(path, latitude: 1, longitude: 1);

      final code = await run(['--json', 'map', '-p', tmp.path]);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['message'], contains('--out'));
    });

    test('bad --dpi -> bad_input (exit 3)', () async {
      final path = p.join(tmp.path, 'img.jpg');
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend().writeGps(path, latitude: 1, longitude: 1);

      final code = await run([
        '--json',
        'map',
        '-p',
        tmp.path,
        '-o',
        p.join(tmp.path, 'out.png'),
        '--dpi',
        '0',
      ]);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['message'], contains('--dpi'));
    });
  });
}
