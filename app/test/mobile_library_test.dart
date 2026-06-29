import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/engine/mobile_library.dart';

LibraryAsset _asset(
  String id, {
  String? filename,
  int width = 4000,
  int height = 3000,
  int byteSize = 5000000,
  DateTime? createdAt,
  double? lat,
  double? lng,
}) => LibraryAsset(
  id: id,
  filename: filename ?? '$id.jpg',
  width: width,
  height: height,
  byteSize: byteSize,
  createdAt: createdAt,
  latitude: lat,
  longitude: lng,
);

HashedFile _hashed(String path, {int width = 1024, int height = 768}) =>
    HashedFile(
      path: path,
      width: width,
      height: height,
      fileSize: 100,
      basename: 'proxy',
      isRaw: false,
    );

void main() {
  group('MobileLibrary.fromExports', () {
    test('builds parallel proxy↔asset and id maps, skipping empty proxies', () {
      final assets = [_asset('a'), _asset('b'), _asset('c')];
      final lib = MobileLibrary.fromExports(assets, ['/p/a', '', '/p/c']);

      expect(lib.proxyPaths, ['/p/a', '/p/c']);
      expect(lib.assetsById.keys, containsAll(['a', 'b', 'c']));
      expect(lib.assetForProxy('/p/a')!.id, 'a');
      expect(lib.assetForProxy('/p/missing'), isNull);
    });

    test('maps proxy paths back to asset ids, dropping unknowns', () {
      final lib = MobileLibrary.fromExports(
        [_asset('a'), _asset('b')],
        ['/p/a', '/p/b'],
      );
      expect(lib.assetIdsForProxies(['/p/b', '/p/x', '/p/a']), ['b', 'a']);
    });

    test('removeAssets drops them from every index', () {
      final lib = MobileLibrary.fromExports(
        [_asset('a'), _asset('b')],
        ['/p/a', '/p/b'],
      );
      lib.removeAssets(['a']);
      expect(lib.proxyPaths, ['/p/b']);
      expect(lib.assetsById.keys, ['b']);
      expect(lib.assetForProxy('/p/a'), isNull);
    });

    test('proxyForAsset is the inverse of assetForProxy', () {
      final lib = MobileLibrary.fromExports([_asset('a')], ['/p/a']);
      expect(lib.proxyForAsset('a'), '/p/a');
      expect(lib.proxyForAsset('nope'), isNull);
    });
  });

  group('dimension substitution', () {
    test('restores original width/height/size/basename from the asset', () {
      final lib = MobileLibrary.fromExports(
        [
          _asset(
            'a',
            filename: 'IMG_1.HEIC',
            width: 6000,
            height: 4000,
            byteSize: 9000000,
          ),
        ],
        ['/p/a'],
      );
      final restored = lib.withOriginalDimensions([_hashed('/p/a')]);
      expect(restored.single.width, 6000);
      expect(restored.single.height, 4000);
      expect(restored.single.fileSize, 9000000);
      // basename is the stem (no extension).
      expect(restored.single.basename, 'IMG_1');
    });

    test('passes through records whose proxy is unknown', () {
      final lib = MobileLibrary.fromExports([_asset('a')], ['/p/a']);
      final h = _hashed('/p/unknown');
      expect(lib.withOriginalDimensions([h]).single.width, 1024);
    });

    test('withOriginalGroups re-chooses the keeper by original resolution', () {
      // The proxy hashes are equal-resolution, but original 'big' is larger, so
      // the keeper must flip to it after substitution.
      final lib = MobileLibrary.fromExports(
        [
          _asset('small', width: 1000, height: 1000),
          _asset('big', width: 8000, height: 6000),
        ],
        ['/p/small', '/p/big'],
      );
      final group = DuplicateGroup(
        best: _hashed('/p/small'),
        duplicates: [_hashed('/p/big')],
      );
      final out = lib.withOriginalGroups([group], KeepPipeline.standard);
      expect(out.single.best.path, '/p/big');
      expect(out.single.best.resolution, 8000 * 6000);
    });
  });

  group('synthesizeScan', () {
    test('photos are proxy paths; counts derive from original formats', () {
      final assets = [
        _asset('a', filename: 'a.heic'),
        _asset('b', filename: 'b.JPG'),
        _asset('c', filename: 'c.heic'),
      ];
      final scan = synthesizeScan(assets, ['/p/a', '/p/b', '/p/c']);
      expect(scan.photos, ['/p/a', '/p/b', '/p/c']);
      expect(scan.byExtension['heic'], 2);
      expect(scan.byExtension['jpg'], 1);
      expect(scan.gpxFiles, isEmpty);
      expect(scan.googleFiles, isEmpty);
      expect(scan.unsupportedCount, 0);
    });

    test('drops failed (empty) proxies from photos but defaults blank ext', () {
      final assets = [_asset('a', filename: 'noext'), _asset('b')];
      final scan = synthesizeScan(assets, ['', '/p/b']);
      expect(scan.photos, ['/p/b']);
      expect(scan.byExtension['jpg'], 1);
    });
  });

  group('exploreFromAssets', () {
    test('keeps only geotagged assets with their proxy + coordinates', () {
      final assets = [
        _asset('a', lat: 10, lng: 20, createdAt: DateTime(2020)),
        _asset('b'), // no GPS
      ];
      final lib = MobileLibrary.fromExports(assets, ['/p/a', '/p/b']);
      final photos = lib.exploreFromAssets;
      expect(photos.length, 1);
      expect(photos.single.assetId, 'a');
      expect(photos.single.proxyPath, '/p/a');
      expect(photos.single.latitude, 10);
      expect(photos.single.date, DateTime(2020));
    });
  });

  group('pairingFromFilenames', () {
    test('pairs RAW + JPEG by basename over original filenames', () {
      final assets = [
        _asset('r', filename: 'DSC1.dng'),
        _asset('j', filename: 'DSC1.jpg'),
        _asset('o', filename: 'DSC2.dng'),
      ];
      final lib = MobileLibrary.fromExports(assets, ['/p/r', '/p/j', '/p/o']);
      final mp = lib.pairingFromFilenames();
      expect(mp.pairing.orphanRaws, ['DSC2.dng']);
      expect(mp.idsFor(['DSC2.dng']), ['o']);
      expect(mp.idsFor(['unknown.dng']), isEmpty);
    });
  });

  group('resolveAssetLocations', () {
    test('resolves from the pool by capture time, skipping null dates', () {
      final t = DateTime.utc(2021, 6, 1, 12);
      final pool = SourcePool(
        track: [TimedPoint(time: t, latitude: 50, longitude: 8)],
        google: const [],
      );
      final photos = [
        MobileTagPhoto(assetId: 'a', date: t),
        const MobileTagPhoto(assetId: 'b', date: null),
        MobileTagPhoto(
          assetId: 'c',
          date: DateTime.utc(2000), // far from any point → no fix
        ),
      ];
      final located = resolveAssetLocations(
        photos,
        pool,
        maxTimeDiff: const Duration(seconds: 60),
      );
      expect(located.map((l) => l.assetId), ['a']);
      expect(located.single.location.latitude, 50);
    });
  });
}
