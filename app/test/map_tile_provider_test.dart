import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:stunda/src/explore/map_tile_provider.dart';
import 'package:stunda/src/explore/tile_cache.dart';
import 'package:stunda/src/explore/tile_provider_scope.dart';

Uint8List _realPng() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tileprov'));
  tearDown(() => root.deleteSync(recursive: true));

  TileCache makeCache() => TileCache(
    client: MockClient((_) async => http.Response('', 200)),
    root: root,
  );

  testWidgets('decodeTileBytes turns cached PNG bytes into a ui.Image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final info = await decodeTileBytes(_realPng());
      expect(info.image.width, 2);
      expect(info.image.height, 2);
      info.image.dispose();
    });
  });

  test('getImage keys are equal for the same coordinate, differ otherwise', () {
    final provider = CachingTileProvider(cache: makeCache());
    final layer = TileLayer(urlTemplate: 'https://e/{z}/{x}/{y}.png');
    final a = provider.getImage(const TileCoordinates(1, 2, 3), layer);
    final b = provider.getImage(const TileCoordinates(1, 2, 3), layer);
    final c = provider.getImage(const TileCoordinates(9, 9, 9), layer);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });

  test('getImage keys differ when the underlying cache differs', () {
    final layer = TileLayer(urlTemplate: 'https://e/{z}/{x}/{y}.png');
    final a = CachingTileProvider(
      cache: makeCache(),
    ).getImage(const TileCoordinates(1, 2, 3), layer);
    final b = CachingTileProvider(
      cache: makeCache(),
    ).getImage(const TileCoordinates(1, 2, 3), layer);
    expect(a, isNot(b));
  });

  testWidgets('TileProviderScope exposes its provider; absent -> null', (
    tester,
  ) async {
    final provider = CachingTileProvider(cache: makeCache());
    TileProvider? seen;
    await tester.pumpWidget(
      TileProviderScope(
        tileProvider: provider,
        child: Builder(
          builder: (context) {
            seen = TileProviderScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(provider));

    await tester.pumpWidget(
      Builder(
        builder: (context) {
          expect(TileProviderScope.maybeOf(context), isNull);
          return const SizedBox();
        },
      ),
    );
  });

  test('TileProviderScope.updateShouldNotify reflects provider identity', () {
    final p1 = CachingTileProvider(cache: makeCache());
    final p2 = CachingTileProvider(cache: makeCache());
    const box = SizedBox();
    final a = TileProviderScope(tileProvider: p1, child: box);
    final b = TileProviderScope(tileProvider: p2, child: box);
    final aAgain = TileProviderScope(tileProvider: p1, child: box);
    expect(a.updateShouldNotify(b), isTrue);
    expect(a.updateShouldNotify(aAgain), isFalse);
  });
}
