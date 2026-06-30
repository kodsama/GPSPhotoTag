import 'dart:io';

import 'package:stunda_cli/src/commands/info_command.dart' show cliVersion;
import 'package:stunda_cli/src/runner.dart';

/// Entry point for the `stunda` CLI.
///
/// Resolves the subcommand, runs it, and exits with the code it returns. Usage
/// and bad-argument errors map to exit code 3 (bad_input). When `--json` is
/// present, usage errors are emitted as JSON error events on stdout so machine
/// consumers never receive plain-text on an unexpected channel.
Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.first == '--version')) {
    stdout.writeln('stunda $cliVersion');
    return;
  }
  exitCode = await runCliWithSink(args);
}
