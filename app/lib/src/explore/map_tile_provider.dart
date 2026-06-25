import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'tile_cache.dart';

/// Decodes raw PNG tile [bytes] into a single-frame [ImageInfo].
///
/// Self-contained (does not use flutter_map's decode callback) so the decode
/// step is unit testable; used by the cached-tile [ImageProvider].
Future<ImageInfo> decodeTileBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return ImageInfo(image: frame.image);
}

/// A flutter_map [TileProvider] that serves OSM tiles through the persistent
/// disk [TileCache] (instant on revisit, works offline).
///
/// Thin glue: all the cache/fetch/stale logic lives in the unit-tested
/// [TileCache]; this just wires flutter_map's tile coordinates to it via a
/// custom [ImageProvider].
class CachingTileProvider extends TileProvider {
  /// Creates a provider backed by [cache].
  CachingTileProvider({required this.cache});

  /// The disk cache that actually reads/fetches/writes the tile bytes.
  final TileCache cache;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _CachedTileImage(
        cache: cache,
        z: coordinates.z,
        x: coordinates.x,
        y: coordinates.y,
      );
}

/// An [ImageProvider] whose bytes come from a [TileCache] entry.
@immutable
class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  const _CachedTileImage({
    required this.cache,
    required this.z,
    required this.x,
    required this.y,
  });

  final TileCache cache;
  final int z;
  final int x;
  final int y;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_load());
  }

  Future<ImageInfo> _load() async => decodeTileBytes(await cache.tile(z, x, y));

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage &&
      other.z == z &&
      other.x == x &&
      other.y == y &&
      identical(other.cache, cache);

  @override
  int get hashCode => Object.hash(cache, z, x, y);
}
