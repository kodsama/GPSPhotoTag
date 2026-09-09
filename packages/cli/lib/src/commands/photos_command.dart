import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../exit_codes.dart';
import 'map_command.dart';

/// `photos` — list the geotagged photos in a library with their coordinates.
///
/// The read-only data behind the GUI's Explore map: an agent that cannot open a
/// map window can still ask where every photo was taken. Read-only.
class PhotosCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout and [serviceFactory] the map
  /// service (both for tests).
  PhotosCommand({IOSink? sink, Future<MapService> Function()? serviceFactory})
    // ignore: prefer_initializing_formals
    : _out = sink ?? stdout,
      _serviceFactory = serviceFactory ?? MapCommand.defaultServiceFactory {
    argParser.addMultiOption(
      'photo',
      abbr: 'p',
      help: 'Photo file or directory to read (repeatable).',
    );
  }

  final IOSink _out;
  final Future<MapService> Function() _serviceFactory;

  @override
  String get name => 'photos';

  @override
  String get description =>
      'List geotagged photos with their coordinates (read-only).';

  @override
  Future<int> run() async {
    final json = globalResults!.flag('json');
    final inputs = argResults!.multiOption('photo');
    final photos = Collectors.photos(inputs);
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

    final service = await _serviceFactory();
    final List<GeoPhoto> found;
    try {
      found = await service.readGeotagged(photos);
    } on Object catch (e) {
      _out.writeln(
        json
            ? jsonEncode({
                'event': 'error',
                'code': 'missing_toolkit',
                'message': '$e',
              })
            : 'error: $e',
      );
      return ExitCodes.missingToolkit;
    }

    final payload = {
      if (json) 'event': 'photos',
      'count': found.length,
      'photos': [for (final g in found) g.toJson()],
    };
    _out.writeln(
      json
          ? jsonEncode(payload)
          : const JsonEncoder.withIndent('  ').convert(payload),
    );
    return ExitCodes.ok;
  }
}
