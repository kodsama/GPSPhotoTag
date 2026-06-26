import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/services/map_service.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that returns a canned [ProcResult] for every call.
class FakeRunner implements ProcessRunner {
  FakeRunner(this.result);

  final ProcResult result;

  @override
  Future<ProcResult> run(String executable, List<String> args) async => result;
}

void main() {
  group('tile math', () {
    test('lon/lat 0,0 maps to the centre tile at any zoom', () {
      // At z=0 the world is one 512px tile; the equator/prime-meridian is mid.
      expect(lonToPixelX(0, 0), closeTo(256, 1e-6));
      expect(latToPixelY(0, 0), closeTo(256, 1e-6));
      // At z=1 the world is 2x2 tiles (1024px); centre is at 512px.
      expect(lonToPixelX(0, 1), closeTo(512, 1e-6));
      expect(latToPixelY(0, 1), closeTo(512, 1e-6));
    });

    test('longitude increases pixel X monotonically', () {
      expect(lonToPixelX(-180, 5) < lonToPixelX(0, 5), isTrue);
      expect(lonToPixelX(0, 5) < lonToPixelX(179, 5), isTrue);
    });

    test('northern latitudes give smaller pixel Y than southern', () {
      expect(latToPixelY(45, 8) < latToPixelY(0, 8), isTrue);
      expect(latToPixelY(0, 8) < latToPixelY(-45, 8), isTrue);
    });
  });

  group('zoom selection', () {
    const a = GeoPoint(43.700, 18.340, 'a');
    final tight = [a, const GeoPoint(43.701, 18.341, 'b')];
    final wide = [a, const GeoPoint(48.85, 2.35, 'c')]; // Sarajevo↔Paris.

    test('a tight bbox zooms in further than a wide bbox', () {
      expect(chooseZoom(tight, 1000), greaterThan(chooseZoom(wide, 1000)));
    });

    test('a single point uses the default close zoom', () {
      expect(chooseZoom([a], 1000), 15);
    });
  });

  group('render', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('map_service_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'renders a PNG offline and reports mapped count + basemap warning',
      () async {
        // Two tagged photos in Sarajevo, returned as exiftool -n JSON.
        const json = '''
[
  {"SourceFile":"/photos/DSCF0795.jpg","GPSLatitude":43.8563,"GPSLongitude":18.4131},
  {"SourceFile":"/photos/DSCF0796.jpg","GPSLatitude":43.8580,"GPSLongitude":18.4150}
]''';
        final runner = FakeRunner(const ProcResult(0, json, ''));
        // Every tile fetch 404s -> basemap-less render, no hard fail.
        final client = MockClient((_) async => http.Response('', 404));

        const dpi = 160;
        final canvas = (dpi * 5).clamp(600, 2400);
        final outPath = p.join(tmp.path, 'out.png');
        final service = MapService(runner: runner, client: client);

        final events = await service.render([
          '/photos/DSCF0795.jpg',
          '/photos/DSCF0796.jpg',
        ], MapOptions(outputPng: outPath, dpi: dpi)).toList();

        final done = events.whereType<DoneEvent>().single;
        expect(done.summary['mapped'], 2);

        final warned = events.whereType<LogEvent>().any(
          (e) => e.level == LogLevel.warning && e.message.contains('basemap'),
        );
        expect(warned, isTrue, reason: 'expected the offline basemap warning');

        final file = File(outPath);
        expect(file.existsSync(), isTrue);
        final decoded = img.decodePng(file.readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, canvas);
        expect(decoded.height, canvas);
      },
    );

    test('composites fetched tiles and logs the fetched count', () async {
      const json = '''
[
  {"SourceFile":"/photos/a.jpg","GPSLatitude":43.8563,"GPSLongitude":18.4131},
  {"SourceFile":"/photos/b.jpg","GPSLatitude":43.8580,"GPSLongitude":18.4150}
]''';
      final runner = FakeRunner(const ProcResult(0, json, ''));
      // Serve a real, decodable PNG tile for every fetch so the compositing and
      // fetched-count paths run.
      final tilePng = img.encodePng(
        img.Image(width: 512, height: 512)..clear(img.ColorRgb8(10, 20, 30)),
      );
      final client = MockClient((_) async => http.Response.bytes(tilePng, 200));
      final outPath = p.join(tmp.path, 'tiled.png');
      final service = MapService(runner: runner, client: client);

      final events = await service.render([
        '/photos/a.jpg',
        '/photos/b.jpg',
      ], MapOptions(outputPng: outPath, dpi: 160)).toList();

      // Fetched-count log emitted (not the offline warning).
      final fetchedLog = events.whereType<LogEvent>().firstWhere(
        (e) => e.message.contains('CARTO basemap tile'),
      );
      expect(fetchedLog.level, LogLevel.info);
      expect(events.whereType<DoneEvent>().single.summary['mapped'], 2);
      expect(File(outPath).existsSync(), isTrue);
    });

    test(
      'exiftool failure with empty stdout maps to missing_toolkit',
      () async {
        // Non-zero exit and empty stdout -> _readGps throws StateError, caught.
        final runner = FakeRunner(
          const ProcResult(1, '   ', 'exiftool: error'),
        );
        final service = MapService(
          runner: runner,
          client: MockClient((_) async => http.Response('', 404)),
        );

        final events = await service.render([
          '/photos/x.jpg',
        ], MapOptions(outputPng: p.join(tmp.path, 'x.png'))).toList();

        expect(events.whereType<ErrorEvent>().single.code, 'missing_toolkit');
      },
    );

    test('emits missing_toolkit when exiftool is unavailable', () async {
      final runner = FakeRunner(const ProcResult(0, '[]', ''));
      final service = MapService(runner: runner, exiftoolAvailable: false);

      final events = await service.render([
        '/photos/x.jpg',
      ], MapOptions(outputPng: p.join(tmp.path, 'x.png'))).toList();

      final err = events.whereType<ErrorEvent>().single;
      expect(err.code, 'missing_toolkit');
    });

    test('emits bad_input when no photo has GPS', () async {
      final runner = FakeRunner(
        const ProcResult(0, '[{"SourceFile":"/photos/x.jpg"}]', ''),
      );
      final service = MapService(
        runner: runner,
        client: MockClient((_) async => http.Response('', 404)),
      );

      final events = await service.render([
        '/photos/x.jpg',
      ], MapOptions(outputPng: p.join(tmp.path, 'x.png'))).toList();

      final err = events.whereType<ErrorEvent>().single;
      expect(err.code, 'bad_input');
    });
  });
}
