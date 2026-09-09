import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

void _print(
  IOSink out,
  bool json,
  String key,
  List<Map<String, Object?>> items,
) {
  if (json) {
    out.writeln(jsonEncode({key: items}));
  } else {
    for (final i in items) {
      out.writeln('${i['id']}\t${i['name']}  (${i['kind']})');
    }
  }
}

/// `list-sources` - enumerate supported location sources.
class ListSourcesCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout (for tests).
  ListSourcesCommand({IOSink? sink}) : _out = sink ?? stdout;

  final IOSink _out;

  @override
  String get name => 'list-sources';

  @override
  String get description => 'List supported location sources.';

  @override
  Future<int> run() async {
    _print(
      _out,
      globalResults!.flag('json'),
      'sources',
      locationSources.cast<Map<String, Object?>>(),
    );
    return 0;
  }
}

/// `list-providers` - enumerate tile/geocoder providers.
class ListProvidersCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout (for tests).
  ListProvidersCommand({IOSink? sink}) : _out = sink ?? stdout;

  final IOSink _out;

  @override
  String get name => 'list-providers';

  @override
  String get description => 'List map tile and geocoder providers.';

  @override
  Future<int> run() async {
    _print(
      _out,
      globalResults!.flag('json'),
      'providers',
      mapProviders.cast<Map<String, Object?>>(),
    );
    return 0;
  }
}
