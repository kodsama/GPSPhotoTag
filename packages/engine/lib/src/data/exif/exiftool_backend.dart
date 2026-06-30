import 'dart:convert';

import '../photo_formats.dart';
import '../ports/process_runner.dart';
import 'exif_backend.dart';
import 'exif_utils.dart';

/// An [ExifBackend] that shells out to `exiftool` for RAW, HEIC/HEIF, and
/// other formats that the in-process decoders cannot write.
///
/// Reads and writes happen in place on the given path; exiftool is invoked
/// through an injected [ProcessRunner] so the behaviour is fully testable.
class ExiftoolBackend implements ExifBackend {
  /// Creates a backend driven by [_runner].
  ///
  /// [extensions] overrides the default supported set (RAW + HEIC/HEIF +
  /// WebP); pass it lower-cased and without leading dots.
  ExiftoolBackend(this._runner, {Set<String>? extensions})
    : _extensions = extensions ?? {...PhotoFormats.raw, 'heic', 'heif', 'webp'};

  final ProcessRunner _runner;
  final Set<String> _extensions;

  @override
  bool supports(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return _extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  @override
  Future<PhotoMeta> read(String path) async {
    final result = await _runner.run('exiftool', [
      '-json',
      '-DateTimeOriginal',
      '-CreateDate',
      '-OffsetTimeOriginal',
      '-GPSLatitude',
      '-GPSLongitude',
      path,
    ]);
    if (!result.ok) return const PhotoMeta();

    final decoded = jsonDecode(result.stdout);
    if (decoded is! List || decoded.isEmpty) return const PhotoMeta();
    final obj = decoded.first;
    if (obj is! Map) return const PhotoMeta();

    final capture =
        parseExifDateTimeNaive(obj['DateTimeOriginal']) ??
        parseExifDateTimeNaive(obj['CreateDate']);
    final offset = _parseOffset(obj['OffsetTimeOriginal']);
    final lat = obj['GPSLatitude'];
    final hasGps = lat != null && lat.toString().isNotEmpty;

    return PhotoMeta(captureNaive: capture, offset: offset, hasGps: hasGps);
  }

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async {
    final args = <String>[
      '-overwrite_original',
      '-GPSLatitude=${latitude.abs()}',
      '-GPSLatitudeRef=${latitude < 0 ? 'S' : 'N'}',
      '-GPSLongitude=${longitude.abs()}',
      '-GPSLongitudeRef=${longitude < 0 ? 'W' : 'E'}',
      '-GPSMapDatum=WGS-84',
    ];
    if (dateTimeOriginal != null) {
      final stamp = formatExifDateTime(dateTimeOriginal);
      args
        ..add('-DateTimeOriginal=$stamp')
        ..add('-CreateDate=$stamp');
    }
    args.add(path);

    final result = await _runner.run('exiftool', args);
    if (!result.ok) {
      throw StateError(
        'exiftool failed (${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Parses an EXIF offset string such as `"+02:00"` or `"-05:00"`.
  static Duration? _parseOffset(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    final match = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(text);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final hours = int.parse(match.group(2)!);
    final minutes = int.parse(match.group(3)!);
    return Duration(hours: sign * hours, minutes: sign * minutes);
  }
}
