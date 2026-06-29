import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda/src/explore/timeline_filter.dart';
import 'package:stunda_engine/stunda_engine.dart';

ExplorePhoto _p(String path, {DateTime? date}) => ExplorePhoto(
  path: path,
  latitude: 0,
  longitude: 0,
  meta: date == null ? null : FileMeta(path: path, date: date),
);

DateTime _d(int y, [int m = 1, int day = 1, int h = 0]) =>
    DateTime(y, m, day, h);

void main() {
  group('dateSpanOf', () {
    test('returns null for no photos', () {
      expect(dateSpanOf(const []), isNull);
    });

    test('returns null when no photo carries a date', () {
      expect(dateSpanOf([_p('/a'), _p('/b')]), isNull);
    });

    test('a single dated photo yields a zero-width span', () {
      final span = dateSpanOf([_p('/a', date: _d(2020, 5, 1))]);
      expect(span!.start, _d(2020, 5, 1));
      expect(span.end, _d(2020, 5, 1));
    });

    test('spans the earliest and latest dates, ignoring nulls', () {
      final span = dateSpanOf([
        _p('/mid', date: _d(2021, 6, 15)),
        _p('/null'), // no date — ignored
        _p('/late', date: _d(2022, 1, 1)),
        _p('/early', date: _d(2020, 1, 1)),
      ]);
      expect(span!.start, _d(2020, 1, 1));
      expect(span.end, _d(2022, 1, 1));
    });
  });

  group('filterPhotosByDateRange', () {
    test('keeps dated photos within the range, inclusive on both ends', () {
      final photos = [
        _p('/before', date: _d(2020, 1, 1)),
        _p('/start', date: _d(2021, 1, 1)),
        _p('/inside', date: _d(2021, 6, 1)),
        _p('/end', date: _d(2021, 12, 31)),
        _p('/after', date: _d(2022, 6, 1)),
      ];
      final kept = filterPhotosByDateRange(
        photos,
        start: _d(2021, 1, 1),
        end: _d(2021, 12, 31),
      );
      expect(kept.map((p) => p.path), ['/start', '/inside', '/end']);
    });

    test('always keeps null-dated photos regardless of range', () {
      final photos = [
        _p('/null1'),
        _p('/in', date: _d(2021, 6, 1)),
        _p('/null2'),
        _p('/out', date: _d(2030, 1, 1)),
      ];
      final kept = filterPhotosByDateRange(
        photos,
        start: _d(2021, 1, 1),
        end: _d(2021, 12, 31),
      );
      expect(kept.map((p) => p.path), ['/null1', '/in', '/null2']);
    });

    test('a zero-width range keeps only photos at that exact instant', () {
      final instant = _d(2021, 6, 1, 12);
      final photos = [
        _p('/exact', date: instant),
        _p('/other', date: _d(2021, 6, 1, 13)),
        _p('/null'),
      ];
      final kept = filterPhotosByDateRange(
        photos,
        start: instant,
        end: instant,
      );
      expect(kept.map((p) => p.path), ['/exact', '/null']);
    });

    test('preserves input order and is empty for empty input', () {
      expect(
        filterPhotosByDateRange(const [], start: _d(2020), end: _d(2021)),
        isEmpty,
      );
    });
  });

  group('slider value mapping', () {
    test('round-trips a DateTime through the slider value', () {
      final dt = _d(2021, 6, 15, 9);
      final value = dateTimeToSliderValue(dt);
      expect(value, dt.millisecondsSinceEpoch.toDouble());
      expect(sliderValueToDateTime(value), dt);
    });

    test('sliderValueToDateTime rounds a fractional millisecond value', () {
      final dt = _d(2021, 6, 15);
      final v = dateTimeToSliderValue(dt) + 0.4;
      expect(sliderValueToDateTime(v), dt);
    });
  });

  group('ExplorePhoto.date', () {
    test('reads through to the meta capture date, null without meta', () {
      expect(_p('/a', date: _d(2020, 3, 3)).date, _d(2020, 3, 3));
      expect(_p('/a').date, isNull);
    });
  });
}
