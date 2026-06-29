import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/duplicates_model.dart';
import 'package:stunda/src/state/library_action.dart';

import 'support/fakes.dart';

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

HashedFile _hashed(String path, {int w = 1024, int h = 768}) => HashedFile(
  path: path,
  width: w,
  height: h,
  fileSize: 100,
  basename: 'proxy',
  isRaw: false,
);

AppController _mobile(
  FakePhotoLibrary lib, {
  FakeEngineRunner? runner,
  bool granted = true,
  bool rawPruning = false,
  Future<List<String>> Function()? pickTracks,
}) => AppController(
  runner: runner ?? FakeEngineRunner(),
  photoLibrary: lib,
  requestPhotoAccess: () async => granted,
  pickTrackFiles: pickTracks,
  mobileRawPruning: rawPruning,
);

void main() {
  test('isMobile is true only when a photo library is injected', () {
    expect(AppController().isMobile, isFalse);
    expect(_mobile(FakePhotoLibrary(const [])).isMobile, isTrue);
  });

  group('scanLibrary', () {
    test('enumerates, exports proxies, lands on workspace', () async {
      final lib = FakePhotoLibrary([
        _asset('a', filename: 'a.heic'),
        _asset('b', filename: 'b.jpg'),
      ]);
      final c = _mobile(lib);
      await c.scanLibrary();

      expect(c.screen, AppScreen.workspace);
      expect(c.scan!.photos, [
        FakePhotoLibrary.proxyPathFor('a'),
        FakePhotoLibrary.proxyPathFor('b'),
      ]);
      expect(c.scan!.byExtension['heic'], 1);
      expect(c.photoPermissionDenied, isFalse);
    });

    test('denied access returns to welcome with a flag', () async {
      final c = _mobile(FakePhotoLibrary([_asset('a')]), granted: false);
      await c.scanLibrary();
      expect(c.screen, AppScreen.welcome);
      expect(c.photoPermissionDenied, isTrue);
      expect(c.scan, isNull);
    });

    test('a failed proxy export is dropped, not fatal', () async {
      final lib = FakePhotoLibrary([_asset('a'), _asset('b')])
        ..exportFailures.add('a');
      final c = _mobile(lib);
      await c.scanLibrary();
      expect(c.scan!.photos, [FakePhotoLibrary.proxyPathFor('b')]);
    });

    test('is a no-op on desktop (no library)', () async {
      final c = AppController(runner: FakeEngineRunner());
      await c.scanLibrary();
      expect(c.screen, AppScreen.welcome);
    });
  });

  group('trash routing', () {
    test('routes duplicate trash through the photo library delete', () async {
      final lib = FakePhotoLibrary([_asset('a'), _asset('b')]);
      final runner = FakeEngineRunner();
      final c = _mobile(lib, runner: runner);
      await c.scanLibrary();

      // Seed a reviewable pair whose "other" is asset b's proxy.
      c.debugSetDuplicatePairs([
        DuplicatePair(
          kept: _hashed(FakePhotoLibrary.proxyPathFor('a')),
          other: _hashed(FakePhotoLibrary.proxyPathFor('b')),
        ),
      ]);
      await c.runTrashDuplicates();

      // The engine trash path was never used; the library delete got asset b.
      expect(runner.calls, isNot(contains('trashPaths')));
      expect(lib.deletedIds, ['b']);
      // The trashed asset is gone from the scan.
      expect(c.scan!.photos, [FakePhotoLibrary.proxyPathFor('a')]);
      expect(c.lastSummary, isNotNull);
    });

    test('a native delete failure surfaces an error', () async {
      final lib = FakePhotoLibrary([_asset('a')])
        ..deleteError = StateError('denied');
      final c = _mobile(lib);
      await c.scanLibrary();
      c.debugSetDuplicatePairs([
        DuplicatePair(
          kept: _hashed(FakePhotoLibrary.proxyPathFor('a')),
          other: _hashed(FakePhotoLibrary.proxyPathFor('a')),
        ),
      ]);
      await c.runTrashDuplicates();
      expect(c.errorMessage, contains('denied'));
    });
  });

  group('duplicate dimension substitution', () {
    test('keeper flips to the higher-resolution original', () async {
      final lib = FakePhotoLibrary([
        _asset('small', width: 1000, height: 1000),
        _asset('big', width: 8000, height: 6000),
      ]);
      final runner = FakeEngineRunner()
        ..duplicateGroups = [
          DuplicateGroup(
            best: _hashed(FakePhotoLibrary.proxyPathFor('small')),
            duplicates: [_hashed(FakePhotoLibrary.proxyPathFor('big'))],
          ),
        ];
      final c = _mobile(lib, runner: runner);
      await c.scanLibrary();
      await c.runFindDuplicates();

      final pairs = c.duplicatePairs!;
      expect(pairs.single.kept.path, FakePhotoLibrary.proxyPathFor('big'));
      expect(pairs.single.kept.resolution, 8000 * 6000);
    });
  });

  group('shrink low-quality dimension substitution', () {
    test('restores original size onto the hashed candidates', () async {
      final lib = FakePhotoLibrary([_asset('a', byteSize: 9000000)]);
      final runner = FakeEngineRunner()
        ..hashedFiles = [
          HashedFile(
            path: FakePhotoLibrary.proxyPathFor('a'),
            width: 1024,
            height: 768,
            fileSize: 50,
            basename: 'proxy',
            isRaw: false,
            quality: ImageQuality.zero, // composite 0 → below any threshold
          ),
        ];
      final c = _mobile(lib, runner: runner);
      await c.scanLibrary();
      await c.runShrinkLowQualityHash();
      // The proxy's 50-byte size was replaced with the asset's original size.
      expect(c.shrinkLowQCandidates.single.fileSize, 9000000);
    });
  });

  group('explore from assets', () {
    test('builds map points directly from geotagged assets', () async {
      final lib = FakePhotoLibrary([
        _asset('a', lat: 10, lng: 20, createdAt: DateTime(2020)),
        _asset('b'),
      ]);
      final runner = FakeEngineRunner();
      final c = _mobile(lib, runner: runner);
      await c.scanLibrary();
      c.openExplore();

      expect(c.exploreLoading, isFalse);
      expect(c.explorePhotos.length, 1);
      expect(c.explorePhotos.single.latitude, 10);
      // No engine metadata read happened on mobile.
      expect(runner.calls, isNot(contains('readImageMeta')));
    });
  });

  group('mobile tag', () {
    test('resolves from picked tracks and writes GPS back', () async {
      final dir = Directory.systemTemp.createTempSync('stunda_tag');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = DateTime.utc(2021, 6, 1, 12);
      final gpx = writeGpx(dir, 'track.gpx', t, lat: 51, lon: 7);

      final lib = FakePhotoLibrary([
        _asset('a', createdAt: t),
        _asset('b', createdAt: DateTime.utc(2000)), // out of range
      ]);
      final c = _mobile(lib, pickTracks: () async => [gpx]);
      await c.scanLibrary();
      await c.pickMobileTrackFiles();
      expect(c.mobileTrackFiles, [gpx]);

      await c.runTagMobile();
      expect(lib.gpsWrites.length, 1);
      expect(lib.gpsWrites.single.$1, 'a');
      expect(lib.gpsWrites.single.$2, 51);
      expect(c.runStateFor(LibraryAction.tag).running, isFalse);
    });

    test('dry-run writes nothing but reports', () async {
      final dir = Directory.systemTemp.createTempSync('stunda_tag_dry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = DateTime.utc(2021, 6, 1, 12);
      final gpx = writeGpx(dir, 'track.gpx', t);
      final lib = FakePhotoLibrary([_asset('a', createdAt: t)]);
      final c = _mobile(lib, pickTracks: () async => [gpx]);
      await c.scanLibrary();
      await c.pickMobileTrackFiles();
      c.setDryRun(true);
      await c.runTagMobile();
      expect(lib.gpsWrites, isEmpty);
      expect(c.lastSummary!['dry_run'], 1);
    });

    test('skips already-tagged assets unless replace is on', () async {
      final dir = Directory.systemTemp.createTempSync('stunda_tag_skip');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = DateTime.utc(2021, 6, 1, 12);
      final gpx = writeGpx(dir, 'track.gpx', t);
      final lib = FakePhotoLibrary([_asset('a', createdAt: t, lat: 1, lng: 2)]);
      final c = _mobile(lib, pickTracks: () async => [gpx]);
      await c.scanLibrary();
      await c.pickMobileTrackFiles();

      await c.runTagMobile();
      expect(lib.gpsWrites, isEmpty);
      expect(c.lastSummary!['already_tagged'], 1);

      c.setReplace(true);
      await c.runTagMobile();
      expect(lib.gpsWrites.length, 1);
    });

    test('clearMobileTrackFiles empties the set', () async {
      final c = _mobile(
        FakePhotoLibrary(const []),
        pickTracks: () async => ['/x.gpx'],
      );
      await c.pickMobileTrackFiles();
      expect(c.mobileTrackFiles, isNotEmpty);
      c.clearMobileTrackFiles();
      expect(c.mobileTrackFiles, isEmpty);
    });

    test('runTagMobile is a no-op on desktop', () async {
      final c = AppController(runner: FakeEngineRunner());
      await c.runTagMobile();
      expect(c.lastSummary, isNull);
    });

    test('a native writeGps failure is reported as an error row', () async {
      final dir = Directory.systemTemp.createTempSync('stunda_tag_err');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = DateTime.utc(2021, 6, 1, 12);
      final gpx = writeGpx(dir, 'track.gpx', t);
      final lib = FakePhotoLibrary([_asset('a', createdAt: t)])
        ..writeGpsError = StateError('write failed');
      final c = _mobile(lib, pickTracks: () async => [gpx]);
      await c.scanLibrary();
      await c.pickMobileTrackFiles();
      await c.runTagMobile();
      expect(c.lastSummary!['error'], 1);
    });
  });

  test('opening explore before a mobile scan yields no points', () {
    final c = _mobile(FakePhotoLibrary(const []));
    c.openExplore();
    expect(c.explorePhotos, isEmpty);
    expect(c.exploreLoading, isFalse);
  });

  group('Prune RAW (Android implements, iOS warns)', () {
    test('supportsRawPruning: desktop true, Android true, iOS false', () {
      expect(AppController().supportsRawPruning, isTrue); // desktop
      expect(
        _mobile(
          FakePhotoLibrary(const []),
          rawPruning: true,
        ).supportsRawPruning,
        isTrue, // Android
      );
      expect(
        _mobile(
          FakePhotoLibrary(const []),
          rawPruning: false,
        ).supportsRawPruning,
        isFalse, // iOS
      );
    });

    test(
      'Android pairs by original filename and trashes the orphan RAW',
      () async {
        // IMG_1 has a RAW+JPEG pair; IMG_2 is an orphan RAW (the candidate).
        final lib = FakePhotoLibrary([
          _asset('raw1', filename: 'IMG_1.DNG'),
          _asset('jpg1', filename: 'IMG_1.JPG'),
          _asset('raw2', filename: 'IMG_2.DNG'),
        ]);
        final c = _mobile(lib, rawPruning: true);
        await c.scanLibrary();
        c.openAction(LibraryAction.pruneRaw);

        // Only the companionless RAW is a deletion candidate, keyed by filename.
        expect(c.pairing, isNotNull);
        expect(c.pruneCandidates, ['IMG_2.DNG']);

        await c.runTrashSelected();
        // The orphan RAW's asset id is what reaches the native delete.
        expect(lib.deletedIds, ['raw2']);
        // Its proxy is gone from the scan; the pair survives.
        expect(c.scan!.photos, contains(FakePhotoLibrary.proxyPathFor('raw1')));
        expect(c.scan!.photos, contains(FakePhotoLibrary.proxyPathFor('jpg1')));
        expect(
          c.scan!.photos,
          isNot(contains(FakePhotoLibrary.proxyPathFor('raw2'))),
        );
      },
    );

    test(
      'iOS leaves the pairing null so the action shows the warning',
      () async {
        final lib = FakePhotoLibrary([_asset('raw2', filename: 'IMG_2.DNG')]);
        final c = _mobile(lib, rawPruning: false);
        await c.scanLibrary();
        c.openAction(LibraryAction.pruneRaw);
        expect(c.pairing, isNull);
        expect(c.pruneCandidates, isEmpty);
      },
    );
  });
}
