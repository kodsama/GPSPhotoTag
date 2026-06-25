import 'dart:convert';
import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that returns canned exiftool JSON and records the args of
/// every call so tests can assert chunking.
class _FakeRunner implements ProcessRunner {
  _FakeRunner(this._responses);

  /// One stdout payload per expected call, consumed in order.
  final List<String> _responses;
  final List<List<String>> calls = [];
  int _i = 0;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);
    final out = _i < _responses.length ? _responses[_i++] : '[]';
    return ProcResult(0, out, '');
  }
}

void main() {
  group('readImageMeta', () {
    test('parses width/height/date/gps from exiftool JSON', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {
            'SourceFile': '/lib/a.jpg',
            'ImageWidth': 4032,
            'ImageHeight': 3024,
            'DateTimeOriginal': '2023:07:15 12:30:45',
            'GPSLatitude': 42.5,
          },
          {
            'SourceFile': '/lib/b.jpg',
            'ImageWidth': 800,
            'ImageHeight': 600,
            'CreateDate': '2020:01:02 03:04:05',
          },
        ]),
      ]);

      final metas = await readImageMeta([
        '/lib/a.jpg',
        '/lib/b.jpg',
      ], runner: runner).toList();

      expect(metas, hasLength(2));
      final a = metas[0];
      expect(a.path, '/lib/a.jpg');
      expect(a.width, 4032);
      expect(a.height, 3024);
      expect(a.hasGps, isTrue);
      expect(a.date, DateTime(2023, 7, 15, 12, 30, 45));

      final b = metas[1];
      expect(b.hasGps, isFalse);
      // Falls back to CreateDate when DateTimeOriginal is absent.
      expect(b.date, DateTime(2020, 1, 2, 3, 4, 5));
    });

    test('yields a bare meta for paths exiftool omits', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {'SourceFile': '/lib/a.jpg', 'ImageWidth': 10, 'ImageHeight': 10},
        ]),
      ]);
      final metas = await readImageMeta([
        '/lib/a.jpg',
        '/lib/missing.jpg',
      ], runner: runner).toList();
      expect(metas, hasLength(2));
      expect(metas[1].path, '/lib/missing.jpg');
      expect(metas[1].width, isNull);
      expect(metas[1].hasGps, isFalse);
    });

    test('treats empty/whitespace GPSLatitude as no GPS', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {'SourceFile': '/lib/a.jpg', 'GPSLatitude': ''},
          {'SourceFile': '/lib/b.jpg', 'GPSLatitude': '  '},
        ]),
      ]);
      final metas = await readImageMeta([
        '/lib/a.jpg',
        '/lib/b.jpg',
      ], runner: runner).toList();
      expect(metas.every((m) => !m.hasGps), isTrue);
    });

    test('batches paths into chunks and yields progressively', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {'SourceFile': '/lib/0.jpg'},
          {'SourceFile': '/lib/1.jpg'},
        ]),
        jsonEncode([
          {'SourceFile': '/lib/2.jpg'},
        ]),
      ]);
      final paths = ['/lib/0.jpg', '/lib/1.jpg', '/lib/2.jpg'];
      final metas = await readImageMeta(
        paths,
        runner: runner,
        chunk: 2,
      ).toList();
      expect(metas.map((m) => m.path), paths);
      expect(runner.calls, hasLength(2));
      expect(runner.calls[0].last, '/lib/1.jpg');
      expect(runner.calls[1].last, '/lib/2.jpg');
    });

    test('tolerates non-JSON / empty exiftool output', () async {
      final runner = _FakeRunner(['', 'not json']);
      final m1 = await readImageMeta(
        ['/lib/a.jpg'],
        runner: runner,
        chunk: 1,
      ).toList();
      final m2 = await readImageMeta(
        ['/lib/b.jpg'],
        runner: runner,
        chunk: 1,
      ).toList();
      expect(m1.single.width, isNull);
      expect(m2.single.width, isNull);
    });

    test('parses a zone-suffixed exiftool date as naive', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {
            'SourceFile': '/lib/a.jpg',
            'DateTimeOriginal': '2023:07:15 12:30:45+02:00',
          },
        ]),
      ]);
      final meta = (await readImageMeta([
        '/lib/a.jpg',
      ], runner: runner).toList()).single;
      expect(meta.date, DateTime(2023, 7, 15, 12, 30, 45));
    });

    test('toJson round-trips the fields', () {
      const meta = FileMeta(path: '/p.jpg', hasGps: true, width: 4, height: 3);
      final json = meta.toJson();
      expect(json['path'], '/p.jpg');
      expect(json['hasGps'], isTrue);
      expect(json['width'], 4);
      expect(json['height'], 3);
      expect(json['date'], isNull);
    });
  });

  group('gpsFileMeta', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('file_meta_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads count and span from a GPX file', () {
      final path = '${tmp.path}/track.gpx';
      File(path).writeAsStringSync('''
<?xml version="1.0"?>
<gpx version="1.1" creator="test">
  <trk><trkseg>
    <trkpt lat="1.0" lon="2.0"><time>2023-05-01T10:00:00Z</time></trkpt>
    <trkpt lat="1.1" lon="2.1"><time>2023-05-01T11:00:00Z</time></trkpt>
    <trkpt lat="1.2" lon="2.2"><time>2023-05-01T09:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
''');
      final meta = gpsFileMeta(path);
      expect(meta.hasGps, isTrue);
      expect(meta.pointCount, 3);
      expect(meta.spanStart, DateTime.utc(2023, 5, 1, 9));
      expect(meta.spanEnd, DateTime.utc(2023, 5, 1, 11));
    });

    test('reads a KML file', () {
      final path = '${tmp.path}/t.kml';
      File(path).writeAsStringSync('''
<?xml version="1.0"?>
<kml><Document><Placemark>
  <TimeStamp><when>2022-03-04T05:06:07Z</when></TimeStamp>
  <Point><coordinates>18.1,42.5,0</coordinates></Point>
</Placemark></Document></kml>
''');
      final meta = gpsFileMeta(path);
      expect(meta.pointCount, 1);
      expect(meta.spanStart, DateTime.utc(2022, 3, 4, 5, 6, 7));
    });

    test('reads a Google Records JSON file', () {
      final path = '${tmp.path}/Records.json';
      File(path).writeAsStringSync(
        jsonEncode({
          'locations': [
            {
              'latitudeE7': 425000000,
              'longitudeE7': 181000000,
              'timestamp': '2021-12-31T23:00:00Z',
            },
          ],
        }),
      );
      final meta = gpsFileMeta(path);
      expect(meta.hasGps, isTrue);
      expect(meta.pointCount, 1);
    });

    test('returns zero points for a well-formed file with no points', () {
      final path = '${tmp.path}/empty.gpx';
      File(path).writeAsStringSync(
        '<?xml version="1.0"?><gpx version="1.1" creator="t"></gpx>',
      );
      final meta = gpsFileMeta(path);
      expect(meta.hasGps, isFalse);
      expect(meta.pointCount, 0);
    });

    test('returns a bare meta for a malformed file', () {
      final path = '${tmp.path}/bad.gpx';
      File(path).writeAsStringSync('not gpx at all');
      final meta = gpsFileMeta(path);
      expect(meta.hasGps, isFalse);
      expect(meta.pointCount, isNull);
    });

    test('returns a bare meta for a missing file', () {
      final meta = gpsFileMeta('${tmp.path}/nope.gpx');
      expect(meta.pointCount, isNull);
      expect(meta.hasGps, isFalse);
    });
  });
}
