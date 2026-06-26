import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

const _gpx = '''
<?xml version="1.0"?>
<gpx version="1.1">
  <trk><trkseg>
    <trkpt lat="42.0" lon="18.0"><time>2026-06-22T12:00:00Z</time></trkpt>
    <trkpt lat="42.2" lon="18.2"><time>2026-06-22T12:10:00Z</time></trkpt>
  </trkseg></trk>
  <wpt lat="1.0" lon="1.0"></wpt>
</gpx>
''';

void main() {
  group('parseGpx', () {
    test('reads trackpoints, skips timeless waypoints, sorts by time', () {
      final pts = parseGpx(_gpx);
      expect(pts, hasLength(2));
      expect(pts.first.time, DateTime.utc(2026, 6, 22, 12));
      expect(pts.last.latitude, 42.2);
      // Already ascending.
      expect(pts.first.time.isBefore(pts.last.time), isTrue);
    });

    test('rejects malformed XML', () {
      expect(() => parseGpx('<gpx'), throwsFormatException);
    });
  });

  group('Locator', () {
    final pts = parseGpx(_gpx);
    final loc = Locator(gpx: pts);

    test('exact match within tolerance', () {
      final r = loc.locate(
        DateTime.utc(2026, 6, 22, 12),
        const Duration(seconds: 300),
      );
      expect(r, isNotNull);
      expect(r!.method, GpsMethod.exact);
      expect(r.latitude, 42.0);
      expect(r.source, GpsSource.gpx);
    });

    test('interpolates the midpoint', () {
      final r = loc.locate(
        DateTime.utc(2026, 6, 22, 12, 5),
        const Duration(seconds: 600),
      );
      expect(r!.method, GpsMethod.interpolated);
      expect(r.latitude, closeTo(42.1, 1e-9));
      expect(r.longitude, closeTo(18.1, 1e-9));
    });

    test('returns null beyond the threshold', () {
      final r = loc.locate(
        DateTime.utc(2026, 6, 22, 20),
        const Duration(seconds: 300),
      );
      expect(r, isNull);
    });

    test('nearest fix when only one neighbour is in range', () {
      // Photo at 12:09:00 sits between 12:00 and 12:10. With a 90s threshold
      // only the 12:10 point qualifies -> nearest fix, interpolated provenance.
      final r = loc.locate(
        DateTime.utc(2026, 6, 22, 12, 9),
        const Duration(seconds: 90),
      );
      expect(r, isNotNull);
      expect(r!.method, GpsMethod.interpolated);
      // It snapped to the in-range neighbour (12:10 -> 42.2), not interpolated.
      expect(r.latitude, 42.2);
    });

    test('nearest fix uses the before-neighbour when only it is in range', () {
      // Photo at 12:01:00; with a 90s threshold only the 12:00 point qualifies.
      final r = loc.locate(
        DateTime.utc(2026, 6, 22, 12, 1),
        const Duration(seconds: 90),
      );
      expect(r!.method, GpsMethod.interpolated);
      expect(r.latitude, 42.0);
    });

    test('prefers GPX over Google when both cover the time', () {
      final google = [
        TimedPoint(
          latitude: 0,
          longitude: 0,
          time: DateTime.utc(2026, 6, 22, 12),
        ),
      ];
      final r = Locator(
        gpx: pts,
        google: google,
      ).locate(DateTime.utc(2026, 6, 22, 12), const Duration(seconds: 300));
      expect(r!.source, GpsSource.gpx);
    });

    test('falls back to Google when GPX misses', () {
      final google = [
        TimedPoint(
          latitude: 9,
          longitude: 9,
          time: DateTime.utc(2026, 6, 22, 20),
        ),
      ];
      final r = Locator(
        gpx: pts,
        google: google,
      ).locate(DateTime.utc(2026, 6, 22, 20), const Duration(seconds: 60));
      expect(r!.source, GpsSource.google);
      expect(r.latitude, 9);
    });
  });
}
