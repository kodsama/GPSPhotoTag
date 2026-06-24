import 'dart:convert';

import '../ports/process_runner.dart';
import 'exif_backend.dart';

/// File extensions (without dot) for RAW formats handled by exiftool.
const Set<String> kRawExtensions = {
  'raf', 'nef', 'nrw', 'cr2', 'cr3', 'crw', 'arw', 'sr2', 'srf', 'dng',
  'rw2', 'orf', 'pef', 'ptx', 'raw', 'rwl', 'srw', 'x3f', 'iiq', '3fr', 'erf',
};

/// An [ExifBackend] that shells out to `exiftool` for RAW, HEIC/HEIF, and
/// other formats that the in-process decoders cannot write.
///
/// Reads and writes happen in place on the given path; exiftool is invoked
/// through an injected [ProcessRunner] so the behaviour is fully testable.
class ExiftoolBackend implements ExifBackend {
  /// Creates a backend driven by [_runner].
  ///
  /// [extensions] overrides the default supported set (RAW + HEIC/HEIF); pass
  /// it lower-cased and without leading dots.
  ExiftoolBackend(this._runner, {Set<String>? extensions})
      : _extensions = extensions ?? {...kRawExtensions, 'heic', 'heif'};

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

    final capture = _parseCaptureNaive(obj['DateTimeOriginal']) ??
        _parseCaptureNaive(obj['CreateDate']);
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
      final stamp = _formatExifDateTime(dateTimeOriginal);
      args
        ..add('-DateTimeOriginal=$stamp')
        ..add('-CreateDate=$stamp');
    }
    args.add(path);

    final result = await _runner.run('exiftool', args);
    if (!result.ok) {
      throw StateError('exiftool failed (${result.exitCode}): ${result.stderr}');
    }
  }

  /// Parses an exiftool date string (`"YYYY:MM:DD HH:MM:SS"`, optionally with
  /// sub-seconds or a trailing offset) as a naive [DateTime].
  static DateTime? _parseCaptureNaive(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString();
    if (text.length < 19) return null;
    final head = text.substring(0, 19);
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

  /// Formats [dt] as the EXIF `"YYYY:MM:DD HH:MM:SS"` literal.
  static String _formatExifDateTime(DateTime dt) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year.toString().padLeft(4, '0')}:${p2(dt.month)}:'
        '${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}';
  }
}
