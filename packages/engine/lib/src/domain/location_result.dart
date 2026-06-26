import 'package:meta/meta.dart';

/// Which kind of source produced a [LocationResult].
enum GpsSource {
  /// A user-provided GPX track (highest precision).
  gpx,

  /// Google location history (Takeout `Records.json` or a Timeline export).
  google,
}

/// How a coordinate was derived from the source points.
enum GpsMethod {
  /// A source point fell exactly on (or within rounding of) the photo time.
  exact,

  /// The coordinate was linearly interpolated between two surrounding points.
  interpolated,
}

/// A resolved coordinate for one photo, with provenance.
@immutable
class LocationResult {
  /// Creates a resolved location.
  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.source,
    required this.method,
  });

  /// Latitude in decimal degrees, positive north.
  final double latitude;

  /// Longitude in decimal degrees, positive east.
  final double longitude;

  /// The source family this fix came from.
  final GpsSource source;

  /// Whether the fix was exact or interpolated.
  final GpsMethod method;

  /// A short provenance tag for logs and rows, e.g. `gpx/exact`.
  String get provenance => '${source.name}/${method.name}';

  @override
  String toString() => 'LocationResult($latitude, $longitude, $provenance)';
}
