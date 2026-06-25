import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda_mcp/stunda_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('collectResult', () {
    test('drains a successful stream into a structured result map', () async {
      final row = PhotoRow(
        path: '/tmp/a.jpg',
        status: PhotoStatus.tagged,
        timestamp: DateTime.utc(2026, 6, 22, 12),
        location: const LocationResult(
          latitude: 42.5,
          longitude: 18.1,
          source: GpsSource.gpx,
          method: GpsMethod.exact,
        ),
        note: 'ok',
      );
      final stream = Stream<EngineEvent>.fromIterable([
        const LogEvent('starting', level: LogLevel.info),
        const LogEvent('careful', level: LogLevel.warning),
        const ProgressEvent(done: 1, total: 1),
        ItemEvent(row),
        const DoneEvent({'tagged': 1}),
      ]);

      final out = await collectResult(stream);

      expect(out['ok'], isTrue);
      expect(out['summary'], {'tagged': 1});
      expect(out['count'], 1);
      final items = out['items'] as List<Object?>;
      expect(items, hasLength(1));
      expect((items.single as Map<String, Object?>)['path'], '/tmp/a.jpg');
      expect((items.single as Map<String, Object?>)['status'], 'tagged');
      final logs = out['logs'] as List<Object?>;
      expect(logs, hasLength(2));
      expect((logs.first as Map<String, Object?>)['level'], 'info');
      expect((logs.last as Map<String, Object?>)['level'], 'warning');
      expect(out.containsKey('error'), isFalse);
      expect(out.containsKey('code'), isFalse);
    });

    test('reports ok=false with error and code on an ErrorEvent', () async {
      final stream = Stream<EngineEvent>.fromIterable([
        const LogEvent('debug line', level: LogLevel.debug),
        const ErrorEvent('boom', code: 'bad_input'),
      ]);

      final out = await collectResult(stream);

      expect(out['ok'], isFalse);
      expect(out['error'], 'boom');
      expect(out['code'], 'bad_input');
      expect(out['count'], 0);
      expect(out['items'], isEmpty);
      expect(out['logs'], hasLength(1));
    });

    test('omits logs when none were emitted', () async {
      final out = await collectResult(
        Stream<EngineEvent>.fromIterable([const DoneEvent({})]),
      );
      expect(out.containsKey('logs'), isFalse);
      expect(out['ok'], isTrue);
      expect(out['summary'], <String, int>{});
    });
  });

  group('loadSources', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('loadsources'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('parses GPX and Google Records files, sorted by time', () {
      final gpxPath = '${tmp.path}/track.gpx';
      // Two points written out of order; loadSources must sort ascending.
      File(gpxPath).writeAsStringSync('''
<gpx version="1.1">
  <trk><trkseg>
    <trkpt lat="42.7" lon="18.3"><time>2026-06-22T12:00:00Z</time></trkpt>
    <trkpt lat="42.6" lon="18.2"><time>2026-06-22T11:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>''');

      final recordsPath = '${tmp.path}/Records.json';
      File(recordsPath).writeAsStringSync('''
{"locations":[
  {"latitudeE7":427077000,"longitudeE7":183441000,
   "timestamp":"2026-06-22T13:00:00Z"},
  {"latitudeE7":426000000,"longitudeE7":182000000,
   "timestamp":"2026-06-22T10:00:00Z"}
]}''');

      final sources = loadSources([gpxPath], [recordsPath]);

      expect(sources.gpx, hasLength(2));
      expect(sources.gpx.first.time.isBefore(sources.gpx.last.time), isTrue);
      expect(sources.gpx.first.latitude, closeTo(42.6, 1e-9));

      expect(sources.google, hasLength(2));
      expect(
        sources.google.first.time.isBefore(sources.google.last.time),
        isTrue,
      );
      expect(sources.google.last.latitude, closeTo(42.7077, 1e-9));
    });

    test('returns empty lists when no inputs are given', () {
      final sources = loadSources(const [], const []);
      expect(sources.gpx, isEmpty);
      expect(sources.google, isEmpty);
    });
  });
}
