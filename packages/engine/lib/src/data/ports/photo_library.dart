import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One photo in the device photo library (iOS Photos / Android MediaStore),
/// described by the structured metadata those APIs expose directly — no file
/// read, no exiftool.
///
/// This is the mobile counterpart to a scanned file path: the app enumerates
/// assets on the main isolate (where the photo-library plugin lives), then
/// materialises a downscaled *proxy* file per asset for the worker-isolate
/// engine to hash/score/detect (see [PhotoLibrary.exportProxy]). The original
/// [width]/[height]/[byteSize] and [latitude]/[longitude] are preserved here so
/// the app can substitute them back into engine results (which see only the
/// proxy) for keeper selection and display.
///
/// Pure Dart and immutable so the value semantics are unit-testable without any
/// plugin or Flutter dependency.
@immutable
class LibraryAsset {
  /// Creates an asset descriptor.
  const LibraryAsset({
    required this.id,
    required this.filename,
    required this.width,
    required this.height,
    required this.byteSize,
    this.createdAt,
    this.latitude,
    this.longitude,
  });

  /// The platform's opaque, stable identifier (iOS `PHAsset.localIdentifier`,
  /// Android MediaStore id). Used to fetch bytes, write GPS, and delete.
  final String id;

  /// The asset's display filename (e.g. `IMG_0042.HEIC`). May not be unique.
  final String filename;

  /// Original pixel width (0 when the platform did not report it).
  final int width;

  /// Original pixel height (0 when the platform did not report it).
  final int height;

  /// Original byte size on disk (0 when unknown).
  final int byteSize;

  /// Capture time, when the library reports one.
  final DateTime? createdAt;

  /// Latitude in degrees, when the asset is geotagged.
  final double? latitude;

  /// Longitude in degrees, when the asset is geotagged.
  final double? longitude;

  /// Lower-case extension without the dot (e.g. `heic`), or `''` when none.
  String get ext {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return '';
    return filename.substring(dot + 1).toLowerCase();
  }

  /// Whether the asset already carries GPS coordinates.
  bool get hasGps => latitude != null && longitude != null;

  /// Original pixel area (`width * height`), the keeper-selection resolution
  /// signal that the downscaled proxy would otherwise lose.
  int get pixelArea => width * height;

  /// JSON form, for logging and tests.
  Map<String, Object?> toJson() => {
    'id': id,
    'filename': filename,
    'width': width,
    'height': height,
    'byteSize': byteSize,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
  };
}

/// Seam for the device photo library on mobile (iOS Photos / Android
/// MediaStore).
///
/// The concrete implementation lives in the Flutter app (it wraps a plugin and
/// platform channels) and runs on the **main isolate** — the only place
/// platform channels work. The engine never calls this from a worker isolate;
/// it only ever sees the plain temp files [exportProxy] produces. Abstracting it
/// here keeps the orchestration testable with a fake library.
abstract interface class PhotoLibrary {
  /// Lists every image asset in the library with its structured metadata.
  Future<List<LibraryAsset>> enumerate();

  /// Materialises a downscaled JPEG proxy of asset [id] (longest edge clamped
  /// to [maxEdge]) into a temp file and returns its path. The proxy embeds the
  /// asset's original capture date + GPS in EXIF so the engine pipeline reads
  /// correct metadata from it. Implementations should cache by asset id so
  /// re-scans are cheap.
  Future<String> exportProxy(String id, int maxEdge);

  /// Decoded thumbnail bytes for asset [id] sized to roughly [edge] px, for UI
  /// lists and map popups.
  Future<Uint8List> thumbnail(String id, int edge);

  /// Full-resolution original bytes for asset [id], for the comparison viewer.
  Future<Uint8List> fullBytes(String id);

  /// Writes [latitude]/[longitude] (degrees) onto asset [id] via the native
  /// photo APIs (iOS `PHAssetChangeRequest.location`; Android `ExifInterface`
  /// on the MediaStore entry). Throws on failure.
  Future<void> writeGps(String id, double latitude, double longitude);

  /// Deletes the assets [ids] through the native photo-delete API (which
  /// surfaces the OS confirmation/undo affordances). Throws on failure.
  Future<void> delete(List<String> ids);
}
