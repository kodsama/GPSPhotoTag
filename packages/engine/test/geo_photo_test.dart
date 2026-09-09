import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/services/map_service.dart';
import 'package:test/test.dart';

/// Returns a canned exiftool `-json` payload for the GPS read.
class _FakeRunner implements ProcessRunner {
  _FakeRunner(this.stdout, {this.exitCode = 0});

  final String stdout;
  final int exitCode;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);
    return ProcResult(exitCode, stdout, exitCode == 0 ? '' : 'boom');
  }
}

void main() {
  test('GeoPhoto.toJson omits taken_at when the file has none', () {
    expect(const GeoPhoto(path: '/a.jpg', lat: 1.5, lon: -2.5).toJson(), {
      'path': '/a.jpg',
      'lat': 1.5,
      'lon': -2.5,
    });
  });

  test('GeoPhoto.toJson carries taken_at when present', () {
    expect(
      const GeoPhoto(
        path: '/a.jpg',
        lat: 1,
        lon: 2,
        takenAt: '2026:09:09 10:00:00',
      ).toJson()['taken_at'],
      '2026:09:09 10:00:00',
    );
  });

  test(
    'readGeotagged keeps the full path and drops photos with no GPS',
    () async {
      final runner = _FakeRunner('''
[
  {"SourceFile":"/lib/a.jpg","GPSLatitude":59.33,"GPSLongitude":18.07,
   "DateTimeOriginal":"2026:09:09 10:00:00"},
  {"SourceFile":"/lib/b.jpg"},
  {"SourceFile":"/lib/c.jpg","GPSLatitude":40.7,"GPSLongitude":-74.0}
]
''');

      final found = await MapService(runner: runner)
          .readGeotagged(['/lib/a.jpg', '/lib/b.jpg', '/lib/c.jpg']);

      expect(found.map((g) => g.path), ['/lib/a.jpg', '/lib/c.jpg']);
      expect(found.first.lat, closeTo(59.33, 1e-9));
      expect(found.first.takenAt, '2026:09:09 10:00:00');
      // The photo with no fix is omitted rather than reported at 0,0.
      expect(found.last.takenAt, isNull);
      // One batched call covers every path.
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single, contains('-DateTimeOriginal'));
    },
  );

  test('readGeotagged throws when exiftool fails with no output', () {
    expect(
      MapService(runner: _FakeRunner('', exitCode: 1))
          .readGeotagged(['/a.jpg']),
      throwsA(isA<StateError>()),
    );
  });

  test('render still reads its points through the shared path', () async {
    // Rendering with no geotagged photo must report bad_input, proving the
    // renderer consumes the same read as readGeotagged.
    final events = await MapService(
      runner: _FakeRunner('[{"SourceFile":"/a.jpg"}]'),
    ).render(['/a.jpg'], const MapOptions(outputPng: '/tmp/out.png')).toList();

    expect(events.whereType<ErrorEvent>().single.code, 'bad_input');
  });
}
