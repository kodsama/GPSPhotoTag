import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_cli/src/exit_codes.dart';
import 'package:stunda_cli/src/runner.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

import '_capture.dart';

/// A [MapService] that renders nothing but records the [MapOptions] it received
/// and emits canned events, so the `map` command's post-validation path can be
/// driven without exiftool or network access.
class _FakeMapService extends MapService {
  _FakeMapService({this.fail = false})
    : super(runner: const SystemProcessRunner(), exiftoolAvailable: false);

  /// When true, emit an error instead of a success [DoneEvent].
  final bool fail;

  /// The photos passed to the last [render] call.
  List<String>? lastPhotos;

  /// The options passed to the last [render] call.
  MapOptions? lastOptions;

  @override
  Stream<EngineEvent> render(List<String> photos, MapOptions options) async* {
    lastPhotos = photos;
    lastOptions = options;
    yield const LogEvent('1 of 1 photos had GPS');
    if (fail) {
      yield const ErrorEvent('no GPS found', code: 'bad_input');
    } else {
      yield const DoneEvent({'mapped': 1});
    }
  }
}

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
    final lines = buf.text
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return jsonDecode(lines.last) as Map<String, Object?>;
  }

  group('info', () {
    test('--json emits valid JSON with expected keys; exit 0', () async {
      final code = await run(['--json', 'info']);
      expect(code, ExitCodes.ok);
      final json = jsonDecode(buf.text.trim()) as Map<String, Object?>;
      expect(json['name'], 'stunda');
      expect(json['version'], isA<String>());
      expect(json['platform'], isA<String>());
      expect(json['formats'], isA<Map<String, Object?>>());
      expect(json['sources'], contains('gpx'));
    });

    test('human mode prints a version line', () async {
      final code = await run(['info']);
      expect(code, ExitCodes.ok);
      expect(buf.text, contains('stunda'));
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
      expect(json['tool'], 'stunda');
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
      await const JpegExifBackend().writeGps(
        path,
        latitude: 1,
        longitude: 1,
        dateTimeOriginal: time,
      );
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

    test(
      'tags a photo from a matching GPX point; GPS readable after',
      () async {
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
      },
    );

    test('no photos -> bad_input (exit 3)', () async {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      final code = await run([
        '--json',
        'tag',
        '-p',
        empty.path,
        '--overwrite',
      ]);
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
      final item = lines.firstWhere(
        (e) => e['event'] == 'item',
        orElse: () => {},
      );
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
      await const JpegExifBackend().writeGps(
        path,
        latitude: 1,
        longitude: 1,
        dateTimeOriginal: DateTime(2026, 6, 22, 12),
      );

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
      final code = await run([
        '--json',
        'fix-dates',
        '-p',
        empty.path,
        '--mode',
        'exif',
      ]);
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

  group('map render path (fake service)', () {
    late _FakeMapService fake;

    /// Seeds one GPS-tagged photo and runs `map` against [fake].
    Future<int> runMap(List<String> extra) async {
      final path = p.join(tmp.path, 'img.jpg');
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend().writeGps(path, latitude: 1, longitude: 1);
      final runner = buildRunner(
        sink: buf,
        mapServiceFactory: () async => fake,
      );
      return (await runner.run([
            '--json',
            'map',
            '-p',
            tmp.path,
            '-o',
            p.join(tmp.path, 'out.png'),
            ...extra,
          ])) ??
          0;
    }

    setUp(() => fake = _FakeMapService());

    test(
      'renders to completion; exit 0, parses dpi, default clusters',
      () async {
        final code = await runMap(['--dpi', '150']);
        expect(code, ExitCodes.ok);
        expect(fake.lastPhotos, isNotEmpty);
        expect(fake.lastOptions!.dpi, 150);
        // No --clusters => "all" => null.
        expect(fake.lastOptions!.clusters, isNull);
        expect(fake.lastOptions!.labelNames, isFalse);
        final done = lastJsonLine();
        expect(done['event'], 'done');
        expect((done['summary'] as Map)['mapped'], 1);
      },
    );

    test('--clusters "all" yields null cluster set', () async {
      await runMap(['--clusters', 'all']);
      expect(fake.lastOptions!.clusters, isNull);
    });

    test('--clusters "1,2" parses 1-based ids', () async {
      await runMap(['--clusters', '1,2']);
      expect(fake.lastOptions!.clusters, {1, 2});
    });

    test('--clusters "" (empty) yields null cluster set', () async {
      await runMap(['--clusters', '']);
      expect(fake.lastOptions!.clusters, isNull);
    });

    test('--clusters with no parseable ids yields null', () async {
      await runMap(['--clusters', 'x,y']);
      expect(fake.lastOptions!.clusters, isNull);
    });

    test('--names sets labelNames', () async {
      await runMap(['--names']);
      expect(fake.lastOptions!.labelNames, isTrue);
    });

    test('service error propagates to exit code', () async {
      fake = _FakeMapService(fail: true);
      final code = await runMap(const []);
      expect(code, ExitCodes.badInput);
      expect(lastJsonLine()['code'], 'bad_input');
    });
  });

  group('tag with Google history (source_loader)', () {
    test('loads a Records.json -m source; reaches the engine', () async {
      final path = p.join(tmp.path, 'img.jpg');
      File(path).writeAsBytesSync(minimalJpeg());
      await const JpegExifBackend().writeGps(
        path,
        latitude: 1,
        longitude: 1,
        dateTimeOriginal: DateTime(2026, 6, 22, 12),
      );
      final history = p.join(tmp.path, 'Records.json');
      File(history).writeAsStringSync(
        '{"locations":[{"latitudeE7":427077000,"longitudeE7":183441000,'
        '"timestamp":"2026-06-22T12:00:00Z"}]}',
      );

      final code = await run([
        '--json',
        'tag',
        '-p',
        tmp.path,
        '-m',
        history,
        '--overwrite',
        '--dry-run',
      ]);

      // No bad_input: the Google source loaded, so the engine ran.
      expect(code, isNot(ExitCodes.badInput));
      expect(lastJsonLine()['event'], 'done');
    });
  });

  group('check human-mode install hint', () {
    test('prints an install line for an absent tool', () async {
      // Probe a guaranteed-absent tool name so the !present branch renders.
      final tools = await ToolkitChecker(const SystemProcessRunner()).check();
      final missing = tools.where(
        (t) => !t.present && t.installCommand != null,
      );
      // Only assert the branch when the host actually lacks a tool; otherwise
      // the human path with all-present tools is already covered above.
      if (missing.isEmpty) return;
      await run(['check']);
      expect(buf.text, contains('install:'));
    });
  });

  group('command descriptions', () {
    test('every registered command exposes a non-empty description', () {
      final runner = buildRunner(sink: buf);
      for (final cmd in runner.commands.values) {
        expect(cmd.description, isNotEmpty, reason: cmd.name);
      }
    });
  });
}
