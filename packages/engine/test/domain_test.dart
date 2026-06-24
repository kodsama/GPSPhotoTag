import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:test/test.dart';

void main() {
  group('TimedPoint', () {
    test('coerces time to UTC and orders by time', () {
      final a = TimedPoint(
        latitude: 1,
        longitude: 2,
        time: DateTime.utc(2026, 6, 22, 12),
      );
      final b = TimedPoint(
        latitude: 3,
        longitude: 4,
        time: DateTime.utc(2026, 6, 22, 13),
      );
      expect(a.time.isUtc, isTrue);
      expect(a.compareTo(b), lessThan(0));
      expect([b, a]..sort(), [a, b]);
    });

    test('value equality', () {
      final t = DateTime.utc(2026, 1, 1);
      expect(
        TimedPoint(latitude: 1, longitude: 2, time: t),
        equals(TimedPoint(latitude: 1, longitude: 2, time: t)),
      );
    });
  });

  group('LocationResult', () {
    test('provenance combines source and method', () {
      const r = LocationResult(
        latitude: 42.7,
        longitude: 18.3,
        source: GpsSource.gpx,
        method: GpsMethod.interpolated,
      );
      expect(r.provenance, 'gpx/interpolated');
    });
  });

  group('PhotoRow.toJson', () {
    test('includes coordinates only when a location is present', () {
      const tagged = PhotoRow(
        path: '/a/DSCF1.JPG',
        status: PhotoStatus.tagged,
        location: LocationResult(
          latitude: 42.5,
          longitude: 18.1,
          source: GpsSource.gpx,
          method: GpsMethod.exact,
        ),
      );
      final json = tagged.toJson();
      expect(json['status'], 'tagged');
      expect(json['lat'], 42.5);
      expect(json['source'], 'gpx/exact');

      const skipped = PhotoRow(path: '/a/b.JPG', status: PhotoStatus.noGps);
      expect(skipped.toJson().containsKey('lat'), isFalse);
    });
  });

  group('EngineEvent', () {
    test('events serialise with their discriminator', () {
      expect(const LogEvent('hi').toJson()['event'], 'log');
      expect(
        const ProgressEvent(done: 1, total: 4).toJson(),
        {'event': 'progress', 'done': 1, 'total': 4},
      );
      expect(const ProgressEvent(done: 1, total: 4).fraction, closeTo(0.25, 1e-9));
      expect(
        const DoneEvent({'tagged': 3, 'no_gps': 1}).total,
        4,
      );
    });

    test('exhaustive switch over the sealed hierarchy compiles', () {
      String describe(EngineEvent e) => switch (e) {
            LogEvent() => 'log',
            ProgressEvent() => 'progress',
            ItemEvent() => 'item',
            DoneEvent() => 'done',
            ErrorEvent() => 'error',
          };
      expect(describe(const LogEvent('x')), 'log');
      expect(describe(const ErrorEvent('boom')), 'error');
    });
  });
}
