import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../cli_output.dart';
import '../source_loader.dart';

/// `fix-dates` — realign file timestamps and EXIF capture dates.
class FixDatesCommand extends Command<int> {
  /// Registers the `fix-dates` flags. [sink] overrides stdout (for tests).
  // ignore: prefer_initializing_formals
  FixDatesCommand({IOSink? sink}) : _sink = sink {
    argParser
      ..addMultiOption(
        'photo',
        abbr: 'p',
        help: 'Photo file or directory (repeatable, recursive).',
      )
      ..addOption(
        'mode',
        allowed: ['exif', 'file'],
        mandatory: true,
        help: "'exif': file date <- EXIF; 'file': EXIF <- file date.",
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report only; change nothing.',
      );
  }

  final IOSink? _sink;

  @override
  String get name => 'fix-dates';

  @override
  String get description =>
      'Set file dates from EXIF, or EXIF capture dates from file dates.';

  @override
  Future<int> run() async {
    final out = CliOutput(
      json: globalResults!.flag('json'),
      sink: _sink,
      errorSink: _sink,
    );
    final photos = Collectors.photos(argResults!.multiOption('photo'));
    if (photos.isEmpty) {
      out.add(
        const ErrorEvent('no photos found for --photo', code: 'bad_input'),
      );
      return out.exitCode;
    }
    const runner = SystemProcessRunner();
    final exiftool = await detectExiftool(runner);
    final registry = BackendRegistry(
      runner: runner,
      exiftoolAvailable: exiftool,
    );
    final dater = Dater(exif: DispatchingExifBackend(registry), runner: runner);
    final mode = FixDatesMode.values.byName(argResults!.option('mode')!);
    return out.consume(
      dater.fixDates(photos, mode, dryRun: argResults!.flag('dry-run')),
    );
  }
}
