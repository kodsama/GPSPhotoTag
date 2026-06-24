import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PngExifBackend extra', () {
    const backend = PngExifBackend();
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('png_extra_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('read returns default PhotoMeta for an undecodable file', () async {
      final path = p.join(dir.path, 'broken.png');
      File(path).writeAsBytesSync([0, 1, 2, 3]);
      final meta = await backend.read(path);
      expect(meta.captureNaive, isNull);
      expect(meta.hasGps, isFalse);
    });

    test('writeGps throws StateError for an undecodable file', () {
      final path = p.join(dir.path, 'broken.png');
      File(path).writeAsBytesSync([0, 1, 2, 3]);
      expect(
        () => backend.writeGps(path, latitude: 1, longitude: 2),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'writeGps persists DateTimeOriginal and read parses it back',
      () async {
        final path = p.join(dir.path, 'dated.png');
        File(
          path,
        ).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));

        final dt = DateTime(2026, 6, 24, 9, 8, 7);
        await backend.writeGps(
          path,
          latitude: 12.5,
          longitude: -8.25,
          dateTimeOriginal: dt,
        );

        final meta = await backend.read(path);
        expect(meta.captureNaive, dt);
        expect(meta.hasGps, isTrue);
      },
    );

    test('second write rehydrates EXIF from the stored tEXt chunk', () async {
      final path = p.join(dir.path, 'twice.png');
      File(
        path,
      ).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));

      await backend.writeGps(
        path,
        latitude: 1,
        longitude: 2,
        dateTimeOriginal: DateTime(2025, 1, 1, 0, 0, 0),
      );
      // Second write must read back the previously embedded EXIF (the _exifOf
      // rehydration path) and keep the earlier DateTimeOriginal.
      await backend.writeGps(path, latitude: 3, longitude: 4);

      final meta = await backend.read(path);
      expect(meta.captureNaive, DateTime(2025, 1, 1, 0, 0, 0));
      expect(meta.hasGps, isTrue);
    });
  });
}
