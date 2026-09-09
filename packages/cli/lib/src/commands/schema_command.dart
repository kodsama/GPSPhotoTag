import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'info_command.dart' show cliVersion;

/// `schema` - emit a machine-readable description of the whole CLI surface.
///
/// This is the entry point for agent discovery: read it once to learn every
/// command, its options, the `--json` event shapes, and the exit codes, then
/// drive the tool with `--json`.
class SchemaCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout (for tests).
  SchemaCommand({IOSink? sink}) : _out = sink ?? stdout;

  final IOSink _out;

  @override
  String get name => 'schema';

  @override
  String get description =>
      'Emit a JSON description of all commands, options, events, exit codes.';

  @override
  Future<int> run() async {
    _out.writeln(const JsonEncoder.withIndent('  ').convert(_schema));
    return 0;
  }
}

const _schema = {
  'tool': 'stunda',
  'version': cliVersion,
  'globalFlags': {
    '--json': 'Emit one JSON event per line on stdout.',
    '--verbose': 'Include debug log events.',
  },
  'commands': {
    'tag': {
      'summary': 'Write GPS EXIF from GPX/Google history.',
      'options': {
        '--photo|-p': 'string[] (required) - files/dirs, recursive',
        '--gps|-g': 'string[] - GPX files/dirs',
        '--maps-history|-m': 'string[] - Google Records/Timeline/KML',
        '--out|-o': 'string - output dir (copies originals)',
        '--overwrite': 'bool - modify originals in place',
        '--replace': 'bool - overwrite existing GPS',
        '--raw-mode': 'enum auto|sidecar|embed (default auto)',
        '--max-time-diff': 'int seconds (default 300)',
        '--timezone': 'string IANA tz (fallback when EXIF lacks offset)',
        '--dry-run': 'bool - report only',
      },
      'emits': ['item', 'progress', 'done', 'error'],
    },
    'map': {
      'summary': 'Render a heatmap PNG of where photos were taken (read-only).',
      'options': {
        '--photo|-p': 'string[] (required) - files/dirs',
        '--out|-o': 'string (required) - output PNG path',
        '--dpi': 'int (default 200) - output resolution',
        '--names': 'bool - RESERVED (no effect in 2.0; overview render only)',
        '--clusters':
            "string - RESERVED (no effect in 2.0; overview render only)",
      },
      'emits': ['log', 'done', 'error'],
    },
    'prune-raw': {
      'summary': 'Trash/delete one side of the RAW/photo pairing.',
      'options': {
        '--photo|-p': 'string[] (required) - roots to scan',
        '--direction': 'enum orphan-raws|orphan-images (default orphan-raws)',
        '--rm': 'bool - delete instead of Trash',
        '--dry-run': 'bool - report only',
      },
      'emits': ['log', 'item', 'progress', 'done', 'error'],
    },
    'scan': {
      'summary': 'Report what a library holds (read-only).',
      'options': {
        '--photo|-p': 'string[] (required) - roots to scan',
        '--paths': 'bool - include full photo/track/history path lists',
      },
      'emits': ['(json) {event:scan, files, photoCount, byExtension, ...}'],
    },
    'photos': {
      'summary': 'List geotagged photos with coordinates (read-only).',
      'options': {'--photo|-p': 'string[] (required) - files/dirs'},
      'emits': [
        '(json) {event:photos, count, photos:[{path,lat,lon,taken_at}]}',
      ],
    },
    'inspect': {
      'summary': 'Dimensions, date, GPS, camera and exposure per photo.',
      'options': {'--photo|-p': 'string[] (required) - files/dirs'},
      'emits': ['(json) {event:inspect, count, photos:[{path,width,...}]}'],
    },
    'duplicates': {
      'summary': 'Group visually-similar photos; keep the best of each group.',
      'options': {
        '--photo|-p': 'string[] (required) - roots to scan',
        '--metric': 'enum fast|smart (default fast)',
        '--similarity': 'number 0..1 (default 0.92)',
        '--keep':
            'enum[] resolution|quality|people - keep-rule priority, highest '
            'first; omitted rules are disabled',
        '--apply': 'bool - remove duplicates (default: report only)',
        '--rm': 'bool - with --apply, delete instead of Trash',
      },
      'emits': ['log', 'item', 'progress', 'done', 'error'],
    },
    'shrink': {
      'summary': 'Stage duplicate/orphan/redundant/low-quality photos.',
      'options': {
        '--photo|-p': 'string[] (required) - roots to scan',
        '--stage': 'enum[] duplicates|orphans|pairs|low-quality (required, repeatable)',
        '--metric': 'enum fast|smart (default fast)',
        '--similarity': 'number 0..1 (default 0.92)',
        '--quality-threshold': 'number 0..1 (default 0.35)',
        '--pair-drop': 'enum raw|photo (default raw)',
        '--keep':
            'enum[] resolution|quality|people - keep-rule priority, highest '
            'first; omitted rules are disabled',
        '--apply': 'bool - remove staged files (default: report only)',
        '--rm': 'bool - with --apply, delete instead of Trash',
      },
      'emits': ['log', 'item', 'progress', 'done', 'error'],
    },
    'fix-dates': {
      'summary': 'Realign file dates and EXIF capture dates.',
      'options': {
        '--photo|-p': 'string[] (required)',
        '--mode': 'enum exif|file (required)',
        '--dry-run': 'bool',
      },
      'emits': ['log', 'item', 'progress', 'done', 'error'],
    },
    'check': {
      'summary': 'Report external tool status + install commands.',
      'options': <String, String>{},
      'emits': ['(json) {tools:[...]}'],
    },
    'info': {
      'summary': 'Version/platform/capabilities.',
      'options': <String, String>{},
    },
    'list-sources': {
      'summary': 'Supported location sources.',
      'options': <String, String>{},
    },
    'list-providers': {
      'summary': 'Tile/geocoder providers.',
      'options': <String, String>{},
    },
    'schema': {'summary': 'This document.', 'options': <String, String>{}},
  },
  'events': {
    'log': {
      'event': 'log',
      'level': 'debug|info|warning|error',
      'message': 'string',
    },
    'progress': {'event': 'progress', 'done': 'int', 'total': 'int'},
    'item': {
      'event': 'item',
      'path': 'string',
      'status':
          'tagged|interpolated|already_tagged|no_gps|no_timestamp|dates_fixed'
          '|dry_run|pruned_trashed|pruned_deleted|kept|error',
      'timestamp': 'ISO-8601 (optional)',
      'lat': 'number (optional)',
      'lon': 'number (optional)',
      'source': 'e.g. gpx/exact (optional)',
      'note': 'string (optional)',
    },
    'done': {'event': 'done', 'summary': '{status: count}', 'total': 'int'},
    'error': {
      'event': 'error',
      'code': 'bad_input|missing_toolkit|internal',
      'message': 'string',
    },
  },
  'exitCodes': {
    '0': 'ok - all items succeeded',
    '2': 'partial - some no_gps/no_timestamp/error',
    '3': 'bad_input',
    '4': 'missing_toolkit',
    '5': 'internal error',
  },
};
