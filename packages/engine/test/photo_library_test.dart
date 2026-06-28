import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('LibraryAsset', () {
    LibraryAsset asset({
      String id = 'a1',
      String filename = 'IMG_0042.HEIC',
      int width = 4032,
      int height = 3024,
      int byteSize = 2000000,
      DateTime? createdAt,
      double? latitude,
      double? longitude,
    }) => LibraryAsset(
      id: id,
      filename: filename,
      width: width,
      height: height,
      byteSize: byteSize,
      createdAt: createdAt,
      latitude: latitude,
      longitude: longitude,
    );

    test('ext is the lower-case extension without the dot', () {
      expect(asset(filename: 'IMG_0042.HEIC').ext, 'heic');
      expect(asset(filename: 'photo.JPG').ext, 'jpg');
      expect(asset(filename: 'a.b.Cr2').ext, 'cr2');
    });

    test('ext is empty when there is no usable extension', () {
      expect(asset(filename: 'noext').ext, '');
      expect(asset(filename: '.hidden').ext, '');
      expect(asset(filename: 'trailingdot.').ext, '');
    });

    test('hasGps is true only when both coordinates are present', () {
      expect(asset().hasGps, isFalse);
      expect(asset(latitude: 1.0).hasGps, isFalse);
      expect(asset(longitude: 2.0).hasGps, isFalse);
      expect(asset(latitude: 1.0, longitude: 2.0).hasGps, isTrue);
    });

    test('pixelArea multiplies the original dimensions', () {
      expect(asset(width: 100, height: 50).pixelArea, 5000);
    });

    test('toJson omits absent optionals and includes present ones', () {
      final bare = asset().toJson();
      expect(bare.containsKey('createdAt'), isFalse);
      expect(bare.containsKey('latitude'), isFalse);
      expect(bare.containsKey('longitude'), isFalse);
      expect(bare['id'], 'a1');
      expect(bare['filename'], 'IMG_0042.HEIC');
      expect(bare['width'], 4032);
      expect(bare['height'], 3024);
      expect(bare['byteSize'], 2000000);

      final full = asset(
        createdAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
        latitude: 59.33,
        longitude: 18.06,
      ).toJson();
      expect(full['createdAt'], '2024-01-02T03:04:05.000Z');
      expect(full['latitude'], 59.33);
      expect(full['longitude'], 18.06);
    });
  });
}
