import 'package:stunda_engine/src/data/sources/google_source.dart';
import 'package:stunda_engine/src/domain/timed_point.dart';
import 'package:test/test.dart';

bool _isSorted(List<TimedPoint> points) {
  for (var i = 1; i < points.length; i++) {
    if (points[i - 1].time.isAfter(points[i].time)) return false;
  }
  return true;
}

void main() {
  group('parseGoogleRecords', () {
    test('parses ISO timestamps and converts E7 coordinates', () {
      const json = '''
      {"locations":[
        {"latitudeE7":427077000,"longitudeE7":183441000,
         "timestamp":"2026-06-22T12:00:00Z"}
      ]}''';
      final points = parseGoogleRecords(json);
      expect(points, hasLength(1));
      expect(points.first.latitude, closeTo(42.7077, 1e-9));
      expect(points.first.longitude, closeTo(18.3441, 1e-9));
      expect(points.first.time.isUtc, isTrue);
    });

    test('parses legacy timestampMs (epoch ms string)', () {
      const json = '''
      {"locations":[
        {"latitudeE7":427077000,"longitudeE7":183441000,
         "timestampMs":"1690000000000"}
      ]}''';
      final points = parseGoogleRecords(json);
      expect(points, hasLength(1));
      expect(
        points.first.time,
        DateTime.fromMillisecondsSinceEpoch(1690000000000, isUtc: true),
      );
    });

    test('skips entries missing coordinates or time, returns sorted', () {
      const json = '''
      {"locations":[
        {"latitudeE7":300000000,"longitudeE7":300000000,
         "timestamp":"2026-06-22T15:00:00Z"},
        {"longitudeE7":183441000,"timestamp":"2026-06-22T12:00:00Z"},
        {"latitudeE7":100000000,"longitudeE7":100000000,
         "timestamp":"not-a-date"},
        {"latitudeE7":200000000,"longitudeE7":200000000,
         "timestamp":"2026-06-22T10:00:00Z"}
      ]}''';
      final points = parseGoogleRecords(json);
      expect(points, hasLength(2));
      expect(_isSorted(points), isTrue);
      expect(points.first.time.hour, 10);
    });

    test('returns empty on malformed JSON or missing locations', () {
      expect(parseGoogleRecords('not json'), isEmpty);
      expect(parseGoogleRecords('{}'), isEmpty);
    });

    test('converts E7 coordinates supplied as numeric strings', () {
      // Some exports stringify latitudeE7/longitudeE7; _degreesFromE7 must
      // double.tryParse them rather than skip the entry.
      const json = '''
      {"locations":[
        {"latitudeE7":"427077000","longitudeE7":"183441000",
         "timestamp":"2026-06-22T12:00:00Z"}
      ]}''';
      final points = parseGoogleRecords(json);
      expect(points, hasLength(1));
      expect(points.first.latitude, closeTo(42.7077, 1e-9));
      expect(points.first.longitude, closeTo(18.3441, 1e-9));
    });

    test('accepts timestampMs supplied as a JSON number', () {
      // _timeFromEpochMs handles a num directly (not only a numeric string).
      const json = '''
      {"locations":[
        {"latitudeE7":427077000,"longitudeE7":183441000,
         "timestampMs":1690000000000}
      ]}''';
      final points = parseGoogleRecords(json);
      expect(points, hasLength(1));
      expect(
        points.first.time,
        DateTime.fromMillisecondsSinceEpoch(1690000000000, isUtc: true),
      );
    });
  });

  group('parseGoogleTimeline semanticSegments', () {
    test('parses timelinePath point strings', () {
      const json = '''
      {"semanticSegments":[
        {"timelinePath":[
          {"point":"42.7077°, 18.3441°","time":"2026-06-22T12:00:00Z"},
          {"point":"42.7000°, 18.3000°","time":"2026-06-22T11:00:00Z"}
        ]}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(2));
      expect(_isSorted(points), isTrue);
      expect(points.last.latitude, closeTo(42.7077, 1e-9));
      expect(points.last.longitude, closeTo(18.3441, 1e-9));
    });

    test('accepts latLng key with same format', () {
      const json = '''
      {"semanticSegments":[
        {"timelinePath":[
          {"latLng":"1.5°, 2.5°","time":"2026-06-22T12:00:00Z"}
        ]}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(1));
      expect(points.first.latitude, closeTo(1.5, 1e-9));
      expect(points.first.longitude, closeTo(2.5, 1e-9));
    });

    test('visit emits points at startTime and endTime', () {
      const json = '''
      {"semanticSegments":[
        {"startTime":"2026-06-22T08:00:00Z","endTime":"2026-06-22T09:00:00Z",
         "visit":{"topCandidate":{"placeLocation":{"latLng":"3.0°, 4.0°"}}}}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(2));
      expect(_isSorted(points), isTrue);
      expect(points.first.latitude, closeTo(3.0, 1e-9));
    });

    test('visit falls back to topCandidate.latLng without placeLocation', () {
      // No placeLocation: _segmentLatLng must read latLng off the candidate.
      const json = '''
      {"semanticSegments":[
        {"startTime":"2026-06-22T08:00:00Z","endTime":"2026-06-22T09:00:00Z",
         "visit":{"topCandidate":{"latLng":"7.5°, 8.5°"}}}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(2));
      expect(points.first.latitude, closeTo(7.5, 1e-9));
      expect(points.first.longitude, closeTo(8.5, 1e-9));
    });

    test('activity emits a single point when only startTime present', () {
      const json = '''
      {"semanticSegments":[
        {"startTime":"2026-06-22T08:00:00Z",
         "activity":{"latLng":"5.0°, 6.0°"}}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(1));
      expect(points.first.longitude, closeTo(6.0, 1e-9));
    });

    test('skips segments lacking coordinates', () {
      const json = '''
      {"semanticSegments":[
        {"startTime":"2026-06-22T08:00:00Z","endTime":"2026-06-22T09:00:00Z"}
      ]}''';
      expect(parseGoogleTimeline(json), isEmpty);
    });
  });

  group('parseGoogleTimeline timelineObjects', () {
    test('parses placeVisit and activitySegment', () {
      const json = '''
      {"timelineObjects":[
        {"placeVisit":{
          "location":{"latitudeE7":427077000,"longitudeE7":183441000},
          "duration":{"startTimestamp":"2026-06-22T12:00:00Z",
                      "endTimestamp":"2026-06-22T13:00:00Z"}}},
        {"activitySegment":{
          "startLocation":{"latitudeE7":420000000,"longitudeE7":180000000},
          "endLocation":{"latitudeE7":430000000,"longitudeE7":190000000},
          "duration":{"startTimestamp":"2026-06-22T10:00:00Z",
                      "endTimestamp":"2026-06-22T11:00:00Z"}}}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(4));
      expect(_isSorted(points), isTrue);
      expect(points.first.time.hour, 10);
      expect(points.first.latitude, closeTo(42.0, 1e-9));
    });

    test('skips activitySegment with missing coordinates', () {
      const json = '''
      {"timelineObjects":[
        {"activitySegment":{
          "startLocation":{"latitudeE7":420000000,"longitudeE7":180000000},
          "duration":{"startTimestamp":"2026-06-22T10:00:00Z",
                      "endTimestamp":"2026-06-22T11:00:00Z"}}}
      ]}''';
      final points = parseGoogleTimeline(json);
      expect(points, hasLength(1));
      expect(points.first.time.hour, 10);
    });
  });

  group('parseGoogleKml', () {
    test('parses gx:Track alternating when/coord', () {
      const kml = '''
      <kml xmlns:gx="http://www.google.com/kml/ext/2.2">
        <Placemark><gx:Track>
          <when>2026-06-22T12:00:00Z</when>
          <gx:coord>18.3441 42.7077 0</gx:coord>
          <when>2026-06-22T11:00:00Z</when>
          <gx:coord>18.3000 42.7000 0</gx:coord>
        </gx:Track></Placemark>
      </kml>''';
      final points = parseGoogleKml(kml);
      expect(points, hasLength(2));
      expect(_isSorted(points), isTrue);
      expect(points.last.latitude, closeTo(42.7077, 1e-9));
      expect(points.last.longitude, closeTo(18.3441, 1e-9));
    });

    test('parses Placemark Point with TimeStamp', () {
      const kml = '''
      <kml>
        <Placemark>
          <Point><coordinates>18.3441,42.7077,0</coordinates></Point>
          <TimeStamp><when>2026-06-22T12:00:00Z</when></TimeStamp>
        </Placemark>
      </kml>''';
      final points = parseGoogleKml(kml);
      expect(points, hasLength(1));
      expect(points.first.latitude, closeTo(42.7077, 1e-9));
      expect(points.first.longitude, closeTo(18.3441, 1e-9));
    });

    test('skips Placemark without timestamp and returns empty on bad XML', () {
      const kml = '''
      <kml><Placemark>
        <Point><coordinates>18.3441,42.7077,0</coordinates></Point>
      </Placemark></kml>''';
      expect(parseGoogleKml(kml), isEmpty);
      expect(parseGoogleKml('not <xml'), isEmpty);
    });
  });

  group('parseGoogleAuto', () {
    test('sniffs KML', () {
      const kml = '''
      <kml><Placemark>
        <Point><coordinates>18.3441,42.7077,0</coordinates></Point>
        <TimeStamp><when>2026-06-22T12:00:00Z</when></TimeStamp>
      </Placemark></kml>''';
      expect(parseGoogleAuto(kml), hasLength(1));
    });

    test('sniffs timeline and records JSON', () {
      const timeline = '''
      {"semanticSegments":[
        {"timelinePath":[{"point":"1.0°, 2.0°","time":"2026-06-22T12:00:00Z"}]}
      ]}''';
      const records = '''
      {"locations":[
        {"latitudeE7":427077000,"longitudeE7":183441000,
         "timestamp":"2026-06-22T12:00:00Z"}
      ]}''';
      expect(parseGoogleAuto(timeline), hasLength(1));
      expect(parseGoogleAuto(records), hasLength(1));
      expect(parseGoogleAuto('{"unknown":1}'), isEmpty);
    });
  });
}
