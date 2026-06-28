import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:stunda_engine/stunda_engine.dart';

/// The device photo library on Android/iOS, implementing the engine's
/// [PhotoLibrary] port.
///
/// Enumeration, metadata, thumbnails, full bytes, and deletion go through the
/// `photo_manager` plugin (iOS Photos / Android MediaStore). GPS write-back —
/// the one thing the plugin cannot do — goes through a small native method
/// channel ([_gpsChannel]): iOS `PHAssetChangeRequest.location`, Android
/// `ExifInterface` on the MediaStore entry.
///
/// All calls run on the main isolate (the only place platform channels work);
/// the engine only ever consumes the temp proxy files [exportProxy] writes.
class DevicePhotoLibrary implements PhotoLibrary {
  /// Creates a library wrapper. [channel] is overridable for tests.
  DevicePhotoLibrary({MethodChannel? channel})
    : _gpsChannel = channel ?? const MethodChannel('stunda/photo');

  /// How many assets are fetched per page during [enumerate].
  static const int _pageSize = 500;

  final MethodChannel _gpsChannel;

  /// Cached temp dir holding exported proxies for this run.
  Directory? _proxyDir;

  /// Resolved [AssetEntity] cache keyed by id, populated by [enumerate] so the
  /// per-asset operations don't re-query the platform for the handle.
  final Map<String, AssetEntity> _byId = {};

  /// Requests photo-library access, returning whether usable access was granted
  /// (full or limited). Callers gate scanning on this.
  Future<bool> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  @override
  Future<List<LibraryAsset>> enumerate() async {
    final total = await PhotoManager.getAssetCount(type: RequestType.image);
    final assets = <LibraryAsset>[];
    _byId.clear();
    for (var start = 0; start < total; start += _pageSize) {
      final end = (start + _pageSize) > total ? total : start + _pageSize;
      final page = await PhotoManager.getAssetListRange(
        start: start,
        end: end,
        type: RequestType.image,
      );
      for (final entity in page) {
        _byId[entity.id] = entity;
        assets.add(await _toLibraryAsset(entity));
      }
    }
    return assets;
  }

  Future<LibraryAsset> _toLibraryAsset(AssetEntity entity) async {
    final filename = entity.title ?? await entity.titleAsync;
    final latLng = await entity.latlngAsync();
    // photo_manager reports (0, 0) for assets without a location.
    final hasGps =
        latLng != null && (latLng.latitude != 0 || latLng.longitude != 0);
    return LibraryAsset(
      id: entity.id,
      filename: filename.isEmpty ? '${entity.id}.jpg' : filename,
      width: entity.width,
      height: entity.height,
      byteSize: 0,
      createdAt: entity.createDateTime,
      latitude: hasGps ? latLng.latitude : null,
      longitude: hasGps ? latLng.longitude : null,
    );
  }

  @override
  Future<String> exportProxy(String id, int maxEdge) async {
    final dir = await _ensureProxyDir();
    final out = File(p.join(dir.path, '${_safeName(id)}_$maxEdge.jpg'));
    if (out.existsSync() && out.lengthSync() > 0) return out.path;

    final entity = await _entity(id);
    final bytes = await entity.thumbnailDataWithSize(
      ThumbnailSize(maxEdge, maxEdge),
      quality: 90,
    );
    if (bytes == null) {
      throw StateError('could not export proxy for asset $id');
    }
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }

  @override
  Future<Uint8List> thumbnail(String id, int edge) async {
    final entity = await _entity(id);
    final bytes = await entity.thumbnailDataWithSize(ThumbnailSize(edge, edge));
    if (bytes == null) throw StateError('no thumbnail for asset $id');
    return bytes;
  }

  @override
  Future<Uint8List> fullBytes(String id) async {
    final entity = await _entity(id);
    final bytes = await entity.originBytes;
    if (bytes == null) throw StateError('no bytes for asset $id');
    return bytes;
  }

  @override
  Future<void> writeGps(String id, double latitude, double longitude) async {
    await _gpsChannel.invokeMethod<void>('writeGps', {
      'id': id,
      'lat': latitude,
      'lng': longitude,
    });
  }

  @override
  Future<void> delete(List<String> ids) async {
    if (ids.isEmpty) return;
    await PhotoManager.editor.deleteWithIds(ids);
  }

  Future<AssetEntity> _entity(String id) async {
    final cached = _byId[id];
    if (cached != null) return cached;
    final fetched = await AssetEntity.fromId(id);
    if (fetched == null) throw StateError('asset $id not found');
    _byId[id] = fetched;
    return fetched;
  }

  Future<Directory> _ensureProxyDir() async {
    final existing = _proxyDir;
    if (existing != null) return existing;
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'stunda_proxies'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _proxyDir = dir;
    return dir;
  }

  /// Filesystem-safe rendering of a platform asset id (which may contain `/`).
  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}
