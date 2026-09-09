import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../exit_codes.dart';

/// `inspect` - dimensions, capture date, GPS, camera and exposure per photo.
///
/// The headless form of the comparison viewer's info strip, so an agent can ask
/// what shot a photo and how big it is without opening a window. Read-only.
class InspectCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout and [runner] the exiftool
  /// invoker (both for tests).
  InspectCommand({IOSink? sink, ProcessRunner? runner})
    // ignore: prefer_initializing_formals
    : _out = sink ?? stdout,
      _runner = runner ?? const SystemProcessRunner() {
    argParser.addMultiOption(
      'photo',
      abbr: 'p',
      help: 'Photo file or directory to inspect (repeatable).',
    );
  }

  final IOSink _out;
  final ProcessRunner _runner;

  @override
  String get name => 'inspect';

  @override
  String get description =>
      'Report dimensions, date, GPS, camera and exposure per photo.';

  @override
  Future<int> run() async {
    final json = globalResults!.flag('json');
    final photos = Collectors.photos(argResults!.multiOption('photo'));
    if (photos.isEmpty) {
      _out.writeln(
        json
            ? jsonEncode({
                'event': 'error',
                'code': 'bad_input',
                'message': 'no photos found for --photo',
              })
            : 'error: no photos found for --photo',
      );
      return ExitCodes.badInput;
    }

    final info = await inspectPhotos(photos, runner: _runner);
    final payload = {
      if (json) 'event': 'inspect',
      'count': info.length,
      'photos': [for (final i in info) i.toJson()],
    };
    _out.writeln(
      json
          ? jsonEncode(payload)
          : const JsonEncoder.withIndent('  ').convert(payload),
    );
    return ExitCodes.ok;
  }
}
