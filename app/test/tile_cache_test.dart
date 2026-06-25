import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:stunda/src/explore/tile_cache.dart';

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
