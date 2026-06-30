import 'package:stunda_engine/stunda_engine.dart';

/// Pure orchestration helpers for the mobile (Android/iOS) photo-library flow.
///
/// On mobile the engine never sees the photo library: the app exports a
/// downscaled JPEG *proxy* per asset to a temp file, the engine hashes/scores
/// those proxies exactly like desktop files, and the app maps results back to
/// assets to route trash + GPS-write through the [PhotoLibrary]. Everything in
/// this file is plain Dart with no plugin or Flutter dependency, so the
/// proxy↔asset mapping, the synthesized scan result, the dimension
/// substitution, the explore-from-assets projection, and the
/// classify-from-filenames pairing are all unit-testable without a device.
class MobileLibrary {
  /// Builds a mobile library view over [assets] given the exported [proxyPaths]
  /// (one per asset, in the same order). The proxy path list is parallel to
  /// [assets]: `proxyPaths[i]` is the temp JPEG exported for `assets[i]`.
  MobileLibrary._(this._proxyToAsset, this._assetById);

  /// Builds the mapping from a parallel list of [assets] and their exported
  /// [proxyPaths]. The two lists must be the same length; pairs where the proxy
  /// export failed (an empty path) are skipped so a single bad asset never
  /// poisons the whole scan.
  factory MobileLibrary.fromExports(
    List<LibraryAsset> assets,
    List<String> proxyPaths,
  ) {
    assert(
      assets.length == proxyPaths.length,
      'assets and proxyPaths must be parallel',
    );
    final proxyToAsset = <String, LibraryAsset>{};
    final assetById = <String, LibraryAsset>{};
    for (var i = 0; i < assets.length; i++) {
      final asset = assets[i];
      assetById[asset.id] = asset;
      final proxy = proxyPaths[i];
      if (proxy.isNotEmpty) proxyToAsset[proxy] = asset;
    }
    return MobileLibrary._(proxyToAsset, assetById);
  }

  final Map<String, LibraryAsset> _proxyToAsset;
  final Map<String, LibraryAsset> _assetById;

  /// The proxy path for a given asset [id], or null when it has none (export
  /// failed or the asset was trashed). The inverse of [assetForProxy].
  String? proxyForAsset(String id) {
    for (final entry in _proxyToAsset.entries) {
      if (entry.value.id == id) return entry.key;
    }
    return null;
  }

  /// The proxy temp-file paths the engine scans, in insertion order.
  List<String> get proxyPaths => _proxyToAsset.keys.toList(growable: false);

  /// Every asset still in the library, keyed by id.
  Map<String, LibraryAsset> get assetsById => Map.unmodifiable(_assetById);

  /// The asset behind a [proxyPath], or null when unknown (e.g. already
  /// trashed).
  LibraryAsset? assetForProxy(String proxyPath) => _proxyToAsset[proxyPath];

  /// Maps engine-facing [proxyPaths] back to platform asset ids, dropping any
  /// proxy that no longer resolves to an asset.
  List<String> assetIdsForProxies(Iterable<String> proxyPaths) => [
    for (final path in proxyPaths)
      if (_proxyToAsset[path] != null) _proxyToAsset[path]!.id,
  ];

  /// Drops [ids] from every index after a successful delete, so the synthesized
  /// scan + explore projections stop referencing trashed assets.
  void removeAssets(Iterable<String> ids) {
    final set = ids.toSet();
    _assetById.removeWhere((id, _) => set.contains(id));
    _proxyToAsset.removeWhere((_, asset) => set.contains(asset.id));
  }

  /// Substitutes each [hashed] proxy record's original dimensions/size/basename
  /// back from its [LibraryAsset], so keeper selection and display reflect the
  /// full-resolution original rather than the downscaled proxy. Records whose
  /// proxy path is unknown pass through unchanged.
  List<HashedFile> withOriginalDimensions(List<HashedFile> hashed) => [
    for (final h in hashed) _restore(h),
  ];

  /// Rebuilds each duplicate [group] with its members' original dimensions
  /// substituted back, re-choosing the keeper under [pipeline] so resolution-
  /// based keep rules use the full-resolution original, not the proxy. Pure.
  List<DuplicateGroup> withOriginalGroups(
    List<DuplicateGroup> groups,
    KeepPipeline pipeline,
  ) => [
    for (final group in groups)
      _rebuildGroup([group.best, ...group.duplicates], pipeline),
  ];

  DuplicateGroup _rebuildGroup(
    List<HashedFile> members,
    KeepPipeline pipeline,
  ) {
    final restored = [for (final m in members) _restore(m)];
    final best = chooseKeeper(restored, pipeline);
    return DuplicateGroup(
      best: best,
      duplicates: [
        for (final m in restored)
          if (!identical(m, best)) m,
      ],
    );
  }

  HashedFile _restore(HashedFile h) {
    final asset = _proxyToAsset[h.path];
    if (asset == null) return h;
    return h.withOriginal(
      width: asset.width,
      height: asset.height,
      fileSize: asset.byteSize,
      basename: _stem(asset.filename),
    );
  }

  /// The geotagged assets projected for the Explore map (lat/lng + date are
  /// already known from enumeration, so Explore needs no metadata read). Each
  /// carries its already-exported [MobileExplorePhoto.proxyPath] so the map
  /// markers + detail panel render the real (decodable) proxy JPEG by file path,
  /// reusing the desktop image pipeline unchanged.
  List<MobileExplorePhoto> get exploreFromAssets => [
    for (final asset in _assetById.values)
      if (asset.hasGps)
        MobileExplorePhoto(
          assetId: asset.id,
          proxyPath: proxyForAsset(asset.id),
          latitude: asset.latitude!,
          longitude: asset.longitude!,
          date: asset.createdAt,
          width: asset.width,
          height: asset.height,
        ),
  ];

  /// Classifies the library's RAW/JPEG pairing over the *original* asset
  /// filenames (proxies are all `.jpg` and would lose the RAW extension), then
  /// maps the chosen filenames back to asset ids for deletion.
  ///
  /// Returns the [RawPairing] (whose `PairedFile.path` is each asset's
  /// filename) plus a filename→id lookup so the controller can route the
  /// trash through [PhotoLibrary.delete]. Filenames may collide; the last asset
  /// with a given filename wins, which is acceptable for a best-effort mobile
  /// RAW prune. Each filename is listed at most once so the review rows and the
  /// deletion mapping stay one-to-one (a duplicated filename would otherwise
  /// show twice while only one of them could ever map back for deletion).
  MobilePairing pairingFromFilenames() {
    final idByFilename = <String, String>{};
    final filenames = <String>[];
    for (final asset in _assetById.values) {
      if (!idByFilename.containsKey(asset.filename)) {
        filenames.add(asset.filename);
      }
      idByFilename[asset.filename] = asset.id;
    }
    return MobilePairing(classifyPairing(filenames), idByFilename);
  }
}

/// Synthesizes a [FolderScanResult] whose `photos` are the engine-facing proxy
/// [proxyPaths], with per-format counts derived from the original [assets]'
/// extensions.
///
/// This lets every existing desktop runner (Duplicates, Shrink, …) that reads
/// `scan.photos` work UNCHANGED on mobile: it scans real proxy files. There are
/// no GPS source files or unsupported files on mobile, so those lists are empty.
/// [assets] and [proxyPaths] must be parallel; empty proxy paths (failed
/// exports) are dropped from `photos` but still counted in `files`.
FolderScanResult synthesizeScan(
  List<LibraryAsset> assets,
  List<String> proxyPaths,
) {
  assert(
    assets.length == proxyPaths.length,
    'assets and proxyPaths must be parallel',
  );
  final photos = <String>[];
  final byExtension = <String, int>{};
  for (var i = 0; i < assets.length; i++) {
    final proxy = proxyPaths[i];
    if (proxy.isEmpty) continue;
    photos.add(proxy);
    // Count by the ORIGINAL asset's format (heic/jpg/dng/…), not the proxy's
    // `.jpg`, so the workspace's per-format breakdown reflects the real library.
    final ext = assets[i].ext.isEmpty ? 'jpg' : assets[i].ext;
    byExtension.update(ext, (n) => n + 1, ifAbsent: () => 1);
  }
  return FolderScanResult(
    files: photos.length,
    dirs: 1,
    byExtension: byExtension,
    photos: photos,
    gpxFiles: const [],
    kmlFiles: const [],
    googleFiles: const [],
    unsupported: const [],
    unsupportedByExtension: const {},
    unsupportedByCategory: const {},
    unsupportedTotal: 0,
  );
}

/// A geotagged asset ready to plot on the Explore map on mobile — coordinates
/// come from enumeration, and the image loads by [assetId] (not a file path).
class MobileExplorePhoto {
  /// Creates a plottable mobile photo.
  const MobileExplorePhoto({
    required this.assetId,
    required this.latitude,
    required this.longitude,
    this.proxyPath,
    this.date,
    this.width = 0,
    this.height = 0,
  });

  /// The platform asset id, used to load the thumbnail on demand.
  final String assetId;

  /// The already-exported proxy JPEG path for this asset, or null when none was
  /// exported — the decodable file the map renders.
  final String? proxyPath;

  /// Latitude in signed decimal degrees.
  final double latitude;

  /// Longitude in signed decimal degrees.
  final double longitude;

  /// Capture date, when known.
  final DateTime? date;

  /// Original pixel width of the asset (0 when the platform did not report it),
  /// surfaced in the Explore detail panel's info lines.
  final int width;

  /// Original pixel height of the asset (0 when unknown).
  final int height;
}

/// The mobile RAW pairing plus the filename→asset-id lookup needed to route a
/// chosen filename back through the photo library for deletion.
class MobilePairing {
  /// Wraps a [pairing] keyed by filename with its [idByFilename] lookup.
  const MobilePairing(this.pairing, this.idByFilename);

  /// The classification (each `PairedFile.path` is an asset filename).
  final RawPairing pairing;

  /// Asset id for each filename in [pairing].
  final Map<String, String> idByFilename;

  /// Asset ids for the chosen [filenames], dropping any unknown filename.
  List<String> idsFor(Iterable<String> filenames) => [
    for (final name in filenames)
      if (idByFilename[name] != null) idByFilename[name]!,
  ];
}

/// Classifies the tag outcome for EVERY [photo], mirroring the desktop
/// `TagService` per-photo decision exactly so the mobile summary tallies the
/// same status vocabulary (noTimestamp / alreadyTagged / noGps / tagged /
/// interpolated). The write itself stays in the controller (it needs the
/// plugin), so a [MobileTagOutcome] whose [MobileTagOutcome.location] is
/// non-null is the only one that still needs a `writeGps`; the rest are
/// terminal skip results.
///
/// The decision order matches desktop `_tagOne`: a missing capture date is
/// [PhotoStatus.noTimestamp]; an already-geotagged asset with [replace] off is
/// [PhotoStatus.alreadyTagged]; no source coordinate within [maxTimeDiff] is
/// [PhotoStatus.noGps]; otherwise the fix's [GpsMethod] picks `tagged` (exact)
/// vs `interpolated`. Pure, so the classification is unit-testable.
List<MobileTagOutcome> classifyTagOutcomes(
  Iterable<MobileTagPhoto> photos,
  SourcePool pool, {
  required Duration maxTimeDiff,
  required bool replace,
}) {
  final locator = Locator(gpx: pool.track, google: pool.google);
  final out = <MobileTagOutcome>[];
  for (final photo in photos) {
    final date = photo.date;
    if (date == null) {
      out.add(
        MobileTagOutcome(
          assetId: photo.assetId,
          status: PhotoStatus.noTimestamp,
        ),
      );
      continue;
    }
    if (photo.hasGps && !replace) {
      out.add(
        MobileTagOutcome(
          assetId: photo.assetId,
          status: PhotoStatus.alreadyTagged,
        ),
      );
      continue;
    }
    final fix = locator.locate(date, maxTimeDiff);
    if (fix == null) {
      out.add(
        MobileTagOutcome(assetId: photo.assetId, status: PhotoStatus.noGps),
      );
      continue;
    }
    final status = fix.method == GpsMethod.exact
        ? PhotoStatus.tagged
        : PhotoStatus.interpolated;
    out.add(
      MobileTagOutcome(assetId: photo.assetId, status: status, location: fix),
    );
  }
  return out;
}

/// One asset's classified tag outcome. When [location] is non-null the asset
/// resolved to a fix and the controller must still write it (or report a dry
/// run); otherwise [status] is a terminal skip reason.
class MobileTagOutcome {
  /// Creates an outcome for [assetId] with [status] and an optional resolved
  /// [location].
  const MobileTagOutcome({
    required this.assetId,
    required this.status,
    this.location,
  });

  /// The platform asset id.
  final String assetId;

  /// The desktop-equivalent [PhotoStatus] for this asset before any write.
  final PhotoStatus status;

  /// The resolved coordinate when one was found (then [status] is `tagged` or
  /// `interpolated`); null for every skip outcome.
  final LocationResult? location;
}

/// The minimal asset facts the mobile tag resolution needs: which asset, when
/// it was captured, and whether it already carries GPS.
class MobileTagPhoto {
  /// Creates a tag input for [assetId] captured at [date].
  const MobileTagPhoto({
    required this.assetId,
    required this.date,
    this.hasGps = false,
  });

  /// The platform asset id to write GPS onto.
  final String assetId;

  /// Capture instant, or null when unknown (then the photo is skipped).
  final DateTime? date;

  /// Whether the asset already has coordinates.
  final bool hasGps;
}

/// Lower-cased basename without its extension — the RAW-companion match key,
/// kept here so the mobile filename pairing matches the engine's logic.
String _stem(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot <= 0 ? filename : filename.substring(0, dot);
}
