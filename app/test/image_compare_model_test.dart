import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/widgets/image_compare_model.dart';

import 'support/fakes.dart';

void main() {
  group('nextCompareMode', () {
    test('cycles vertical → horizontal → side-by-side → vertical', () {
      expect(
        nextCompareMode(CompareMode.verticalCurtain),
        CompareMode.horizontalCurtain,
      );
      expect(
        nextCompareMode(CompareMode.horizontalCurtain),
        CompareMode.sideBySide,
      );
      expect(
        nextCompareMode(CompareMode.sideBySide),
        CompareMode.verticalCurtain,
      );
    });
  });

  group('clampFraction', () {
    test('clamps to 0..1 and maps NaN to the centre', () {
      expect(clampFraction(-0.5), 0.0);
      expect(clampFraction(0.3), 0.3);
      expect(clampFraction(1.7), 1.0);
      expect(clampFraction(double.nan), 0.5);
    });
  });

  group('dragFraction', () {
    test('normalises the drag delta by the extent and clamps', () {
      expect(dragFraction(from: 0.0, start: 0, current: 100, extent: 200), 0.5);
      expect(
        dragFraction(from: 0.5, start: 0, current: 100, extent: 200),
        1.0, // 0.5 + 0.5, clamped at 1
      );
      expect(
        dragFraction(from: 0.5, start: 100, current: 0, extent: 200),
        0.0, // 0.5 - 0.5
      );
    });

    test('a non-positive extent is treated as no movement', () {
      expect(dragFraction(from: 0.4, start: 0, current: 99, extent: 0), 0.4);
    });
  });

  group('formatters', () {
    test('formatGps rounds to 5 decimals', () {
      expect(formatGps(42.123456, 18.987654), '42.12346, 18.98765');
    });

    test('formatCaptureTime pads the wall-clock fields', () {
      expect(formatCaptureTime(DateTime(2023, 7, 5, 9, 4)), '2023-07-05 09:04');
    });
  });

  group('exifSegments', () {
    test('null exif yields nothing', () {
      expect(exifSegments(null), isEmpty);
    });

    test('joins make+model and prefixes ISO / f-number', () {
      const exif = CuratedExif(
        path: '/a.jpg',
        make: 'FUJIFILM',
        model: 'X-T4',
        lens: 'XF35mmF1.4 R',
        iso: '200',
        exposure: '1/250',
        fNumber: '2.8',
        focalLength: '35.0 mm',
      );
      expect(exifSegments(exif), [
        'FUJIFILM X-T4',
        'XF35mmF1.4 R',
        'ISO 200',
        '1/250',
        'f/2.8',
        '35.0 mm',
      ]);
    });

    test('drops absent fields, keeps model-only camera', () {
      const exif = CuratedExif(path: '/a.jpg', model: 'X-T4');
      expect(exifSegments(exif), ['X-T4']);
    });
  });

  group('compareInfoSegments', () {
    test('builds name · dims · size · time and gates the GPS pin in', () {
      final segs = compareInfoSegments(
        name: 'shot.jpg',
        fileSize: 2 * 1024 * 1024,
        meta: FileMeta(
          path: '/lib/shot.jpg',
          hasGps: true,
          latitude: 42.5,
          longitude: 18.1,
          width: 4032,
          height: 3024,
          date: DateTime(2023, 1, 2, 3, 4),
        ),
        exif: const CuratedExif(path: '/lib/shot.jpg', iso: '400'),
        tr: enTr,
      );
      final texts = segs.map((s) => s.text).toList();
      expect(texts.first, 'shot.jpg');
      expect(texts, contains('4032 × 3024'));
      expect(texts, contains('2023-01-02 03:04'));
      expect(texts, contains('ISO 400'));
      // The GPS segment is present and flagged, carrying the coordinate.
      final gps = segs.firstWhere((s) => s.isGps);
      expect(gps.text, '42.50000, 18.10000');
    });

    test('omits the GPS pin when coordinates are absent', () {
      final segs = compareInfoSegments(
        name: 'a.jpg',
        meta: const FileMeta(path: '/a.jpg', width: 10, height: 10),
        tr: enTr,
      );
      expect(segs.any((s) => s.isGps), isFalse);
    });

    test('omits the GPS pin when hasGps is false even with coords', () {
      final segs = compareInfoSegments(
        name: 'a.jpg',
        meta: const FileMeta(path: '/a.jpg', latitude: 1, longitude: 2),
        tr: enTr,
      );
      expect(segs.any((s) => s.isGps), isFalse);
    });

    test('omits size when null', () {
      final segs = compareInfoSegments(name: 'a.jpg', tr: enTr);
      expect(segs.map((s) => s.text), ['a.jpg']);
    });
  });
}
