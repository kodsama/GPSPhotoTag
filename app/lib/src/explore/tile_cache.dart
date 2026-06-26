// Constructor wires an injected client/timeout/sleep/concurrency into private
// fields, which trips this purely-stylistic lint; suppressed file-wide.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math';
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

/// A signature for the "sleep" seam injected into [TileCache] so retry backoff
/// is instant under test (a fake that returns immediately) but real in the app.
typedef SleepFn = Future<void> Function(Duration);

Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

/// Max number of fetch attempts for a single tile (1 initial + 2 retries).
const int _maxFetchAttempts = 3;

/// Delay before each retry, indexed by retry number: 200ms before attempt 2,
/// 600ms before attempt 3, then 1500ms for any further attempt.
const List<Duration> _retryBackoff = [
  Duration(milliseconds: 200),
  Duration(milliseconds: 600),
  Duration(milliseconds: 1500),
];

Duration _backoffFor(int retry) =>
    _retryBackoff[retry.clamp(0, _retryBackoff.length - 1)];

/// Whether a failed fetch (HTTP status or thrown error) is worth retrying:
/// timeouts, HTTP 429 (rate limit), HTTP 5xx, and socket/network errors are
/// transient; a 404 (and other 4xx) is permanent and fails fast.
bool isRetryableStatus(int status) => status == 429 || status >= 500;

/// A permanent fetch failure (e.g. HTTP 404) that must NOT be retried.
class _NonRetryable implements Exception {
  _NonRetryable(this.message);
  final String message;
}

/// A bounded async gate: at most [_limit] holders run [run]'s body at once; the
/// rest queue (FIFO) until a slot frees. Used so a burst of tile requests never
/// fires more than a handful of simultaneous network fetches.
class _Semaphore {
  _Semaphore(this._limit);

  final int _limit;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  /// Runs [body] once a slot is free, releasing the slot afterwards (even on
  /// error). [highPriority] callers jump the queue ahead of low-priority ones.
  Future<T> run<T>(
    Future<T> Function() body, {
    bool highPriority = true,
  }) async {
    if (_active >= _limit) {
      final c = Completer<void>();
      if (highPriority) {
        _waiters.insert(0, c);
      } else {
        _waiters.add(c);
      }
      await c.future;
    }
    _active++;
    try {
      return await body();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

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
  ///
  /// At most [maxConcurrentFetches] network fetches run at once (disk hits
  /// bypass the gate); each request times out after [requestTimeout] and a
  /// retryable failure is retried up to 3 times with [_retryBackoff] delays.
  /// [sleep] is the backoff seam (overridden in tests so they never wait).
  TileCache({
    required http.Client client,
    required Directory root,
    int maxConcurrentFetches = 6,
    Duration requestTimeout = const Duration(seconds: 12),
    SleepFn sleep = _realSleep,
  }) : _client = client,
       _requestTimeout = requestTimeout,
       _sleep = sleep,
       _gate = _Semaphore(maxConcurrentFetches),
       tilesDir = Directory(p.join(root.path, 'map_tiles'));

  final http.Client _client;
  final _Semaphore _gate;
  final Duration _requestTimeout;
  final SleepFn _sleep;

  /// The `<root>/map_tiles` directory holding the cached `{z}/{x}/{y}.png`.
  final Directory tilesDir;

  /// The on-disk path a tile at ([z], [x], [y]) is (or would be) cached at.
  String pathFor(int z, int x, int y) =>
      p.join(tilesDir.path, '$z', '$x', '$y.png');

  /// Returns the tile bytes for ([z], [x], [y]).
  ///
  /// A cached file on disk is served directly (instant, offline, bypasses the
  /// concurrency gate, and acts as the stale fallback for a tile that can no
  /// longer be re-fetched — once written, a tile is kept forever). On a cache
  /// miss the OSM tile is fetched through the shared gate (at most a handful of
  /// network fetches at once, [highPriority] ones served first), retried with
  /// backoff on a transient failure, written to disk atomically (temp file +
  /// rename), and returned. If every attempt fails but a stale file appeared on
  /// disk meanwhile, the stale bytes are served; only a miss with nothing
  /// cached propagates so the caller can show an error tile.
  Future<Uint8List> tile(
    int z,
    int x,
    int y, {
    bool highPriority = true,
  }) async {
    final file = File(pathFor(z, x, y));
    if (file.existsSync()) return file.readAsBytes();
    try {
      final bytes = await _gate.run(
        () => _fetchWithRetry(z, x, y),
        highPriority: highPriority,
      );
      await _writeAtomic(file, bytes);
      return bytes;
    } on Object {
      // All attempts failed: serve a stale copy if one exists, else propagate.
      if (file.existsSync()) return file.readAsBytes();
      rethrow;
    }
  }

  /// Warms ([z], [x], [y]) into the disk cache if absent, at low priority
  /// (behind on-screen tiles) and swallowing failures. Used by anticipatory
  /// prefetch so already-cached tiles are skipped (store-if-absent).
  Future<void> prefetch(int z, int x, int y) async {
    if (File(pathFor(z, x, y)).existsSync()) return;
    try {
      await tile(z, x, y, highPriority: false);
    } on Object {
      // Best-effort warming: a failed prefetch is silently ignored.
    }
  }

  /// Fetches the tile, retrying transient failures (timeout, 429, 5xx, socket
  /// error) up to 3 attempts with increasing backoff. A non-retryable status
  /// (e.g. 404) throws immediately without further attempts.
  Future<Uint8List> _fetchWithRetry(int z, int x, int y) async {
    Object lastError = StateError('no attempt made');
    for (var attempt = 0; attempt < _maxFetchAttempts; attempt++) {
      if (attempt > 0) await _sleep(_backoffFor(attempt - 1));
      try {
        return await _fetchOnce(z, x, y);
      } on _NonRetryable {
        rethrow;
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw lastError;
  }

  Future<Uint8List> _fetchOnce(int z, int x, int y) async {
    final res = await _client
        .get(
          Uri.parse(osmTileUrl(z, x, y)),
          headers: const {'User-Agent': tileUserAgent},
        )
        .timeout(_requestTimeout);
    if (res.statusCode == 200) return res.bodyBytes;
    final msg = 'tile $z/$x/$y -> HTTP ${res.statusCode}';
    if (isRetryableStatus(res.statusCode)) throw HttpException(msg);
    throw _NonRetryable(msg);
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

/// The slippy-map tile X covering longitude [lng] at zoom [z].
int lngToTileX(double lng, int z) {
  final n = 1 << z;
  final x = ((lng + 180.0) / 360.0 * n).floor();
  return x.clamp(0, n - 1);
}

/// The slippy-map tile Y covering latitude [lat] at zoom [z].
int latToTileY(double lat, int z) {
  final n = 1 << z;
  final clamped = lat.clamp(-85.05112878, 85.05112878);
  final rad = clamped * pi / 180.0;
  final y = ((1 - log(tan(rad) + 1 / cos(rad)) / pi) / 2 * n).floor();
  return y.clamp(0, n - 1);
}

/// The tile coordinates to warm around a settled viewport so panning and
/// zooming reveal already-cached tiles instead of blank paper.
///
/// Given the visible lat/lng box ([north], [south], [east], [west]) at integer
/// zoom [zoom], returns, deduplicated and capped at [cap] tiles:
///   * the viewport tiles at [zoom], expanded by a [margin]-tile ring in every
///     direction (so a pan in any direction lands on cached tiles),
///   * the **z+1** child tiles covering that same expanded box (instant
///     zoom-in), up to [maxZoom],
///   * the **z-1** parent tiles covering it (instant zoom-out), down to 0.
///
/// Pure tile math (no I/O, no Flutter) so it is fully unit testable; the screen
/// extracts the box/zoom from the live `MapCamera` and feeds it here, then hands
/// the list to [TileCache.prefetch].
List<(int z, int x, int y)> prefetchTileCoordinates({
  required double north,
  required double south,
  required double east,
  required double west,
  required int zoom,
  int margin = 2,
  int maxZoom = 19,
  int cap = 300,
}) {
  final seen = <(int, int, int)>{};
  final out = <(int, int, int)>[];

  void addLevel(int z) {
    if (z < 0 || z > maxZoom || out.length >= cap) return;
    final n = 1 << z;
    // West/east -> min/max X; north(lat hi) -> min Y, south(lat lo) -> max Y.
    final x0 = (lngToTileX(west, z) - margin).clamp(0, n - 1);
    final x1 = (lngToTileX(east, z) + margin).clamp(0, n - 1);
    final y0 = (latToTileY(north, z) - margin).clamp(0, n - 1);
    final y1 = (latToTileY(south, z) + margin).clamp(0, n - 1);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        if (out.length >= cap) return;
        final key = (z, x, y);
        if (seen.add(key)) out.add(key);
      }
    }
  }

  // Current zoom first (most useful), then children (z+1), then parents (z-1).
  addLevel(zoom);
  addLevel(zoom + 1);
  addLevel(zoom - 1);
  return out;
}
