import '../domain/location_result.dart';
import '../domain/timed_point.dart';

/// Resolves a photo's capture time to a coordinate, preferring GPX over Google.
///
/// For each source the locator finds the bracketing points around the requested
/// time. An exact hit (a point within [exactTolerance]) is returned as
/// [GpsMethod.exact]; otherwise, when both neighbours lie within `maxTimeDiff`,
/// the position is linearly interpolated ([GpsMethod.interpolated]). If only one
/// neighbour is within range it is used as a nearest fix. When nothing qualifies
/// the source yields null and the next source is tried.
class Locator {
  /// Builds a locator over already-sorted point lists (ascending by time).
  ///
  /// Pass [gpx] and/or [google]; either may be empty. The lists are assumed
  /// sorted — [parseGpx] and the Google parsers guarantee this.
  Locator({List<TimedPoint>? gpx, List<TimedPoint>? google})
      : _gpx = gpx ?? const [],
        _google = google ?? const [];

  final List<TimedPoint> _gpx;
  final List<TimedPoint> _google;

  /// Points within this tolerance of the target count as an exact match.
  static const Duration exactTolerance = Duration(seconds: 1);

  /// Resolves [photoTime] (any timezone; compared in UTC) within [maxTimeDiff].
  ///
  /// Returns null when no source has usable coverage near the time.
  LocationResult? locate(DateTime photoTime, Duration maxTimeDiff) {
    final t = photoTime.toUtc();
    return _locateIn(_gpx, GpsSource.gpx, t, maxTimeDiff) ??
        _locateIn(_google, GpsSource.google, t, maxTimeDiff);
  }

  LocationResult? _locateIn(
    List<TimedPoint> points,
    GpsSource source,
    DateTime t,
    Duration maxDiff,
  ) {
    if (points.isEmpty) return null;

    final i = _lowerBound(points, t);
    final before = i > 0 ? points[i - 1] : null;
    final after = i < points.length ? points[i] : null;

    // Exact hit on either neighbour.
    for (final p in [after, before]) {
      if (p != null && _absDiff(p.time, t) <= exactTolerance) {
        return LocationResult(
          latitude: p.latitude,
          longitude: p.longitude,
          source: source,
          method: GpsMethod.exact,
        );
      }
    }

    final beforeOk = before != null && _absDiff(before.time, t) <= maxDiff;
    final afterOk = after != null && _absDiff(after.time, t) <= maxDiff;

    // Both neighbours in range → interpolate between them.
    if (beforeOk && afterOk) {
      return _interpolate(before, after, t, source);
    }
    // Only one side in range → nearest fix (still "interpolated" provenance:
    // it is not an exact timestamp match).
    final nearest = beforeOk ? before : (afterOk ? after : null);
    if (nearest != null) {
      return LocationResult(
        latitude: nearest.latitude,
        longitude: nearest.longitude,
        source: source,
        method: GpsMethod.interpolated,
      );
    }
    return null;
  }

  LocationResult _interpolate(
    TimedPoint a,
    TimedPoint b,
    DateTime t,
    GpsSource source,
  ) {
    final span = b.time.difference(a.time).inMicroseconds;
    final frac =
        span == 0 ? 0.0 : t.difference(a.time).inMicroseconds / span;
    final clamped = frac.clamp(0.0, 1.0);
    return LocationResult(
      latitude: a.latitude + (b.latitude - a.latitude) * clamped,
      longitude: a.longitude + (b.longitude - a.longitude) * clamped,
      source: source,
      method: GpsMethod.interpolated,
    );
  }

  /// First index whose time is >= [t] (classic lower-bound binary search).
  int _lowerBound(List<TimedPoint> points, DateTime t) {
    var lo = 0;
    var hi = points.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (points[mid].time.isBefore(t)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Duration _absDiff(DateTime a, DateTime b) =>
      Duration(microseconds: a.difference(b).inMicroseconds.abs());
}
