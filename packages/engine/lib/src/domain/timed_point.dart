import 'package:meta/meta.dart';

/// A single GPS fix at a known instant.
///
/// Coordinates are WGS-84 decimal degrees; [time] is always stored in UTC so
/// points from different sources (GPX, Google) sort and compare unambiguously.
@immutable
class TimedPoint implements Comparable<TimedPoint> {
  /// Creates a fix at [time] (coerced to UTC) and [latitude]/[longitude].
  TimedPoint({
    required this.latitude,
    required this.longitude,
    required DateTime time,
  }) : time = time.toUtc();

  /// Latitude in decimal degrees, positive north.
  final double latitude;

  /// Longitude in decimal degrees, positive east.
  final double longitude;

  /// The instant of the fix, in UTC.
  final DateTime time;

  /// Points are ordered by [time]; this drives binary search in the locator.
  @override
  int compareTo(TimedPoint other) => time.compareTo(other.time);

  @override
  String toString() =>
      'TimedPoint($latitude, $longitude @ ${time.toIso8601String()})';

  @override
  bool operator ==(Object other) =>
      other is TimedPoint &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.time == time;

  @override
  int get hashCode => Object.hash(latitude, longitude, time);
}
