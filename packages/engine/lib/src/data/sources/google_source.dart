import 'dart:convert';

import 'package:xml/xml.dart';

import '../../domain/timed_point.dart';

/// Parses a Takeout `Records.json` into time-ordered [TimedPoint]s.
///
/// Reads the `locations` array, where each entry carries `latitudeE7` /
/// `longitudeE7` (degrees × 1e7) and either an ISO-8601 `timestamp` or a
/// legacy `timestampMs` (epoch-millisecond string). Entries missing coordinates
/// or a parseable time are skipped. The result is sorted ascending by time.
List<TimedPoint> parseGoogleRecords(String jsonText) {
  final decoded = _tryDecode(jsonText);
  final locations = (decoded is Map ? decoded['locations'] : null);
  final points = <TimedPoint>[];
  if (locations is List) {
    for (final entry in locations) {
      if (entry is! Map) continue;
      final time = _timeFromRecord(entry);
      final point = _pointFromE7(entry, time);
      if (point != null) points.add(point);
    }
  }
  points.sort();
  return points;
}

/// Parses a Google Timeline export into time-ordered [TimedPoint]s.
///
/// Handles both the 2024+ mobile `semanticSegments` shape (with `timelinePath`,
/// `visit` and `activity` segments) and the legacy `timelineObjects` shape
/// (`placeVisit` / `activitySegment`). Entries missing coordinates or a
/// parseable time are skipped. The result is sorted ascending by time.
List<TimedPoint> parseGoogleTimeline(String jsonText) {
  final decoded = _tryDecode(jsonText);
  final points = <TimedPoint>[];
  if (decoded is Map) {
    final semantic = decoded['semanticSegments'];
    if (semantic is List) {
      for (final segment in semantic) {
        if (segment is Map) _addSemanticSegment(segment, points);
      }
    }
    final legacy = decoded['timelineObjects'];
    if (legacy is List) {
      for (final object in legacy) {
        if (object is Map) _addTimelineObject(object, points);
      }
    }
  }
  points.sort();
  return points;
}

/// Parses KML/KMZ-extracted XML into time-ordered [TimedPoint]s.
///
/// Handles `<gx:Track>` with alternating `<when>` and `<gx:coord>` children
/// (coordinates ordered `lon lat alt`) as well as `<Placemark>` elements with a
/// `<Point><coordinates>` (`lon,lat,alt`) and a `<TimeStamp><when>`. Entries
/// missing coordinates or a parseable time are skipped. The result is sorted
/// ascending by time.
List<TimedPoint> parseGoogleKml(String kmlText) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(kmlText);
  } on XmlException {
    return const [];
  }

  final points = <TimedPoint>[];
  for (final track
      in doc.descendantElements.where((e) => e.localName == 'Track')) {
    _addGxTrack(track, points);
  }
  for (final placemark in doc.findAllElements('Placemark')) {
    _addPlacemark(placemark, points);
  }
  points.sort();
  return points;
}

/// Parses any supported Google location format by sniffing [content].
///
/// Content starting with `<` is treated as KML; otherwise it is JSON, routed to
/// [parseGoogleTimeline] when it contains `semanticSegments` or
/// `timelineObjects`, and to [parseGoogleRecords] when it contains `locations`.
/// The result is sorted ascending by time.
List<TimedPoint> parseGoogleAuto(String content) {
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('<')) return parseGoogleKml(content);

  final List<TimedPoint> points;
  if (content.contains('"semanticSegments"') ||
      content.contains('"timelineObjects"')) {
    points = parseGoogleTimeline(content);
  } else if (content.contains('"locations"')) {
    points = parseGoogleRecords(content);
  } else {
    points = <TimedPoint>[];
  }
  return points;
}

// --- Records helpers ------------------------------------------------------

DateTime? _timeFromRecord(Map<dynamic, dynamic> entry) {
  final timestamp = entry['timestamp'];
  if (timestamp is String) {
    final parsed = DateTime.tryParse(timestamp);
    if (parsed != null) return parsed;
  }
  return _timeFromEpochMs(entry['timestampMs']);
}

TimedPoint? _pointFromE7(Map<dynamic, dynamic> entry, DateTime? time) {
  if (time == null) return null;
  final lat = _degreesFromE7(entry['latitudeE7']);
  final lng = _degreesFromE7(entry['longitudeE7']);
  if (lat == null || lng == null) return null;
  return TimedPoint(latitude: lat, longitude: lng, time: time);
}

double? _degreesFromE7(Object? value) {
  if (value is num) return value / 1e7;
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed / 1e7;
  }
  return null;
}

DateTime? _timeFromEpochMs(Object? value) {
  final ms = value is num
      ? value.toInt()
      : (value is String ? int.tryParse(value) : null);
  if (ms == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

// --- Timeline (semanticSegments) helpers ----------------------------------

void _addSemanticSegment(
  Map<dynamic, dynamic> segment,
  List<TimedPoint> out,
) {
  final path = segment['timelinePath'];
  if (path is List) {
    for (final entry in path) {
      if (entry is! Map) continue;
      final coords = _parseLatLngString(entry['point'] ?? entry['latLng']);
      final time = _parseTime(entry['time']);
      _emit(coords, time, out);
    }
  }

  final start = _parseTime(segment['startTime']);
  final end = _parseTime(segment['endTime']);
  if (start == null && end == null) return;

  final coords = _segmentLatLng(segment);
  if (coords == null) return;
  _emit(coords, start, out);
  _emit(coords, end, out);
}

({double lat, double lng})? _segmentLatLng(Map<dynamic, dynamic> segment) {
  final visit = segment['visit'];
  if (visit is Map) {
    final candidate = visit['topCandidate'];
    if (candidate is Map) {
      final location = candidate['placeLocation'];
      if (location is Map) {
        final coords = _parseLatLngString(location['latLng']);
        if (coords != null) return coords;
      }
      final coords = _parseLatLngString(candidate['latLng']);
      if (coords != null) return coords;
    }
  }
  final activity = segment['activity'];
  if (activity is Map) {
    final coords = _parseLatLngString(activity['latLng']);
    if (coords != null) return coords;
  }
  return _parseLatLngString(segment['latLng']);
}

/// Parses a Google `"<lat>°, <lng>°"` string into a coordinate pair.
({double lat, double lng})? _parseLatLngString(Object? value) {
  if (value is! String) return null;
  final parts = value.replaceAll('°', '').split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0].trim());
  final lng = double.tryParse(parts[1].trim());
  if (lat == null || lng == null) return null;
  return (lat: lat, lng: lng);
}

// --- Timeline (timelineObjects) helpers -----------------------------------

void _addTimelineObject(Map<dynamic, dynamic> object, List<TimedPoint> out) {
  final placeVisit = object['placeVisit'];
  if (placeVisit is Map) {
    final coords = _objectLatLng(placeVisit['location']);
    final duration = placeVisit['duration'];
    _emitDuration(coords, duration, out);
  }

  final activity = object['activitySegment'];
  if (activity is Map) {
    final duration = activity['duration'];
    final startCoords = _objectLatLng(activity['startLocation']);
    final endCoords = _objectLatLng(activity['endLocation']);
    if (duration is Map) {
      _emit(startCoords, _parseTime(duration['startTimestamp']), out);
      _emit(endCoords, _parseTime(duration['endTimestamp']), out);
    }
  }
}

({double lat, double lng})? _objectLatLng(Object? location) {
  if (location is! Map) return null;
  final lat = _degreesFromE7(location['latitudeE7']);
  final lng = _degreesFromE7(location['longitudeE7']);
  if (lat == null || lng == null) return null;
  return (lat: lat, lng: lng);
}

void _emitDuration(
  ({double lat, double lng})? coords,
  Object? duration,
  List<TimedPoint> out,
) {
  if (duration is! Map) return;
  _emit(coords, _parseTime(duration['startTimestamp']), out);
  _emit(coords, _parseTime(duration['endTimestamp']), out);
}

// --- KML helpers ----------------------------------------------------------

void _addGxTrack(XmlElement track, List<TimedPoint> out) {
  final whens = <DateTime?>[];
  for (final when in track.childElements.where((e) => e.localName == 'when')) {
    whens.add(_parseTime(when.innerText));
  }
  final coords = <({double lat, double lng})?>[];
  for (final coord
      in track.childElements.where((e) => e.localName == 'coord')) {
    coords.add(_parseCoordTriplet(coord.innerText, separator: ' '));
  }
  final count = whens.length < coords.length ? whens.length : coords.length;
  for (var i = 0; i < count; i++) {
    _emit(coords[i], whens[i], out);
  }
}

void _addPlacemark(XmlElement placemark, List<TimedPoint> out) {
  final point = placemark.getElement('Point');
  final coordsText = point?.getElement('coordinates')?.innerText;
  final coords =
      coordsText == null ? null : _parseCoordTriplet(coordsText, separator: ',');

  final timeStamp = placemark.getElement('TimeStamp');
  final time = _parseTime(timeStamp?.getElement('when')?.innerText);
  _emit(coords, time, out);
}

/// Parses a KML coordinate triplet `lon<sep>lat<sep>alt` into a pair.
({double lat, double lng})? _parseCoordTriplet(
  String text, {
  required String separator,
}) {
  final parts = text
      .trim()
      .split(separator)
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  if (parts.length < 2) return null;
  final lng = double.tryParse(parts[0].trim());
  final lat = double.tryParse(parts[1].trim());
  if (lat == null || lng == null) return null;
  return (lat: lat, lng: lng);
}

// --- Shared helpers -------------------------------------------------------

Object? _tryDecode(String jsonText) {
  try {
    return jsonDecode(jsonText);
  } on FormatException {
    return null;
  }
}

DateTime? _parseTime(Object? value) =>
    value is String ? DateTime.tryParse(value.trim()) : null;

void _emit(
  ({double lat, double lng})? coords,
  DateTime? time,
  List<TimedPoint> out,
) {
  if (coords == null || time == null) return;
  out.add(TimedPoint(latitude: coords.lat, longitude: coords.lng, time: time));
}
