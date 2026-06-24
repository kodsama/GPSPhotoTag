import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

/// `check` — probe for exiftool (RAW-embed / HEIC via exiftool).
class CheckCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout (for tests).
  CheckCommand({IOSink? sink}) : _out = sink ?? stdout;

  final IOSink _out;

  @override
  String get name => 'check';

  @override
  String get description =>
      'Report the status of external tools and how to install them.';

  @override
  Future<int> run() async {
    final tools = await ToolkitChecker(const SystemProcessRunner()).check();
    if (globalResults!.flag('json')) {
      _out.writeln(
        jsonEncode({
          'tools': [for (final t in tools) t.toJson()],
        }),
      );
    } else {
      for (final t in tools) {
        final mark = t.present ? '✓' : '✗';
        final ver = t.version == null ? '' : ' (${t.version})';
        _out.writeln('$mark ${t.name}$ver — ${t.purpose}');
        if (!t.present && t.installCommand != null) {
          _out.writeln('    install: ${t.installCommand}');
        }
      }
    }
    return 0;
  }
}
