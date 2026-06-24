import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

/// The location-source kinds the engine can parse.
const locationSources = [
  {
    'id': 'gpx',
    'name': 'GPX track',
    'kind': 'local',
    'extensions': ['gpx'],
    'note': 'Highest precision. Best for watch/app/handheld recordings.',
  },
  {
    'id': 'google_records',
    'name': 'Google Takeout Records.json',
    'kind': 'local',
    'extensions': ['json'],
    'note': 'Your entire location history.',
  },
  {
    'id': 'google_timeline',
    'name': 'Google Timeline export',
    'kind': 'local',
    'extensions': ['json'],
    'note': '2024+ mobile semanticSegments and legacy timelineObjects.',
  },
  {
    'id': 'google_kml',
    'name': 'Google Timeline KML',
    'kind': 'local',
    'extensions': ['kml'],
    'note': 'Per-day KML export.',
  },
];

/// Tile/geocoder providers used by the heatmap (the reinterpreted "catalog").
const mapProviders = [
  {
    'id': 'carto_light',
    'name': 'CARTO Positron (light)',
    'type': 'tiles',
    'kind': 'cloud',
    'recommended': true,
    'attribution': '© OpenStreetMap contributors © CARTO',
  },
  {
    'id': 'osm',
    'name': 'OpenStreetMap standard',
    'type': 'tiles',
    'kind': 'cloud',
    'recommended': false,
    'attribution': '© OpenStreetMap contributors',
  },
  {
    'id': 'nominatim',
    'name': 'OSM Nominatim',
    'type': 'geocoder',
    'kind': 'cloud',
    'recommended': true,
    'attribution': '© OpenStreetMap contributors',
  },
];

void _print(bool json, String key, List<Map<String, Object?>> items) {
  if (json) {
    stdout.writeln(jsonEncode({key: items}));
  } else {
    for (final i in items) {
      stdout.writeln('${i['id']}\t${i['name']}  (${i['kind']})');
    }
  }
}

/// `list-sources` — enumerate supported location sources.
class ListSourcesCommand extends Command<int> {
  @override
  String get name => 'list-sources';

  @override
  String get description => 'List supported location sources.';

  @override
  Future<int> run() async {
    _print(globalResults!.flag('json'), 'sources',
        locationSources.cast<Map<String, Object?>>());
    return 0;
  }
}

/// `list-providers` — enumerate tile/geocoder providers.
class ListProvidersCommand extends Command<int> {
  @override
  String get name => 'list-providers';

  @override
  String get description => 'List map tile and geocoder providers.';

  @override
  Future<int> run() async {
    _print(globalResults!.flag('json'), 'providers',
        mapProviders.cast<Map<String, Object?>>());
    return 0;
  }
}
