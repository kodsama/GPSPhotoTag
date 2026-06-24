import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'exif_backend.dart';

/// tEXt keyword under which the serialized EXIF block is stored.
///
/// The `image` package's PNG encoder does not (yet) emit a native `eXIf`
/// chunk, so the EXIF TIFF block is base64-encoded into a textual chunk that
/// the encoder and decoder both round-trip faithfully.
const String _kExifTextKey = 'gpsphototag:exif';

/// An [ExifBackend] for PNG files, implemented entirely in-process with the
/// `image` package.
///
/// [writeGps] re-encodes the PNG (lossless for PNG); pixel data is preserved.
class PngExifBackend implements ExifBackend {
  /// Creates a PNG backend.
  const PngExifBackend();

  @override
  bool supports(String path) => path.toLowerCase().endsWith('.png');

  @override
  Future<PhotoMeta> read(String path) async {
    final image = img.decodePng(await File(path).readAsBytes());
    if (image == null) return const PhotoMeta();

    final exif = _exifOf(image);
    final capture = _parseCaptureNaive(
      exif.exifIfd['DateTimeOriginal']?.toString() ??
          exif.imageIfd['DateTimeOriginal']?.toString(),
    );
    return PhotoMeta(
      captureNaive: capture,
      hasGps: exif.gpsIfd.hasGPSLatitude,
    );
  }

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async {
    final file = File(path);
    final image = img.decodePng(await file.readAsBytes());
    if (image == null) {
      throw StateError('Not a decodable PNG: $path');
    }

    final exif = _exifOf(image);
    exif.gpsIfd
      ..setGpsLocation(latitude: latitude, longitude: longitude)
      ..gpsLatitudeRef = latitude < 0 ? 'S' : 'N'
      ..gpsLongitudeRef = longitude < 0 ? 'W' : 'E';
    if (dateTimeOriginal != null) {
      final stamp = _formatExifDateTime(dateTimeOriginal);
      exif.exifIfd['DateTimeOriginal'] = stamp;
      exif.imageIfd['DateTimeOriginal'] = stamp;
    }

    _embedExif(image, exif);
    await file.writeAsBytes(img.encodePng(image));
  }

  /// Returns the EXIF block for [image], rehydrating it from the tEXt chunk
  /// written by a previous [writeGps] when present.
  static img.ExifData _exifOf(img.Image image) {
    final stored = image.textData?[_kExifTextKey];
    if (stored == null) return image.exif;
    final bytes = base64.decode(stored);
    final exif = img.ExifData.fromInputBuffer(img.InputBuffer(bytes));
    image.exif = exif;
    return exif;
  }

  /// Serializes [exif] into a base64 tEXt chunk on [image].
  static void _embedExif(img.Image image, img.ExifData exif) {
    final out = img.OutputBuffer();
    exif.write(out);
    image.addTextData({_kExifTextKey: base64.encode(out.getBytes())});
  }

  /// Parses an EXIF `"YYYY:MM:DD HH:MM:SS"` string as a naive [DateTime].
  static DateTime? _parseCaptureNaive(String? raw) {
    if (raw == null || raw.length < 19) return null;
    final head = raw.substring(0, 19);
    final year = int.tryParse(head.substring(0, 4));
    final month = int.tryParse(head.substring(5, 7));
    final day = int.tryParse(head.substring(8, 10));
    final hour = int.tryParse(head.substring(11, 13));
    final minute = int.tryParse(head.substring(14, 16));
    final second = int.tryParse(head.substring(17, 19));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return DateTime(year, month, day, hour, minute, second);
  }

  /// Formats [dt] as the EXIF `"YYYY:MM:DD HH:MM:SS"` literal.
  static String _formatExifDateTime(DateTime dt) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year.toString().padLeft(4, '0')}:${p2(dt.month)}:'
        '${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}';
  }
}
