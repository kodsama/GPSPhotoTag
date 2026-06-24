import 'dart:io';
import 'dart:typed_data';

import 'package:gpsphototag_engine/src/data/exif/jpeg_exif_backend.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  group('JpegExifBackend', () {
    const backend = JpegExifBackend();
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('jpeg_exif_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Writes a tiny synthetic JPEG and returns its path.
    String makeJpeg(String name) {
      final jpg = img.encodeJpg(img.Image(width: 4, height: 4));
      final path = '${tmp.path}/$name';
      File(path).writeAsBytesSync(jpg);
      return path;
    }

    test('supports recognises JPEG extensions case-insensitively', () {
      expect(backend.supports('a.JPG'), isTrue);
      expect(backend.supports('a.jpeg'), isTrue);
      expect(backend.supports('a.jpg'), isTrue);
      expect(backend.supports('a.png'), isFalse);
      expect(backend.supports('a.raf'), isFalse);
    });

    test('writeGps then read round-trips positive coordinates', () async {
      final path = makeJpeg('pos.jpg');
      await backend.writeGps(path, latitude: 42.7077, longitude: 18.3441);

      final meta = await backend.read(path);
      expect(meta.hasGps, isTrue);

      // The output must still decode as a JPEG.
      expect(img.decodeJpg(File(path).readAsBytesSync()), isNotNull);
    });

    test(
      'writeGps round-trips coordinates within rounding tolerance',
      () async {
        final path = makeJpeg('coords.jpg');
        const lat = 42.7077;
        const lon = 18.3441;
        await backend.writeGps(path, latitude: lat, longitude: lon);

        final (rlat, rlon) = _readGps(path);
        expect(rlat, closeTo(lat, 1e-3));
        expect(rlon, closeTo(lon, 1e-3));
      },
    );

    test('negative coordinates get S/W refs and round-trip sign', () async {
      final path = makeJpeg('neg.jpg');
      const lat = -33.8688;
      const lon = -70.6483;
      await backend.writeGps(path, latitude: lat, longitude: lon);

      final (rlat, rlon) = _readGps(path);
      expect(rlat, lessThan(0));
      expect(rlon, lessThan(0));
      expect(rlat, closeTo(lat, 1e-3));
      expect(rlon, closeTo(lon, 1e-3));
    });

    test('writeGps with dateTimeOriginal round-trips to the second', () async {
      final path = makeJpeg('dt.jpg');
      final dt = DateTime(2026, 6, 24, 13, 45, 30);
      await backend.writeGps(
        path,
        latitude: 1.0,
        longitude: 2.0,
        dateTimeOriginal: dt,
      );

      final meta = await backend.read(path);
      expect(meta.captureNaive, dt);
      expect(meta.hasGps, isTrue);
    });

    test('read on a JPEG without Exif returns empty PhotoMeta', () async {
      final path = makeJpeg('plain.jpg');
      final meta = await backend.read(path);
      expect(meta.hasGps, isFalse);
      expect(meta.captureNaive, isNull);
      expect(meta.offset, isNull);
    });

    test(
      'a second write preserves the previously written DateTimeOriginal',
      () async {
        final path = makeJpeg('preserve.jpg');
        final dt = DateTime(2025, 1, 2, 3, 4, 5);
        await backend.writeGps(
          path,
          latitude: 10.0,
          longitude: 20.0,
          dateTimeOriginal: dt,
        );
        // Second write without a date must keep the existing one.
        await backend.writeGps(path, latitude: -1.0, longitude: -2.0);

        final meta = await backend.read(path);
        expect(meta.captureNaive, dt);
        expect(img.decodeJpg(File(path).readAsBytesSync()), isNotNull);
      },
    );
  });

  // Integration regression for the external-data offset bug: when the source
  // JPEG already carries Exif sub-IFD tags stored OUTSIDE the 4-byte value
  // field (RATIONAL/SRATIONAL like FNumber, ExposureTime, ShutterSpeedValue),
  // the re-serialized TIFF must rewrite each preserved entry's value-offset to
  // its freshly-assigned position. Carrying over the old offset produces
  // "Invalid offset"/"Suspicious offset" warnings and makes exiftool refuse to
  // edit the file. `img.encodeJpg` never emits external-data tags, so this case
  // needs a real EXIF fixture built with exiftool.
  group('JpegExifBackend exiftool round-trip', () {
    const backend = JpegExifBackend();
    late Directory tmp;
    late String fixture;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('jpeg_exif_exiftool');
      fixture = '${tmp.path}/fuji.jpg';
      File(
        fixture,
      ).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
      // Inject rich EXIF including external-data (S)RATIONAL tags.
      Process.runSync('exiftool', <String>[
        '-overwrite_original',
        '-Make=FUJIFILM',
        '-Model=X-E5',
        '-FNumber=2.8',
        '-ExposureTime=1/250',
        '-ShutterSpeedValue=1/250',
        '-ISO=200',
        '-DateTimeOriginal=2026:06:22 12:43:38',
        fixture,
      ]);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test(
      'writeGps preserves external-data EXIF tags with valid offsets',
      () async {
        await backend.writeGps(fixture, latitude: 42.7077, longitude: 18.3441);

        // 1. The written TIFF must have valid value-offsets for every entry.
        final validate = Process.runSync('exiftool', <String>[
          '-warning',
          '-validate',
          fixture,
        ]);
        final validateOut = '${validate.stdout}${validate.stderr}';
        expect(
          validateOut,
          isNot(contains('Invalid offset')),
          reason: 'preserved Exif sub-IFD entries have corrupt value-offsets',
        );
        expect(
          validateOut,
          isNot(contains('Suspicious')),
          reason: 'preserved Exif sub-IFD entries have suspicious offsets',
        );

        // 2. exiftool must be able to write GPS into our file (exit code 0).
        final edit = Process.runSync('exiftool', <String>[
          '-overwrite_original',
          '-GPSLatitude=1',
          '-GPSLongitude=1',
          '-GPSLatitudeRef=N',
          '-GPSLongitudeRef=E',
          fixture,
        ]);
        expect(
          edit.exitCode,
          0,
          reason:
              'exiftool refused to edit our file: '
              '${edit.stdout}${edit.stderr}',
        );

        // 3. Our own reader still sees the preserved capture time and GPS.
        // (Re-read after exiftool's edit, which only touches GPS.)
        final meta = await backend.read(fixture);
        expect(meta.captureNaive, DateTime(2026, 6, 22, 12, 43, 38));
        expect(meta.hasGps, isTrue);
      },
      skip: _exiftoolAvailable() ? false : 'exiftool not on PATH',
    );
  });
}

/// Whether `exiftool` can be invoked in this environment.
bool _exiftoolAvailable() {
  try {
    return Process.runSync('exiftool', <String>['-ver']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Reads back the GPS latitude/longitude as signed decimal degrees.
///
/// Re-parses the JPEG's Exif GPS IFD directly so the test asserts on the exact
/// values written by the backend (deg/min/sec rationals + N/S/E/W refs).
(double, double) _readGps(String path) {
  final bytes = File(path).readAsBytesSync();
  // Locate Exif APP1.
  var i = 2;
  var tiffStart = -1;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) break;
    final marker = bytes[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
    final payloadStart = i + 4;
    if (marker == 0xE1 &&
        bytes[payloadStart] == 0x45 &&
        bytes[payloadStart + 1] == 0x78) {
      tiffStart = payloadStart + 6;
      break;
    }
    i = i + 2 + segLen;
  }
  expect(tiffStart, greaterThan(0), reason: 'no Exif APP1 found');

  final bd = ByteData.sublistView(bytes, tiffStart);
  final little = bd.getUint8(0) == 0x49;
  final e = little ? Endian.little : Endian.big;
  final ifd0 = bd.getUint32(4, e);

  var gpsOffset = -1;
  final count0 = bd.getUint16(ifd0, e);
  for (var n = 0; n < count0; n++) {
    final p = ifd0 + 2 + n * 12;
    if (bd.getUint16(p, e) == 0x8825) {
      gpsOffset = bd.getUint32(p + 8, e);
    }
  }
  expect(gpsOffset, greaterThan(0), reason: 'no GPS IFD pointer');

  var latRef = 'N';
  var lonRef = 'E';
  var lat = 0.0;
  var lon = 0.0;
  final gcount = bd.getUint16(gpsOffset, e);
  for (var n = 0; n < gcount; n++) {
    final p = gpsOffset + 2 + n * 12;
    final tag = bd.getUint16(p, e);
    switch (tag) {
      case 0x01:
        latRef = String.fromCharCode(bd.getUint8(p + 8));
      case 0x02:
        lat = _dms(bd, bd.getUint32(p + 8, e), e);
      case 0x03:
        lonRef = String.fromCharCode(bd.getUint8(p + 8));
      case 0x04:
        lon = _dms(bd, bd.getUint32(p + 8, e), e);
    }
  }
  if (latRef == 'S') lat = -lat;
  if (lonRef == 'W') lon = -lon;
  return (lat, lon);
}

/// Reads three RATIONALs at [offset] and combines into decimal degrees.
double _dms(ByteData bd, int offset, Endian e) {
  double r(int o) => bd.getUint32(o, e) / bd.getUint32(o + 4, e);
  final deg = r(offset);
  final min = r(offset + 8);
  final sec = r(offset + 16);
  return deg + min / 60.0 + sec / 3600.0;
}
