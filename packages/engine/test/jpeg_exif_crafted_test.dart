import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:stunda_engine/src/data/exif/exif_backend.dart';
import 'package:stunda_engine/src/data/exif/jpeg_exif_backend.dart';
import 'package:test/test.dart';

/// Wraps a hand-crafted little-endian [tiff] in a minimal JPEG: SOI, an Exif
/// APP1 segment carrying the TIFF, then SOS so the scanner stops cleanly.
Uint8List _jpegWithTiff(Uint8List tiff) {
  final body =
      (BytesBuilder()
            ..add(const [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
            ..add(tiff))
          .toBytes();
  final segLen = body.length + 2;
  return (BytesBuilder()
        ..add(const [0xFF, 0xD8]) // SOI
        ..add([0xFF, 0xE1, (segLen >> 8) & 0xFF, segLen & 0xFF]) // APP1
        ..add(body)
        ..add(const [0xFF, 0xDA])) // SOS: stop scanning.
      .toBytes();
}

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
void _u32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

void main() {
  const backend = JpegExifBackend();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('jpeg_crafted'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A camera/library is permitted to store the ExifIFD pointer as a SHORT
  // rather than a LONG; valueAsLong must still resolve the sub-IFD offset.
  test('reads an ExifIFD pointer stored as a SHORT-typed value', () async {
    const ifd0Off = 8;
    const exifIfdOff = 26; // after the 18-byte IFD0.
    final dtBytes = Uint8List.fromList('2021:07:04 13:37:05 '.codeUnits);

    final b = BytesBuilder()..add(const [0x49, 0x49]); // "II" little-endian.
    _u16(b, 0x002A);
    _u32(b, ifd0Off);
    // IFD0: one entry, the ExifIFD pointer as SHORT.
    _u16(b, 1);
    _u16(b, 0x8769); // ExifIFD tag.
    _u16(b, 3); // type SHORT.
    _u32(b, 1); // count.
    _u16(b, exifIfdOff); // SHORT value: offset to the Exif sub-IFD.
    _u16(b, 0); // value-field padding.
    _u32(b, 0); // next-IFD pointer.
    // Exif sub-IFD: one DateTimeOriginal entry with external ASCII data.
    const dtOff = exifIfdOff + 2 + 12 + 4;
    _u16(b, 1);
    _u16(b, 0x9003); // DateTimeOriginal.
    _u16(b, 2); // ASCII.
    _u32(b, dtBytes.length);
    _u32(b, dtOff);
    _u32(b, 0);
    b.add(dtBytes);

    final path = '${tmp.path}/short_ptr.jpg';
    File(path).writeAsBytesSync(_jpegWithTiff(b.toBytes()));

    final meta = await backend.read(path);
    expect(meta.captureNaive, DateTime(2021, 7, 4, 13, 37, 5));
  });

  // writeGps preserves every existing IFD0 tag verbatim, sizing each by its
  // EXIF type. A DOUBLE-typed (12) tag must be measured as 8 bytes per value.
  test('preserves a DOUBLE-typed IFD0 tag through writeGps', () async {
    const ifd0Off = 8;
    const doubleDataOff = 26;

    final b = BytesBuilder()..add(const [0x49, 0x49]);
    _u16(b, 0x002A);
    _u32(b, ifd0Off);
    _u16(b, 1);
    _u16(b, 0x9999); // private tag.
    _u16(b, 12); // type DOUBLE.
    _u32(b, 1); // count.
    _u32(b, doubleDataOff); // external 8-byte value.
    _u32(b, 0); // next IFD.
    b.add(Uint8List(8)..[0] = 0x42);

    final path = '${tmp.path}/double_tag.jpg';
    File(path).writeAsBytesSync(_jpegWithTiff(b.toBytes()));

    await backend.writeGps(path, latitude: 1.0, longitude: 2.0);

    final meta = await backend.read(path);
    expect(meta.hasGps, isTrue);
    expect(meta, isA<PhotoMeta>());
  });

  // OffsetTimeOriginal must be parsed into PhotoMeta.offset. img.encodeJpg does
  // not emit that tag, so we inject it with exiftool when available.
  test('read parses OffsetTimeOriginal into a UTC offset', () async {
    final path = '${tmp.path}/offset.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
    Process.runSync('exiftool', <String>[
      '-overwrite_original',
      '-DateTimeOriginal=2026:06:22 12:43:38',
      '-OffsetTimeOriginal=+02:00',
      path,
    ]);

    final meta = await backend.read(path);
    expect(meta.captureNaive, DateTime(2026, 6, 22, 12, 43, 38));
    expect(meta.offset, const Duration(hours: 2));
  }, skip: _exiftoolAvailable() ? false : 'exiftool not on PATH');

  test('read parses a negative OffsetTimeOriginal', () async {
    final path = '${tmp.path}/neg_offset.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
    Process.runSync('exiftool', <String>[
      '-overwrite_original',
      '-DateTimeOriginal=2026:06:22 12:43:38',
      '-OffsetTimeOriginal=-05:30',
      path,
    ]);

    final meta = await backend.read(path);
    expect(meta.offset, const Duration(hours: -5, minutes: -30));
  }, skip: _exiftoolAvailable() ? false : 'exiftool not on PATH');

  // A phone with location services off still writes a complete GPS block: an
  // empty latitude ref and zero-denominator rationals. Reading tag presence
  // alone called these already-tagged, so the tagger skipped every photo that
  // actually needed a coordinate.
  Uint8List emptyGpsTiff({
    required List<int> ref,
    required List<List<int>> dms,
  }) {
    const ifd0Off = 8;
    const gpsIfdOff = 26; // after the 18-byte IFD0.
    const latDataOff = 56; // after the 30-byte GPS IFD.

    final b = BytesBuilder()..add(const [0x49, 0x49]);
    _u16(b, 0x002A);
    _u32(b, ifd0Off);
    // IFD0: just the GPS IFD pointer.
    _u16(b, 1);
    _u16(b, 0x8825); // GPSInfo IFD.
    _u16(b, 4); // LONG.
    _u32(b, 1);
    _u32(b, gpsIfdOff);
    _u32(b, 0); // next IFD.
    // GPS IFD: latitude ref (inline ASCII) + latitude (external RATIONALs).
    _u16(b, 2);
    _u16(b, 0x0001); // GPSLatitudeRef.
    _u16(b, 2); // ASCII.
    _u32(b, 2);
    b.add(ref); // 4-byte inline value field.
    _u16(b, 0x0002); // GPSLatitude.
    _u16(b, 5); // RATIONAL.
    _u32(b, 3);
    _u32(b, latDataOff);
    _u32(b, 0); // next IFD.
    for (final r in dms) {
      _u32(b, r[0]);
      _u32(b, r[1]);
    }
    return b.toBytes();
  }

  test('an empty GPS block does not count as already tagged', () async {
    final path = '${tmp.path}/empty_gps.jpg';
    File(path).writeAsBytesSync(
      _jpegWithTiff(
        emptyGpsTiff(
          ref: const [0x00, 0x00, 0x00, 0x00], // ref present, no value.
          dms: const [
            [0, 0],
            [0, 0],
            [0, 0],
          ],
        ),
      ),
    );

    final meta = await backend.read(path);
    expect(meta.hasGps, isFalse);
  });

  test('a real coordinate still counts as already tagged', () async {
    final path = '${tmp.path}/real_gps.jpg';
    File(path).writeAsBytesSync(
      _jpegWithTiff(
        emptyGpsTiff(
          ref: const [0x4E, 0x00, 0x00, 0x00], // "N"
          dms: const [
            [55, 1],
            [36, 1],
            [3315, 100],
          ],
        ),
      ),
    );

    final meta = await backend.read(path);
    expect(meta.hasGps, isTrue);
  });
}

bool _exiftoolAvailable() {
  try {
    return Process.runSync('exiftool', <String>['-ver']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
