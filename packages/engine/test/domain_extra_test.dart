import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('LocationResult.toString', () {
    test('includes coordinates and provenance', () {
      const r = LocationResult(
        latitude: 42.5,
        longitude: 18.1,
        source: GpsSource.google,
        method: GpsMethod.exact,
      );
      expect(r.toString(), 'LocationResult(42.5, 18.1, google/exact)');
    });
  });

  group('PhotoRow.copyWith', () {
    const base = PhotoRow(path: '/a/b.jpg', status: PhotoStatus.noGps);

    test('replaces only the provided fields, keeps path', () {
      final ts = DateTime.utc(2026, 1, 2, 3);
      const loc = LocationResult(
        latitude: 1,
        longitude: 2,
        source: GpsSource.gpx,
        method: GpsMethod.interpolated,
      );
      final updated = base.copyWith(
        status: PhotoStatus.tagged,
        timestamp: ts,
        location: loc,
        note: 'done',
      );
      expect(updated.path, '/a/b.jpg');
      expect(updated.status, PhotoStatus.tagged);
      expect(updated.timestamp, ts);
      expect(updated.location, same(loc));
      expect(updated.note, 'done');
    });

    test('with no arguments preserves all fields', () {
      final copy = base.copyWith();
      expect(copy.status, PhotoStatus.noGps);
      expect(copy.timestamp, isNull);
      expect(copy.location, isNull);
      expect(copy.note, isNull);
    });
  });

  group('PhotoMeta.copyWith', () {
    test('overrides selected fields and preserves the rest', () {
      const base = PhotoMeta(hasGps: false);
      final dt = DateTime(2026, 5, 1, 10);
      final updated = base.copyWith(
        captureNaive: dt,
        offset: const Duration(hours: 2),
        hasGps: true,
      );
      expect(updated.captureNaive, dt);
      expect(updated.offset, const Duration(hours: 2));
      expect(updated.hasGps, isTrue);

      final unchanged = updated.copyWith();
      expect(unchanged.captureNaive, dt);
      expect(unchanged.hasGps, isTrue);
    });
  });

  group('EngineEvent toJson coverage', () {
    test('LogEvent serialises level and message', () {
      expect(const LogEvent('careful', level: LogLevel.warning).toJson(), {
        'event': 'log',
        'level': 'warning',
        'message': 'careful',
      });
    });

    test('ProgressEvent.fraction is 0 when total is 0', () {
      const e = ProgressEvent(done: 0, total: 0);
      expect(e.fraction, 0);
      expect(e.toJson(), {'event': 'progress', 'done': 0, 'total': 0});
    });

    test('ItemEvent merges the row JSON under the discriminator', () {
      const row = PhotoRow(path: '/x.jpg', status: PhotoStatus.noGps);
      final json = const ItemEvent(row).toJson();
      expect(json['event'], 'item');
      expect(json['path'], '/x.jpg');
      expect(json['status'], 'no_gps');
    });

    test('DoneEvent reports its summary and total', () {
      const e = DoneEvent({'tagged': 2, 'no_gps': 1});
      expect(e.total, 3);
      expect(e.toJson(), {
        'event': 'done',
        'summary': {'tagged': 2, 'no_gps': 1},
        'total': 3,
      });
    });

    test('ErrorEvent carries code and message', () {
      expect(const ErrorEvent('boom', code: 'bad_input').toJson(), {
        'event': 'error',
        'code': 'bad_input',
        'message': 'boom',
      });
      expect(const ErrorEvent('x').toJson()['code'], 'internal');
    });
  });

  group('TimedPoint extras', () {
    final t = DateTime.utc(2026, 1, 1, 12);
    final a = TimedPoint(latitude: 1, longitude: 2, time: t);

    test('toString shows coordinates and ISO time', () {
      expect(a.toString(), 'TimedPoint(1.0, 2.0 @ ${t.toIso8601String()})');
    });

    test('equal points share a hashCode', () {
      final b = TimedPoint(latitude: 1, longitude: 2, time: t);
      expect(a.hashCode, b.hashCode);
      expect(a, equals(b));
    });

    test('differing fields are unequal', () {
      expect(a == TimedPoint(latitude: 9, longitude: 2, time: t), isFalse);
      expect(a == Object(), isFalse);
    });
  });
}
