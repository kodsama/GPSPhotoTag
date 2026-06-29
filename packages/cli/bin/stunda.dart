import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_cli/src/commands/info_command.dart' show cliVersion;
import 'package:stunda_cli/src/exit_codes.dart';
import 'package:stunda_cli/src/runner.dart';

/// Entry point for the `stunda` CLI.
///
/// Resolves the subcommand, runs it, and exits with the code it returns. Usage
/// and bad-argument errors map to exit code 3 (bad_input).
Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.first == '--version')) {
    stdout.writeln('stunda $cliVersion');
    return;
  }
  final runner = buildRunner();
  try {
    final code = await runner.run(args) ?? ExitCodes.ok;
    exitCode = code;
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln('');
    stderr.writeln(e.usage);
    exitCode = ExitCodes.badInput;
  }
}
