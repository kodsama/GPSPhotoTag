import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/explore/detail_selection.dart';
import 'package:stunda/src/explore/explore_model.dart';
import 'package:stunda_engine/stunda_engine.dart';

ExplorePhoto _p(String path, double lat, double lon, {FileMeta? meta}) =>
    ExplorePhoto(path: path, latitude: lat, longitude: lon, meta: meta);

void main() {
  group('ExplorePhoto.fromMeta', () {
    test('builds from a meta carrying coordinates', () {
      final ep = ExplorePhoto.fromMeta(
        const FileMeta(
          path: '/a.jpg',
          hasGps: true,
          latitude: 42.5,
          longitude: 18.1,
        ),
      );
      expect(ep, isNotNull);
      expect(ep!.path, '/a.jpg');
      expect(ep.position.latitude, 42.5);
      expect(ep.position.longitude, 18.1);
    });

    test('returns null when meta has no GPS', () {
      expect(ExplorePhoto.fromMeta(const FileMeta(path: '/a.jpg')), isNull);
    });

    test('returns null when hasGps but coordinates missing', () {
      expect(
        ExplorePhoto.fromMeta(
          const FileMeta(path: '/a.jpg', hasGps: true, latitude: 42.5),
        ),
        isNull,
      );
    });
  });

  group('groupPhotosIntoPoints', () {
    test('merges photos that round to the same coordinate', () {
      final points = groupPhotosIntoPoints([
        _p('/a.jpg', 42.500001, 18.100001),
        _p('/b.jpg', 42.500002, 18.100002), // same to 5 dp
        _p('/c.jpg', 10.0, 20.0),
      ]);
      expect(points, hasLength(2));
      expect(points.first.count, 2);
      expect(points.first.photos.map((p) => p.path), ['/a.jpg', '/b.jpg']);
      expect(points.last.count, 1);
    });

    test('keeps points distinct when they differ at the precision', () {
      final points = groupPhotosIntoPoints([
        _p('/a.jpg', 42.50001, 18.10001),
        _p('/b.jpg', 42.50009, 18.10009),
      ]);
      expect(points, hasLength(2));
    });

    test('a coarser precision merges more aggressively', () {
      final points = groupPhotosIntoPoints([
        _p('/a.jpg', 42.51, 18.11),
        _p('/b.jpg', 42.52, 18.12),
      ], precision: 0);
      expect(points, hasLength(1));
      expect(points.single.count, 2);
    });

    test('preserves first-seen order and is empty for no input', () {
      expect(groupPhotosIntoPoints(const []), isEmpty);
      final points = groupPhotosIntoPoints([
        _p('/z.jpg', 1, 1),
        _p('/a.jpg', 2, 2),
      ]);
      expect(points.map((p) => p.photos.single.path), ['/z.jpg', '/a.jpg']);
    });
  });

  group('boundsOf', () {
    test('returns null for no points', () {
      expect(boundsOf(const []), isNull);
    });

    test('computes the min/max corners', () {
      final b = boundsOf([
        const MapPoint(latitude: 10, longitude: -5, photos: []),
        const MapPoint(latitude: 40, longitude: 30, photos: []),
        const MapPoint(latitude: 25, longitude: 12, photos: []),
      ]);
      expect(b!.southWest.latitude, 10);
      expect(b.southWest.longitude, -5);
      expect(b.northEast.latitude, 40);
      expect(b.northEast.longitude, 30);
    });

    test('a single point yields a zero-area box', () {
      final b = boundsOf([
        const MapPoint(latitude: 7, longitude: 8, photos: []),
      ]);
      expect(b!.southWest, b.northEast);
    });
  });

  group('isDecodableImage / fileTypeLabel', () {
    test('jpg/png/webp/gif/bmp are decodable', () {
      for (final ext in ['jpg', 'JPEG', 'png', 'webp', 'gif', 'bmp']) {
        expect(isDecodableImage('/x.$ext'), isTrue, reason: ext);
      }
    });

    test('heic/raw/unknown are not decodable', () {
      for (final ext in ['heic', 'raf', 'cr2', 'mov', '']) {
        expect(isDecodableImage('/x.$ext'), isFalse, reason: ext);
      }
    });

    test('label is the upper-case extension, or FILE when none', () {
      expect(fileTypeLabel('/a/photo.HeIc'), 'HEIC');
      expect(fileTypeLabel('/a/noext'), 'FILE');
    });
  });

  group('DetailSelection', () {
    MapPoint multi() => MapPoint(
      latitude: 1,
      longitude: 2,
      photos: [_p('/a.jpg', 1, 2), _p('/b.jpg', 1, 2), _p('/c.jpg', 1, 2)],
    );

    test('single photo: not multi, counter 1/1', () {
      final s = DetailSelection(
        point: MapPoint(
          latitude: 1,
          longitude: 2,
          photos: [_p('/a.jpg', 1, 2)],
        ),
      );
      expect(s.isMulti, isFalse);
      expect(s.total, 1);
      expect(s.counter, '1 / 1');
      expect(s.current.path, '/a.jpg');
    });

    test('multi photo: counter and next/prev wrap around', () {
      var s = DetailSelection(point: multi());
      expect(s.isMulti, isTrue);
      expect(s.counter, '1 / 3');

      s = s.next();
      expect(s.counter, '2 / 3');
      expect(s.current.path, '/b.jpg');

      s = s.next().next(); // index 3 -> wraps to 0
      expect(s.counter, '1 / 3');

      s = s.previous(); // wraps back to last
      expect(s.counter, '3 / 3');
      expect(s.current.path, '/c.jpg');
    });

    test('an out-of-range index is clamped', () {
      final s = DetailSelection(point: multi(), index: 99);
      expect(s.index, 2);
    });
  });

  group('shouldCloseOnZoom', () {
    test('closes when zoomed out past the open zoom (beyond hysteresis)', () {
      expect(shouldCloseOnZoom(16, 15.0), isTrue);
    });

    test('stays open when zooming in', () {
      expect(shouldCloseOnZoom(16, 18), isFalse);
    });

    test('stays open within the hysteresis band', () {
      expect(shouldCloseOnZoom(16, 15.6), isFalse); // 16-0.5=15.5 threshold
    });

    test('a custom hysteresis shifts the threshold', () {
      expect(shouldCloseOnZoom(16, 15.0, hysteresis: 2), isFalse);
      expect(shouldCloseOnZoom(16, 13.0, hysteresis: 2), isTrue);
    });
  });
}
