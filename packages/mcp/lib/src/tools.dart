import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import 'event_collector.dart';

/// One MCP tool: a name, a human description, a JSON-Schema for its arguments,
/// and an executor that runs the engine and returns a structured result.
class McpTool {
  /// Creates a tool.
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
  });

  /// Tool name as exposed to the client (snake_case).
  final String name;

  /// One-line description shown in `tools/list`.
  final String description;

  /// JSON Schema (draft-07 style) describing the `arguments` object.
  final Map<String, Object?> inputSchema;

  /// Executes the tool with validated [args]; returns a structured result map.
  final Future<Map<String, Object?>> Function(Map<String, Object?> args) run;
}

List<String> _strList(Object? v) =>
    v is List ? v.map((e) => '$e').toList() : const [];

/// Builds the GPSPhotoTag tool catalog over the engine.
///
/// [exiftoolAvailable] gates RAW-embed/HEIC; pass the result of a one-time
/// [ToolkitChecker] probe so each call doesn't re-probe.
List<McpTool> buildTools({
  ProcessRunner runner = const SystemProcessRunner(),
  bool exiftoolAvailable = true,
}) {
  BackendRegistry registry(RawMode mode) => BackendRegistry(
    runner: runner,
    rawMode: mode,
    exiftoolAvailable: exiftoolAvailable,
  );

  return [
    McpTool(
      name: 'tag_photos',
      description:
          'Write GPS EXIF into photos from GPX tracks and/or Google location '
          'history. Returns per-photo results and a status summary.',
      inputSchema: {
        'type': 'object',
        'required': ['photos'],
        'properties': {
          'photos': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Photo files or directories (recursive).',
          },
          'gpx': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'GPX files or directories.',
          },
          'maps_history': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Google Records.json / Timeline JSON / KML.',
          },
          'out': {
            'type': 'string',
            'description':
                'Output directory; copies originals. Omit to tag in '
                'place (then set overwrite=true).',
          },
          'overwrite': {
            'type': 'boolean',
            'description':
                'Modify originals in place (required when out unset).',
          },
          'replace': {
            'type': 'boolean',
            'description': 'Overwrite GPS already present in the photo.',
          },
          'raw_mode': {
            'type': 'string',
            'enum': ['auto', 'sidecar', 'embed'],
            'description': 'How to write GPS to RAW files (default auto).',
          },
          'max_time_diff': {
            'type': 'integer',
            'description':
                'Max seconds between photo time and a fix (def 300).',
          },
          'timezone': {
            'type': 'string',
            'description': 'IANA tz fallback when EXIF lacks an offset.',
          },
          'dry_run': {
            'type': 'boolean',
            'description': 'Report what would happen; write nothing.',
          },
        },
      },
      run: (args) async {
        final photos = Collectors.photos(_strList(args['photos']));
        if (photos.isEmpty) {
          return {'ok': false, 'code': 'bad_input', 'error': 'no photos found'};
        }
        final sources = loadSources(
          _strList(args['gpx']),
          _strList(args['maps_history']),
        );
        if (sources.gpx.isEmpty && sources.google.isEmpty) {
          return {
            'ok': false,
            'code': 'bad_input',
            'error': 'no location source: provide gpx and/or maps_history',
          };
        }
        final mode = RawMode.values.byName(
          (args['raw_mode'] as String?) ?? 'auto',
        );
        final options = TagOptions(
          outDir: args['out'] as String?,
          overwrite: args['overwrite'] as bool? ?? false,
          replace: args['replace'] as bool? ?? false,
          rawMode: mode,
          maxTimeDiff: Duration(
            seconds: (args['max_time_diff'] as num?)?.toInt() ?? 300,
          ),
          timezone: args['timezone'] as String?,
          dryRun: args['dry_run'] as bool? ?? false,
        );
        return collectResult(
          TagService(registry: registry(mode)).tag(
            photos: photos,
            gpx: sources.gpx,
            google: sources.google,
            options: options,
          ),
        );
      },
    ),
    McpTool(
      name: 'render_heatmap',
      description:
          'Render a density-heatmap PNG of where photos were taken '
          '(reads existing GPS; read-only). Needs exiftool to read coordinates.',
      inputSchema: {
        'type': 'object',
        'required': ['photos', 'out'],
        'properties': {
          'photos': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Photo files or directories.',
          },
          'out': {'type': 'string', 'description': 'Output PNG path.'},
          'dpi': {
            'type': 'integer',
            'description': 'Resolution 30..1200 (default 200).',
          },
        },
      },
      run: (args) async {
        final photos = Collectors.photos(_strList(args['photos']));
        final out = args['out'] as String?;
        if (photos.isEmpty || out == null) {
          return {
            'ok': false,
            'code': 'bad_input',
            'error': 'photos and out are required',
          };
        }
        final service = MapService(
          runner: runner,
          exiftoolAvailable: exiftoolAvailable,
        );
        return collectResult(
          service.render(
            photos,
            MapOptions(
              outputPng: out,
              dpi: (args['dpi'] as num?)?.toInt() ?? 200,
            ),
          ),
        );
      },
    ),
    McpTool(
      name: 'prune_raw',
      description:
          'Move RAW files that have no same-name JPG/HEIC companion '
          '(anywhere in the tree) to the Trash, or delete them.',
      inputSchema: {
        'type': 'object',
        'required': ['roots'],
        'properties': {
          'roots': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Files or directories to scan.',
          },
          'delete': {
            'type': 'boolean',
            'description': 'Permanently delete instead of moving to Trash.',
          },
          'dry_run': {'type': 'boolean', 'description': 'Report only.'},
        },
      },
      run: (args) async {
        final roots = _strList(args['roots']);
        if (roots.isEmpty) {
          return {'ok': false, 'code': 'bad_input', 'error': 'roots required'};
        }
        return collectResult(
          Pruner(trash: const SystemTrash()).prune(
            roots,
            PruneOptions(
              delete: args['delete'] as bool? ?? false,
              dryRun: args['dry_run'] as bool? ?? false,
            ),
          ),
        );
      },
    ),
    McpTool(
      name: 'fix_dates',
      description:
          "Realign dates. mode 'exif': file date <- EXIF; mode 'file': "
          'EXIF capture date <- file date.',
      inputSchema: {
        'type': 'object',
        'required': ['photos', 'mode'],
        'properties': {
          'photos': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Photo files or directories.',
          },
          'mode': {
            'type': 'string',
            'enum': ['exif', 'file'],
            'description':
                "'exif': file date <- EXIF; 'file': EXIF <- file date.",
          },
          'dry_run': {'type': 'boolean', 'description': 'Report only.'},
        },
      },
      run: (args) async {
        final photos = Collectors.photos(_strList(args['photos']));
        final modeName = args['mode'] as String?;
        if (photos.isEmpty || modeName == null) {
          return {
            'ok': false,
            'code': 'bad_input',
            'error': 'photos and mode are required',
          };
        }
        final dater = Dater(
          exif: DispatchingExifBackend(registry(RawMode.auto)),
          runner: runner,
        );
        return collectResult(
          dater.fixDates(
            photos,
            FixDatesMode.values.byName(modeName),
            dryRun: args['dry_run'] as bool? ?? false,
          ),
        );
      },
    ),
    McpTool(
      name: 'check_toolkit',
      description:
          'Report external tools (exiftool, libheif, package manager): '
          'presence, version, purpose, and install command.',
      inputSchema: const {'type': 'object', 'properties': {}},
      run: (args) async {
        final tools = await ToolkitChecker(runner).check();
        return {
          'ok': true,
          'tools': [for (final t in tools) t.toJson()],
        };
      },
    ),
    McpTool(
      name: 'get_capabilities',
      description:
          'Describe supported formats, location sources, and the RAW '
          'write modes available in this environment.',
      inputSchema: const {'type': 'object', 'properties': {}},
      run: (args) async => {
        'ok': true,
        'formats': {
          'jpeg': 'inline lossless (pure Dart)',
          'png': 'inline (re-encode)',
          'raw': exiftoolAvailable
              ? 'XMP sidecar or exiftool embed'
              : 'XMP sidecar only (exiftool not found)',
          'heic': exiftoolAvailable
              ? 'exiftool'
              : 'unavailable (need exiftool)',
        },
        'sources': ['gpx', 'google_records', 'google_timeline', 'google_kml'],
        'raw_modes': ['auto', 'sidecar', 'embed'],
        'exiftool_available': exiftoolAvailable,
      },
    ),
  ];
}
