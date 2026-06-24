import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

/// `check` — probe external tools (exiftool, libheif, package manager).
class CheckCommand extends Command<int> {
  @override
  String get name => 'check';

  @override
  String get description =>
      'Report the status of external tools and how to install them.';

  @override
  Future<int> run() async {
    final tools = await ToolkitChecker(const SystemProcessRunner()).check();
    if (globalResults!.flag('json')) {
      stdout.writeln(jsonEncode({'tools': [for (final t in tools) t.toJson()]}));
    } else {
      for (final t in tools) {
        final mark = t.present ? '✓' : '✗';
        final ver = t.version == null ? '' : ' (${t.version})';
        stdout.writeln('$mark ${t.name}$ver — ${t.purpose}');
        if (!t.present && t.installCommand != null) {
          stdout.writeln('    install: ${t.installCommand}');
        }
      }
    }
    return 0;
  }
}
