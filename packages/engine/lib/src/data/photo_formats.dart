import 'package:path/path.dart' as p;

/// Extension classification shared by the collectors and the backend registry.
///
/// All sets are lower-case without the leading dot.
abstract final class PhotoFormats {
  /// JPEG files (lossless inline GPS via the pure-Dart backend).
  static const jpeg = {'jpg', 'jpeg'};

  /// PNG files.
  static const png = {'png'};

  /// HEIC/HEIF files (handled via exiftool).
  static const heic = {'heic', 'heif'};

  /// WebP files (GPS read/written via exiftool, like HEIC).
  static const webp = {'webp'};

  /// RAW containers (XMP sidecar by default, or exiftool embed).
  static const raw = {
    'raf',
    'nef',
    'nrw',
    'cr2',
    'cr3',
    'crw',
    'arw',
    'sr2',
    'srf',
    'dng',
    'rw2',
    'orf',
    'pef',
    'ptx',
    'raw',
    'rwl',
    'srw',
    'x3f',
    'iiq',
    '3fr',
    'erf',
  };

  /// Extensions treated as JPG/HEIC "companions" when pruning RAW orphans.
  static const companion = {'jpg', 'jpeg', 'heic', 'heif'};

  /// Every taggable photo extension.
  static final Set<String> all = {...jpeg, ...png, ...heic, ...webp, ...raw};

  /// The lower-case extension of [path] without the dot (e.g. `raf`).
  static String extOf(String path) {
    final e = p.extension(path);
    return e.isEmpty ? '' : e.substring(1).toLowerCase();
  }

  /// Whether [path] is a taggable photo by extension.
  static bool isPhoto(String path) => all.contains(extOf(path));

  /// Whether [path] is a RAW container by extension.
  static bool isRaw(String path) => raw.contains(extOf(path));
}
