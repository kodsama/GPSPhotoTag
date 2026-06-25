import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Identifying User-Agent sent with every OSM tile request, per the OSM tile
/// usage policy (a contactable identity, not a generic library name).
const String tileUserAgent =
    'Stunda/2.0 (+https://github.com/kodsama/stunda; kodsama@protonmail.com)';

/// The OSM tile URL for ([z], [x], [y]).
String osmTileUrl(int z, int x, int y) =>
    'https://tile.openstreetmap.org/$z/$x/$y.png';

/// A persistent, disk-backed browse-cache for map tiles.
///
/// Every tile fetched from the network is written to
/// `<cacheDir>/map_tiles/{z}/{x}/{y}.png` and served from disk forever after,
/// so revisited areas are instant and work offline. Pure and Flutter-free (it
/// takes an injected [http.Client] and cache [Directory]) so it is fully unit
/// testable: cache-hit reads disk without touching the client; cache-miss
/// fetches then writes atomically; a network error with a stale file on disk
/// serves the stale bytes.
class TileCache {
  /// Creates a cache writing under `<root>/map_tiles`, fetching misses with
  /// [client].
  TileCache({required http.Client client, required Directory root})
    // ignore: prefer_initializing_formals
    : _client = client,
      tilesDir = Directory(p.join(root.path, 'map_tiles'));

  final http.Client _client;

  /// The `<root>/map_tiles` directory holding the cached `{z}/{x}/{y}.png`.
  final Directory tilesDir;

  /// The on-disk path a tile at ([z], [x], [y]) is (or would be) cached at.
  String pathFor(int z, int x, int y) =>
      p.join(tilesDir.path, '$z', '$x', '$y.png');

  /// Returns the tile bytes for ([z], [x], [y]).
  ///
  /// A cached file on disk is served directly (instant, offline, and acts as
  /// the stale fallback for a tile that can no longer be re-fetched — once
  /// written, a tile is kept forever). On a cache miss the OSM tile is fetched
  /// (with [tileUserAgent]), written to disk atomically (temp file + rename),
  /// and returned. A fetch failure with nothing cached propagates so the caller
  /// can show an error tile.
  Future<Uint8List> tile(int z, int x, int y) async {
    final file = File(pathFor(z, x, y));
    if (file.existsSync()) return file.readAsBytes();
    final bytes = await _fetch(z, x, y);
    await _writeAtomic(file, bytes);
    return bytes;
  }

  Future<Uint8List> _fetch(int z, int x, int y) async {
    final res = await _client.get(
      Uri.parse(osmTileUrl(z, x, y)),
      headers: const {'User-Agent': tileUserAgent},
    );
    if (res.statusCode != 200) {
      throw HttpException('tile $z/$x/$y -> HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  /// Writes [bytes] to [file] atomically: a sibling temp file is written first,
  /// then renamed over the target so a reader never sees a half-written tile.
  Future<void> _writeAtomic(File file, Uint8List bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }
}

/// The list of `(z, x, y)` tile coordinates covering the whole world for zoom
/// levels [minZoom]..[maxZoom] inclusive (each zoom z has `2^z * 2^z` tiles).
///
/// z0..z3 is 1 + 4 + 16 + 64 = 85 tiles — the rough world view seeded on first
/// run so the map paints immediately instead of showing grey.
List<(int z, int x, int y)> seedTileCoordinates({
  int minZoom = 0,
  int maxZoom = 3,
}) {
  final coords = <(int, int, int)>[];
  for (var z = minZoom; z <= maxZoom; z++) {
    final n = 1 << z; // 2^z
    for (var x = 0; x < n; x++) {
      for (var y = 0; y < n; y++) {
        coords.add((z, x, y));
      }
    }
  }
  return coords;
}

/// Seeds the low-zoom world view into [cache], once, best-effort.
///
/// Runs at most [concurrency] fetches in flight so the OSM servers (and the
/// network) are never hammered, and swallows per-tile errors so a flaky network
/// never blocks the UI. Idempotent: a marker file (`map_tiles/.seeded`) is
/// written on success and short-circuits any later call, so the 85 tiles are
/// only ever seeded once.
///
/// Returns the number of tiles freshly written this call (0 when already seeded
/// or when every tile was already cached).
Future<int> seedLowZoomTiles(
  TileCache cache, {
  int minZoom = 0,
  int maxZoom = 3,
  int concurrency = 4,
}) async {
  final marker = File(p.join(cache.tilesDir.path, '.seeded'));
  if (marker.existsSync()) return 0;

  final coords = seedTileCoordinates(minZoom: minZoom, maxZoom: maxZoom);
  var written = 0;
  // Throttle to `concurrency` in-flight fetches by draining fixed-size batches.
  for (var i = 0; i < coords.length; i += concurrency) {
    final batch = coords.skip(i).take(concurrency);
    await Future.wait([
      for (final (z, x, y) in batch)
        () async {
          final existed = File(cache.pathFor(z, x, y)).existsSync();
          try {
            await cache.tile(z, x, y);
            if (!existed) written++;
          } on Object {
            // Best-effort: ignore individual tile failures.
          }
        }(),
    ]);
  }

  try {
    await cache.tilesDir.create(recursive: true);
    await marker.writeAsString('1', flush: true);
  } on Object {
    // Marker write failure just means we may try again next launch.
  }
  return written;
}
