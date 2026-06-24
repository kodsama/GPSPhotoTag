import 'package:meta/meta.dart';

/// Metadata read from a photo, used to decide matching and skipping.
@immutable
class PhotoMeta {
  /// Creates a metadata record.
  const PhotoMeta({this.captureNaive, this.offset, this.hasGps = false});

  /// The naive (timezone-less) capture time from EXIF `DateTimeOriginal`.
  ///
  /// This is wall-clock time as written by the camera; the caller converts it
  /// to UTC using [offset] when present, or a configured fallback timezone.
  final DateTime? captureNaive;

  /// The UTC offset from EXIF `OffsetTimeOriginal`, when the camera wrote one.
  final Duration? offset;

  /// Whether the file already carries a GPS position (inline or via sidecar).
  final bool hasGps;

  /// A copy with selected fields replaced.
  PhotoMeta copyWith({DateTime? captureNaive, Duration? offset, bool? hasGps}) =>
      PhotoMeta(
        captureNaive: captureNaive ?? this.captureNaive,
        offset: offset ?? this.offset,
        hasGps: hasGps ?? this.hasGps,
      );
}

/// Reads capture metadata from, and writes GPS into, one family of photo files.
///
/// Backends operate **in place** on the path they are given; the tagger is
/// responsible for copying a file into an output directory first when the user
/// asked for non-destructive output. Sidecar-based backends may write a
/// companion file (e.g. `photo.raf.xmp`) rather than modifying [path].
abstract interface class ExifBackend {
  /// Whether this backend handles the file at [path] (by extension).
  bool supports(String path);

  /// Reads capture time, offset, and GPS-presence from [path].
  Future<PhotoMeta> read(String path);

  /// Writes [latitude]/[longitude] (WGS-84) into the file at [path].
  ///
  /// When [dateTimeOriginal] is provided it is also written (used by the
  /// date-fix `file` direction). Implementations preserve existing metadata
  /// wherever possible.
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  });
}
