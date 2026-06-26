import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:stunda/src/explore/tile_cache.dart';

/// A sleep seam that records the backoff durations instead of waiting.
SleepFn _spySleep(List<Duration> sink) =>
    (Duration d) async => sink.add(d);

/// A 1x1 PNG's worth of arbitrary bytes (content is irrelevant to the cache).
final _png = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('tilecache'));
  tearDown(() => root.deleteSync(recursive: true));

  group('osmTileUrl + pathFor', () {
    test('build the expected OSM url and on-disk path', () {
      expect(osmTileUrl(3, 4, 5), 'https://tile.openstreetmap.org/3/4/5.png');
      final cache = TileCache(
        client: MockClient((_) async => http.Response('', 200)),
        root: root,
      );
      expect(
        cache.pathFor(3, 4, 5),
        p.join(root.path, 'map_tiles', '3', '4', '5.png'),
      );
      expect(cache.tilesDir.path, p.join(root.path, 'map_tiles'));
    });
  });

  group('TileCache.tile', () {
    test(
      'cache miss fetches, writes the tile to disk, and returns bytes',
      () async {
        var hits = 0;
        final client = MockClient((req) async {
          hits++;
          expect(req.url.toString(), osmTileUrl(2, 1, 1));
          expect(req.headers['User-Agent'], tileUserAgent);
          return http.Response.bytes(_png, 200);
        });
        final cache = TileCache(client: client, root: root);

        final bytes = await cache.tile(2, 1, 1);

        expect(bytes, _png);
        expect(hits, 1);
        // Written to disk atomically (no leftover temp file).
        final file = File(cache.pathFor(2, 1, 1));
        expect(file.existsSync(), isTrue);
        expect(file.readAsBytesSync(), _png);
        expect(
          file.parent.listSync().where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );

    test('cache hit reads disk WITHOUT hitting the client', () async {
      // Pre-seed the file on disk.
      final cache = TileCache(
        client: MockClient((_) async => fail('client must not be called')),
        root: root,
      );
      final file = File(cache.pathFor(5, 6, 7))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_png);

      final bytes = await cache.tile(5, 6, 7);

      expect(bytes, _png);
      expect(file.readAsBytesSync(), _png);
    });

    test(
      'non-200 with NO stale copy rethrows so an error tile can show',
      () async {
        final cache = TileCache(
          client: MockClient((_) async => http.Response('nope', 404)),
          root: root,
        );
        await expectLater(cache.tile(1, 0, 0), throwsA(isA<Exception>()));
        expect(File(cache.pathFor(1, 0, 0)).existsSync(), isFalse);
      },
    );

    test(
      'a cached tile is served offline even when the network is down',
      () async {
        final stale = Uint8List.fromList([9, 9, 9]);
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          throw const SocketExceptionLike();
        });
        final cache = TileCache(client: client, root: root);
        // Simulate a previously fetched (now "stale") tile on disk.
        File(cache.pathFor(4, 2, 2))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(stale);

        // The disk copy is served without touching the (failing) network.
        final bytes = await cache.tile(4, 2, 2);
        expect(bytes, stale);
        expect(calls, 0);
      },
    );
  });

  group('TileCache reliability (timeout / retry / concurrency / stale)', () {
    test(
      'retries a 429 then succeeds on the 200, with backoff delays',
      () async {
        final slept = <Duration>[];
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          if (calls == 1) return http.Response('rate limited', 429);
          return http.Response.bytes(_png, 200);
        });
        final cache = TileCache(
          client: client,
          root: root,
          sleep: _spySleep(slept),
        );

        final bytes = await cache.tile(3, 1, 2);

        expect(bytes, _png);
        expect(calls, 2); // first 429, retry succeeds
        expect(slept, [const Duration(milliseconds: 200)]); // one backoff
        expect(File(cache.pathFor(3, 1, 2)).existsSync(), isTrue);
      },
    );

    test('a timeout is retryable: times out then succeeds', () async {
      final slept = <Duration>[];
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) {
          // Never completes within the (tiny) request timeout below.
          await Completer<void>().future;
        }
        return http.Response.bytes(_png, 200);
      });
      final cache = TileCache(
        client: client,
        root: root,
        requestTimeout: const Duration(milliseconds: 20),
        sleep: _spySleep(slept),
      );

      final bytes = await cache.tile(3, 1, 2);
      expect(bytes, _png);
      expect(calls, 2);
      expect(slept, [const Duration(milliseconds: 200)]);
    });

    test(
      '3x failure but a stale file appeared meanwhile serves the stale bytes',
      () async {
        final stale = Uint8List.fromList([7, 7, 7]);
        final slept = <Duration>[];
        var calls = 0;
        late final TileCache cache;
        final client = MockClient((_) async {
          calls++;
          // Simulate a concurrent writer dropping the tile on disk during the
          // first (failing) fetch — the post-failure path must serve it.
          if (calls == 1) {
            File(cache.pathFor(2, 0, 0))
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(stale);
          }
          return http.Response('boom', 500);
        });
        cache = TileCache(client: client, root: root, sleep: _spySleep(slept));

        // The tile is NOT on disk when tile() starts, so it enters the fetch
        // path; all 3 attempts 500, then the now-present stale file is served.
        final bytes = await cache.tile(2, 0, 0);
        expect(bytes, stale);
        expect(calls, 3); // exhausted retries before falling back to stale
      },
    );

    test(
      'all 3 attempts fail and nothing is cached -> error propagates',
      () async {
        final slept = <Duration>[];
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('server error', 503);
        });
        final cache = TileCache(
          client: client,
          root: root,
          sleep: _spySleep(slept),
        );

        await expectLater(cache.tile(5, 1, 1), throwsA(isA<Exception>()));
        expect(calls, 3); // 1 + 2 retries
        expect(slept, [
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 600),
        ]);
        expect(File(cache.pathFor(5, 1, 1)).existsSync(), isFalse);
      },
    );

    test('404 fails fast: no retry, no backoff', () async {
      final slept = <Duration>[];
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('not found', 404);
      });
      final cache = TileCache(
        client: client,
        root: root,
        sleep: _spySleep(slept),
      );

      await expectLater(cache.tile(9, 0, 0), throwsA(isA<Exception>()));
      expect(calls, 1); // no retry on 404
      expect(slept, isEmpty); // no backoff
    });

    test('network fetches never exceed the concurrency cap', () async {
      var active = 0;
      var peak = 0;
      final gate = Completer<void>();
      final client = MockClient((_) async {
        active++;
        peak = peak > active ? peak : active;
        // Hold every fetch open until released, so they pile up against the
        // cap before any completes.
        await gate.future;
        active--;
        return http.Response.bytes(_png, 200);
      });
      final cache = TileCache(
        client: client,
        root: root,
        maxConcurrentFetches: 6,
        sleep: _spySleep([]),
      );

      // Fire 25 distinct tile fetches at once (none are cached).
      final futures = [for (var i = 0; i < 25; i++) cache.tile(10, i, 0)];
      // Let the gate admit its first wave.
      await Future<void>.delayed(Duration.zero);
      expect(peak, lessThanOrEqualTo(6));
      expect(active, lessThanOrEqualTo(6));

      gate.complete();
      await Future.wait(futures);
      expect(peak, 6); // saturated the cap with 25 queued requests
    });

    test('a low-priority fetch queues behind a saturated gate', () async {
      final release = Completer<void>();
      var active = 0;
      var peak = 0;
      final client = MockClient((req) async {
        active++;
        peak = peak > active ? peak : active;
        await release.future;
        active--;
        return http.Response.bytes(_png, 200);
      });
      final cache = TileCache(
        client: client,
        root: root,
        maxConcurrentFetches: 2,
        sleep: _spySleep([]),
      );

      // Saturate the gate with 2 high-priority fetches, then add a low-priority
      // prefetch that must wait (exercising the low-priority enqueue path).
      final hi = [cache.tile(1, 0, 0), cache.tile(1, 1, 0)];
      final lo = cache.prefetch(1, 2, 0);
      await Future<void>.delayed(Duration.zero);
      expect(peak, lessThanOrEqualTo(2)); // low-priority one is still queued

      release.complete();
      await Future.wait([...hi, lo]);
      expect(File(cache.pathFor(1, 2, 0)).existsSync(), isTrue);
    });

    test('low-priority prefetch warms an absent tile via the cache', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response.bytes(_png, 200);
      });
      final cache = TileCache(client: client, root: root, sleep: _spySleep([]));

      await cache.prefetch(8, 3, 3);
      expect(calls, 1);
      expect(File(cache.pathFor(8, 3, 3)).existsSync(), isTrue);

      // Already-cached: prefetch is a no-op (store-if-absent).
      await cache.prefetch(8, 3, 3);
      expect(calls, 1);
    });

    test('prefetch swallows fetch failures', () async {
      final client = MockClient((_) async => http.Response('nope', 404));
      final cache = TileCache(client: client, root: root, sleep: _spySleep([]));
      // Must not throw even though the tile can't be fetched.
      await cache.prefetch(8, 4, 4);
      expect(File(cache.pathFor(8, 4, 4)).existsSync(), isFalse);
    });
  });

  group('isRetryableStatus', () {
    test('429 and 5xx are retryable; 404/other 4xx are not', () {
      expect(isRetryableStatus(429), isTrue);
      expect(isRetryableStatus(500), isTrue);
      expect(isRetryableStatus(503), isTrue);
      expect(isRetryableStatus(404), isFalse);
      expect(isRetryableStatus(400), isFalse);
      expect(isRetryableStatus(200), isFalse);
    });
  });

  group('lngToTileX / latToTileY (slippy-map math)', () {
    test('z0 has a single tile (0,0) covering the world', () {
      expect(lngToTileX(-180, 0), 0);
      expect(lngToTileX(179.9, 0), 0);
      expect(latToTileY(85, 0), 0);
      expect(latToTileY(-85, 0), 0);
    });

    test('z1 splits into the four hemispherical quadrants', () {
      // West longitudes -> x=0, east -> x=1.
      expect(lngToTileX(-90, 1), 0);
      expect(lngToTileX(90, 1), 1);
      // Northern lats -> y=0, southern -> y=1.
      expect(latToTileY(45, 1), 0);
      expect(latToTileY(-45, 1), 1);
    });

    test('clamps out-of-range coordinates into valid tile indices', () {
      expect(lngToTileX(1000, 2), 3); // 2^2 - 1
      expect(latToTileY(90, 2), 0); // clamped to the north edge
      expect(latToTileY(-90, 2), 3); // clamped to the south edge
    });
  });

  group('prefetchTileCoordinates', () {
    test('covers viewport + margin ring and one zoom level either side', () {
      final coords = prefetchTileCoordinates(
        north: 1,
        south: -1,
        east: 1,
        west: -1,
        zoom: 5,
        margin: 1,
      );
      final zooms = coords.map((c) => c.$1).toSet();
      // z, z+1, z-1 are all represented.
      expect(zooms, containsAll(<int>[4, 5, 6]));
      // No duplicates.
      expect(coords.toSet().length, coords.length);
      // Includes the center tile of the viewport at z5.
      final cx = lngToTileX(0, 5);
      final cy = latToTileY(0, 5);
      expect(coords, contains((5, cx, cy)));
      // Margin ring: a tile one to the left/up is also warmed.
      expect(coords, contains((5, cx - 1, cy - 1)));
    });

    test('honours the cap, dropping tiles once the budget is spent', () {
      final coords = prefetchTileCoordinates(
        north: 60,
        south: -60,
        east: 170,
        west: -170,
        zoom: 8,
        margin: 4,
        cap: 50,
      );
      expect(coords.length, lessThanOrEqualTo(50));
      expect(coords, isNotEmpty);
      // Dedup invariant holds even at the cap.
      expect(coords.toSet().length, coords.length);
    });

    test('parent (z-1) and child (z+1) math nests the viewport correctly', () {
      final coords = prefetchTileCoordinates(
        north: 0.5,
        south: -0.5,
        east: 0.5,
        west: -0.5,
        zoom: 10,
        margin: 0,
      );
      final at10 = coords.where((c) => c.$1 == 10).toList();
      final at9 = coords.where((c) => c.$1 == 9).toList();
      final at11 = coords.where((c) => c.$1 == 11).toList();
      expect(at10, isNotEmpty);
      expect(at9, isNotEmpty);
      expect(at11, isNotEmpty);
      // A z10 tile's parent at z9 is (x~/2, y~/2).
      final (_, x10, y10) = at10.first;
      expect(at9, contains((9, x10 ~/ 2, y10 ~/ 2)));
    });

    test('clamps levels at maxZoom (no z+1 above the native cap) and at 0', () {
      final atMax = prefetchTileCoordinates(
        north: 1,
        south: -1,
        east: 1,
        west: -1,
        zoom: 19,
        maxZoom: 19,
      );
      expect(atMax.map((c) => c.$1).toSet(), isNot(contains(20)));

      final atZero = prefetchTileCoordinates(
        north: 80,
        south: -80,
        east: 170,
        west: -170,
        zoom: 0,
      );
      // z-1 would be -1; only z0 and z1 appear.
      expect(atZero.map((c) => c.$1).toSet(), <int>{0, 1});
    });
  });

  group('seedTileCoordinates', () {
    test('z0..z3 yields 85 tiles (1 + 4 + 16 + 64)', () {
      final coords = seedTileCoordinates();
      expect(coords.length, 85);
      expect(coords.first, (0, 0, 0));
      // z3 has 8x8 = 64 tiles; the last is (3, 7, 7).
      expect(coords.last, (3, 7, 7));
    });

    test('respects custom zoom bounds', () {
      expect(seedTileCoordinates(minZoom: 0, maxZoom: 0), [(0, 0, 0)]);
      expect(seedTileCoordinates(minZoom: 1, maxZoom: 1).length, 4);
    });
  });

  group('seedLowZoomTiles', () {
    test('writes every tile, drops a marker, and is idempotent', () async {
      final fetched = <String>[];
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        fetched.add(req.url.path);
        return http.Response.bytes(_png, 200);
      });
      final cache = TileCache(client: client, root: root);

      final written = await seedLowZoomTiles(cache, maxZoom: 1);

      // z0..z1 = 1 + 4 = 5 tiles.
      expect(written, 5);
      expect(calls, 5);
      expect(File(cache.pathFor(0, 0, 0)).existsSync(), isTrue);
      expect(File(cache.pathFor(1, 1, 1)).existsSync(), isTrue);
      // Marker present.
      expect(File(p.join(cache.tilesDir.path, '.seeded')).existsSync(), isTrue);

      // Second run is a no-op: marker short-circuits, no further fetches.
      final again = await seedLowZoomTiles(cache, maxZoom: 1);
      expect(again, 0);
      expect(calls, 5);
    });

    test('swallows per-tile fetch errors and still seeds the marker', () async {
      final client = MockClient((_) async => http.Response('boom', 500));
      final cache = TileCache(client: client, root: root);

      final written = await seedLowZoomTiles(cache, maxZoom: 0);

      expect(written, 0); // nothing succeeded
      expect(File(p.join(cache.tilesDir.path, '.seeded')).existsSync(), isTrue);
    });
  });
}

/// A stand-in error type so the MockClient can simulate a network failure.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
