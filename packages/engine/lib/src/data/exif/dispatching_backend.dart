import 'backend_registry.dart';
import 'exif_backend.dart';

/// An [ExifBackend] that delegates each call to whichever concrete backend the
/// [BackendRegistry] selects for the file's format.
///
/// Lets multi-format operations (e.g. date fixing across a mixed folder) depend
/// on a single [ExifBackend] while still routing JPEG, PNG, RAW and HEIC to the
/// right implementation.
class DispatchingExifBackend implements ExifBackend {
  /// Wraps [registry].
  DispatchingExifBackend(this._registry);

  final BackendRegistry _registry;

  @override
  bool supports(String path) => _registry.readerFor(path) != null;

  @override
  Future<PhotoMeta> read(String path) async =>
      await _registry.readerFor(path)?.read(path) ?? const PhotoMeta();

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async {
    final writer = _registry.writerFor(path);
    if (writer == null) {
      throw StateError('no write backend for $path');
    }
    await writer.writeGps(
      path,
      latitude: latitude,
      longitude: longitude,
      dateTimeOriginal: dateTimeOriginal,
    );
  }
}
