import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

const _gpx = '''
<gpx><trk><trkseg>
<trkpt lat="42.5" lon="18.1"><time>2026-06-22T12:00:00Z</time></trkpt>
</trkseg></trk></gpx>''';

const _kml = '''
<kml><Document><Placemark>
<Point><coordinates>18.2,42.6,0</coordinates></Point>
<TimeStamp><when>2026-06-22T13:00:00Z</when></TimeStamp>
</Placemark></Document></kml>''';

const _records =
    '{"locations":[{"latitudeE7":427000000,'
    '"longitudeE7":183000000,"timestamp":"2026-06-22T14:00:00Z"}]}';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pool'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, String content) {
    final path = p.join(tmp.path, name);
    File(path).writeAsStringSync(content);
    return path;
  }

  test('pools gpx and kml into track, sorted ascending', () {
    final gpx = write('a.gpx', _gpx);
    final kml = write('a.kml', _kml);
    final pool = poolSources(gpxFiles: [gpx], kmlFiles: [kml]);

    expect(pool.track.length, 2);
    expect(pool.track.first.latitude, closeTo(42.5, 1e-6));
    expect(pool.track[1].latitude, closeTo(42.6, 1e-6));
    expect(pool.track.first.time.isBefore(pool.track[1].time), isTrue);
    expect(pool.google, isEmpty);
  });

  test('pools google json separately', () {
    final json = write('Records.json', _records);
    final pool = poolSources(googleJsonFiles: [json]);
    expect(pool.google.length, 1);
    expect(pool.google.single.latitude, closeTo(42.7, 1e-6));
    expect(pool.track, isEmpty);
  });

  test('skips unreadable and malformed files without throwing', () {
    final missing = p.join(tmp.path, 'nope.gpx');
    final bad = write('bad.gpx', 'not xml <<<');
    final pool = poolSources(gpxFiles: [missing, bad]);
    expect(pool.track, isEmpty);
  });

  test(
    'poolFromScan wires a scan result through, regardless of layout',
    () async {
      // Sources scattered across subfolders, mixed with photos and junk.
      Directory(p.join(tmp.path, 'sub')).createSync();
      write(p.join('sub', 't.gpx'), _gpx);
      write('places.kml', _kml);
      write('History.json', _records);
      write('app.json', '{"foo":1}'); // not Google
      File(p.join(tmp.path, 'pic.jpg')).writeAsStringSync('x');

      final scan = await FolderScanner()
          .scan([tmp.path])
          .toList()
          .then((e) => e.whereType<ScanDoneEvent>().single.result);

      expect(scan.gpxCount, 1);
      expect(scan.kmlCount, 1);
      expect(scan.googleCount, 1);

      final pool = poolFromScan(scan);
      expect(pool.track.length, 2, reason: 'gpx + kml');
      expect(pool.google.length, 1, reason: 'validated json only');
    },
  );
}
