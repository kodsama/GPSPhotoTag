import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

/// The CLI/engine version, surfaced by `info` and `--version`.
const cliVersion = '2.0.0';

/// `info` — print version, platform, and capabilities.
class InfoCommand extends Command<int> {
  @override
  String get name => 'info';

  @override
  String get description => 'Print version, platform, and capabilities.';

  @override
  Future<int> run() async {
    final info = {
      'name': 'gpsphototag',
      'version': cliVersion,
      'platform': Platform.operatingSystem,
      'formats': {
        'jpeg': 'inline (pure Dart, lossless)',
        'png': 'inline (re-encode)',
        'raw': 'XMP sidecar, or exiftool embed',
        'heic': 'exiftool',
      },
      'sources': ['gpx', 'google_records', 'google_timeline', 'google_kml'],
    };
    if (globalResults!.flag('json')) {
      stdout.writeln(jsonEncode(info));
    } else {
      stdout.writeln('gpsphototag $cliVersion on ${Platform.operatingSystem}');
      stdout.writeln('formats: jpeg, png, raw (sidecar/exiftool), heic (exiftool)');
      stdout.writeln('sources: gpx, google (records/timeline/kml)');
    }
    return 0;
  }
}
