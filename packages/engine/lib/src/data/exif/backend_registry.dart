import '../../domain/options.dart';
import '../photo_formats.dart';
import '../ports/process_runner.dart';
import 'exif_backend.dart';
import 'exiftool_backend.dart';
import 'jpeg_exif_backend.dart';
import 'png_exif_backend.dart';
import 'xmp_sidecar_backend.dart';

/// Chooses the right [ExifBackend] for a file, honouring [RawMode] and which
/// external tools are present.
///
/// Reading and writing can resolve to different backends: a RAW file is *read*
/// via exiftool (only it understands Fuji/Canon containers) but may be *written*
/// via an XMP sidecar when exiftool is absent or the user picked sidecar mode.
class BackendRegistry {
  /// Builds a registry.
  ///
  /// [exiftoolAvailable] gates RAW-embed and HEIC support; when false those
  /// fall back to sidecars (RAW) or become unsupported (HEIC).
  BackendRegistry({
    required ProcessRunner runner,
    this.rawMode = RawMode.auto,
    this.exiftoolAvailable = true,
  }) : _exiftool = ExiftoolBackend(runner),
       _jpeg = const JpegExifBackend(),
       _png = const PngExifBackend(),
       _sidecar = XmpSidecarBackend();

  /// How RAW GPS is written.
  final RawMode rawMode;

  /// Whether the exiftool binary is usable.
  final bool exiftoolAvailable;

  final ExiftoolBackend _exiftool;
  final JpegExifBackend _jpeg;
  final PngExifBackend _png;
  final XmpSidecarBackend _sidecar;

  /// The backend used to read metadata from [path], or null if unreadable
  /// (e.g. a RAW or HEIC file with no exiftool available).
  ExifBackend? readerFor(String path) {
    final ext = PhotoFormats.extOf(path);
    if (PhotoFormats.jpeg.contains(ext)) return _jpeg;
    if (PhotoFormats.png.contains(ext)) return _png;
    if (PhotoFormats.heic.contains(ext) || PhotoFormats.webp.contains(ext)) {
      return exiftoolAvailable ? _exiftool : null;
    }
    if (PhotoFormats.raw.contains(ext)) {
      // exiftool reads the embedded timestamp; the sidecar backend only knows
      // whether a sidecar already exists. Prefer exiftool when present.
      return exiftoolAvailable ? _exiftool : _sidecar;
    }
    return null;
  }

  /// The backend used to write GPS into [path], or null when no strategy is
  /// available (e.g. HEIC or RAW-embed requested without exiftool).
  ExifBackend? writerFor(String path) {
    final ext = PhotoFormats.extOf(path);
    if (PhotoFormats.jpeg.contains(ext)) return _jpeg;
    if (PhotoFormats.png.contains(ext)) return _png;
    if (PhotoFormats.heic.contains(ext) || PhotoFormats.webp.contains(ext)) {
      return exiftoolAvailable ? _exiftool : null;
    }
    if (PhotoFormats.raw.contains(ext)) {
      return switch (rawMode) {
        RawMode.sidecar => _sidecar,
        RawMode.embed => exiftoolAvailable ? _exiftool : null,
        RawMode.auto => exiftoolAvailable ? _exiftool : _sidecar,
      };
    }
    return null;
  }

  /// Whether a RAW write will land in a sidecar (vs embedded) for [path].
  bool writesSidecar(String path) =>
      PhotoFormats.isRaw(path) && identical(writerFor(path), _sidecar);
}
