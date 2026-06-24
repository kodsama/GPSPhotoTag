import 'package:xml/xml.dart';

import '../../domain/timed_point.dart';

/// Parses a GPX document into time-ordered [TimedPoint]s.
///
/// Reads `<trkpt>`, `<rtept>` and `<wpt>` elements — each must carry `lat`/`lon`
/// attributes and a `<time>` child (ISO-8601). Points without a parseable time
/// are skipped (waypoints often lack one). The result is sorted ascending by
/// time, which the [locator] relies on for binary search.
///
/// Throws [FormatException] if [xml] is not well-formed GPX.
List<TimedPoint> parseGpx(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Invalid GPX XML: $e');
  }

  final points = <TimedPoint>[];
  for (final tag in const ['trkpt', 'rtept', 'wpt']) {
    for (final el in doc.findAllElements(tag)) {
      final point = _pointFrom(el);
      if (point != null) points.add(point);
    }
  }
  points.sort();
  return points;
}

TimedPoint? _pointFrom(XmlElement el) {
  final lat = double.tryParse(el.getAttribute('lat') ?? '');
  final lon = double.tryParse(el.getAttribute('lon') ?? '');
  if (lat == null || lon == null) return null;

  final timeText = el.getElement('time')?.innerText.trim();
  if (timeText == null || timeText.isEmpty) return null;
  final time = DateTime.tryParse(timeText);
  if (time == null) return null;

  return TimedPoint(latitude: lat, longitude: lon, time: time);
}
