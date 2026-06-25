import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../cli_output.dart';
import '../exit_codes.dart';
import '../source_loader.dart';

/// `tag` — write GPS EXIF into photos from GPX and/or Google location history.
class TagCommand extends Command<int> {
  /// Registers the `tag` flags. [sink] overrides stdout (for tests).
  // ignore: prefer_initializing_formals
  TagCommand({IOSink? sink}) : _sink = sink {
    argParser
      ..addMultiOption(
        'photo',
        abbr: 'p',
        help: 'Photo file or directory (repeatable, recursive).',
      )
      ..addMultiOption(
        'gps',
        abbr: 'g',
        help: 'GPX file or directory (repeatable).',
      )
      ..addMultiOption(
        'maps-history',
        abbr: 'm',
        help: 'Google Records.json / Timeline JSON or KML (repeatable).',
      )
      ..addOption(
        'out',
        abbr: 'o',
        help: 'Output directory (copies originals).',
      )
      ..addFlag(
        'overwrite',
        negatable: false,
        help: 'Modify originals in place.',
      )
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Overwrite GPS already in the photo.',
      )
      ..addOption(
        'raw-mode',
        allowed: ['auto', 'sidecar', 'embed'],
        defaultsTo: 'auto',
        help: 'How to write GPS to RAW files.',
      )
      ..addOption(
        'max-time-diff',
        defaultsTo: '300',
        help: 'Max seconds between photo time and a source point.',
      )
      ..addOption(
        'timezone',
        help: 'IANA tz used when EXIF lacks an offset (fallback: local).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report only; write nothing.',
      );
  }

  final IOSink? _sink;

  @override
  String get name => 'tag';

  @override
  String get description =>
      'Write GPS EXIF into photos from GPX or Google location history.';

  @override
  Future<int> run() async {
    final json = globalResults!.flag('json');
    final out = CliOutput(json: json, sink: _sink, errorSink: _sink);

    final photos = Collectors.photos(argResults!.multiOption('photo'));
    if (photos.isEmpty) {
      out.add(
        const ErrorEvent('no photos found for --photo', code: 'bad_input'),
      );
      return out.exitCode;
    }

    final seconds = int.tryParse(argResults!.option('max-time-diff') ?? '300');
    if (seconds == null || seconds < 0) {
      out.add(
        const ErrorEvent(
          '--max-time-diff must be a non-negative integer',
          code: 'bad_input',
        ),
      );
      return ExitCodes.badInput;
    }

    final sources = loadSources(
      gpxInputs: argResults!.multiOption('gps'),
      historyInputs: argResults!.multiOption('maps-history'),
    );
    if (sources.gpx.isEmpty && sources.google.isEmpty) {
      out.add(
        const ErrorEvent(
          'no location source: pass --gps and/or --maps-history',
          code: 'bad_input',
        ),
      );
      return out.exitCode;
    }

    const runner = SystemProcessRunner();
    final exiftool = await detectExiftool(runner);
    final registry = BackendRegistry(
      runner: runner,
      rawMode: RawMode.values.byName(argResults!.option('raw-mode')!),
      exiftoolAvailable: exiftool,
    );

    final options = TagOptions(
      outDir: argResults!.option('out'),
      overwrite: argResults!.flag('overwrite'),
      replace: argResults!.flag('replace'),
      rawMode: RawMode.values.byName(argResults!.option('raw-mode')!),
      maxTimeDiff: Duration(seconds: seconds),
      timezone: argResults!.option('timezone'),
      dryRun: argResults!.flag('dry-run'),
    );

    return out.consume(
      TagService(registry: registry).tag(
        photos: photos,
        gpx: sources.gpx,
        google: sources.google,
        options: options,
      ),
    );
  }
}
