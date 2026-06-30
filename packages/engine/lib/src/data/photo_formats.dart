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

  /// GPS-source extensions the engine can parse: `.gpx`/`.kml` tracks and the
  /// `.json` of a Google location-history / Timeline export.
  static const gpsSource = {'gpx', 'kml', 'json'};

  /// Whether [path] is a GPS-source file by extension (track or Google JSON).
  ///
  /// Extension-only: a `.json` that turns out not to be Google history is still
  /// "addable" here; the scanner validates its contents and buckets it as
  /// unsupported if it isn't real location data.
  static bool isGpsSource(String path) => gpsSource.contains(extOf(path));

  /// Whether [path] is a supported library input — a taggable photo or a
  /// GPS-source file. Used to classify individually added / dropped files.
  static bool isSupported(String path) => isPhoto(path) || isGpsSource(path);

  /// Lower-cased basename without its extension, used to match RAW/companion
  /// pairs across the file tree.
  ///
  /// Uses a manual last-separator + last-dot split (handling both `/` and `\`)
  /// rather than `p.basenameWithoutExtension`, so it is correct on Windows when
  /// paths use mixed separators.
  static String baseKeyOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    final stem = dot <= 0 ? base : base.substring(0, dot);
    return stem.toLowerCase();
  }
}
