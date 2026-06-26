import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

/// Extensions Flutter's `Image.file` can decode for a thumbnail/fullscreen
/// view. HEIC/HEIF and RAW are excluded — they fall back to a placeholder.
const _decodableExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

/// Whether [path] is an image Flutter can decode (so we can show a real
/// thumbnail); HEIC/RAW and anything else get a typed placeholder instead.
bool isDecodableImage(String path) {
  final e = p.extension(path);
  final ext = e.isEmpty ? '' : e.substring(1).toLowerCase();
  return _decodableExtensions.contains(ext);
}

/// Extensions Flutter's `Image` can't decode natively but exiftool can extract
/// an embedded JPEG preview from — RAW formats plus HEIC/HEIF.
const _extractableExtensions = {
  'raf',
  'nef',
  'cr2',
  'cr3',
  'dng',
  'arw',
  'orf',
  'rw2',
  'pef',
  'srw',
  'raw', //
  'heic', 'heif',
};

/// Whether [path] needs an exiftool preview extraction to render: true for RAW
/// and HEIC/HEIF (which Flutter can't decode but carry an embedded JPEG), false
/// for natively decodable images (jpg/png/webp/…) and everything else.
///
/// Pure, so the gate that decides whether to call the extractor is unit-testable
/// without a widget tree.
bool needsPreviewExtraction(String path) {
  final e = p.extension(path);
  final ext = e.isEmpty ? '' : e.substring(1).toLowerCase();
  return _extractableExtensions.contains(ext);
}

/// The upper-case file-type label for [path] (e.g. `HEIC`, `RAF`), for the
/// placeholder shown when an image can't be decoded.
String fileTypeLabel(String path) {
  final e = p.extension(path);
  return e.isEmpty ? 'FILE' : e.substring(1).toUpperCase();
}

/// One geotagged photo to plot on the Explore map.
///
/// Carries the file [path], its decimal-degree coordinates, and the [meta] read
/// from exiftool (used to render the detail panel — dimensions, date, …). This
/// is plain, Flutter-free data so the grouping/navigation logic below is unit
/// testable without a widget tree.
class ExplorePhoto {
  /// Creates a plottable photo at ([latitude], [longitude]).
  const ExplorePhoto({
    required this.path,
    required this.latitude,
    required this.longitude,
    this.meta,
  });

  /// Builds an [ExplorePhoto] from a [FileMeta] that carries coordinates, or
  /// null when the meta has no GPS (so callers can `.whereType` non-null).
  static ExplorePhoto? fromMeta(FileMeta meta) {
    final lat = meta.latitude, lon = meta.longitude;
    if (!meta.hasGps || lat == null || lon == null) return null;
    return ExplorePhoto(
      path: meta.path,
      latitude: lat,
      longitude: lon,
      meta: meta,
    );
  }

  /// The image file path.
  final String path;

  /// Latitude in signed decimal degrees.
  final double latitude;

  /// Longitude in signed decimal degrees.
  final double longitude;

  /// The metadata behind this photo (dimensions, date), when known.
  final FileMeta? meta;

  /// The coordinate as a flutter_map [LatLng].
  LatLng get position => LatLng(latitude, longitude);

  /// The capture date from [meta], or null when unknown — the field the
  /// Timeline range filter keys off (null-dated photos are never filtered out).
  DateTime? get date => meta?.date;
}

/// A cluster of photos that share (to a rounding precision) one coordinate.
///
/// At the highest zoom the marker-cluster plugin stops clustering distinct
/// points, but several photos can still sit at the *exact* same spot (a burst,
/// or a phone that quantises GPS). We pre-group those into one [MapPoint] so a
/// single marker can page through them in the detail panel.
class MapPoint {
  /// Creates a point at ([latitude], [longitude]) holding [photos].
  const MapPoint({
    required this.latitude,
    required this.longitude,
    required this.photos,
  });

  /// Latitude of the group's representative position.
  final double latitude;

  /// Longitude of the group's representative position.
  final double longitude;

  /// The photos at this point, in stable input order.
  final List<ExplorePhoto> photos;

  /// The group's position as a flutter_map [LatLng].
  LatLng get position => LatLng(latitude, longitude);

  /// Number of photos held here.
  int get count => photos.length;
}

/// Groups [photos] into [MapPoint]s, merging any that round to the same
/// coordinate at [precision] decimal places (≈1 m at 5 dp).
///
/// Pure and order-stable: points come out in first-seen order, and each point's
/// photos preserve their input order, so the map and the detail pager are
/// deterministic. A higher [precision] merges fewer photos.
List<MapPoint> groupPhotosIntoPoints(
  Iterable<ExplorePhoto> photos, {
  int precision = 5,
}) {
  final order = <String>[];
  final groups = <String, List<ExplorePhoto>>{};
  for (final photo in photos) {
    final key =
        '${photo.latitude.toStringAsFixed(precision)},'
        '${photo.longitude.toStringAsFixed(precision)}';
    final bucket = groups.putIfAbsent(key, () {
      order.add(key);
      return <ExplorePhoto>[];
    });
    bucket.add(photo);
  }
  return [
    for (final key in order)
      MapPoint(
        latitude: groups[key]!.first.latitude,
        longitude: groups[key]!.first.longitude,
        photos: groups[key]!,
      ),
  ];
}

/// The bounding box of [points], or null when there are none.
///
/// Returned as a (south-west, north-east) pair of [LatLng]s suitable for
/// `CameraFit.bounds`. A single point yields a zero-area box (the caller pads /
/// clamps the zoom).
({LatLng southWest, LatLng northEast})? boundsOf(Iterable<MapPoint> points) {
  double? minLat, maxLat, minLon, maxLon;
  for (final p in points) {
    minLat = (minLat == null || p.latitude < minLat) ? p.latitude : minLat;
    maxLat = (maxLat == null || p.latitude > maxLat) ? p.latitude : maxLat;
    minLon = (minLon == null || p.longitude < minLon) ? p.longitude : minLon;
    maxLon = (maxLon == null || p.longitude > maxLon) ? p.longitude : maxLon;
  }
  if (minLat == null) return null;
  return (
    southWest: LatLng(minLat, minLon!),
    northEast: LatLng(maxLat!, maxLon!),
  );
}
