/// Static catalogs describing what the engine can read and draw with.
///
/// They live in the engine, not in a front-end, so the CLI (`list-sources`,
/// `list-providers`) and the MCP server (`list_sources`, `list_providers`)
/// answer from one list rather than drifting apart.
library;

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
