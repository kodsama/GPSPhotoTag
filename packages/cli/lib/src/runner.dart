import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import 'commands/check_command.dart';
import 'commands/fix_dates_command.dart';
import 'commands/info_command.dart';
import 'commands/list_command.dart';
import 'commands/map_command.dart';
import 'commands/prune_command.dart';
import 'commands/schema_command.dart';
import 'commands/tag_command.dart';
import 'exit_codes.dart';

/// Builds the Stunda command runner with every subcommand registered.
///
/// Global flags (`--json`, `--verbose`) live on the runner and are read by each
/// command via `globalResults`.
///
/// [sink] overrides where commands write their output (defaults to stdout);
/// tests pass a buffer-backed sink to capture output in-process.
///
/// [mapServiceFactory] overrides how the `map` command obtains its
/// [MapService]; tests inject a fake to exercise rendering without exiftool or
/// network. Defaults to the real, exiftool-detecting factory.
///
/// [checkRunner] overrides how the `check` command probes external tools; tests
/// inject a fake to exercise the missing-tool reporting path deterministically.
CommandRunner<int> buildRunner({
  IOSink? sink,
  Future<MapService> Function()? mapServiceFactory,
  ProcessRunner? checkRunner,
}) {
  final runner =
      CommandRunner<int>(
          'stunda',
          'Tag photos with GPS from GPX tracks or Google location history.',
        )
        ..argParser.addFlag(
          'json',
          negatable: false,
          help: 'Emit one JSON event per line on stdout (machine/LLM mode).',
        )
        ..argParser.addFlag(
          'verbose',
          abbr: 'v',
          negatable: false,
          help: 'Include debug-level log events.',
        );

  runner
    ..addCommand(TagCommand(sink: sink))
    ..addCommand(MapCommand(sink: sink, serviceFactory: mapServiceFactory))
    ..addCommand(PruneCommand(sink: sink))
    ..addCommand(FixDatesCommand(sink: sink))
    ..addCommand(CheckCommand(sink: sink, runner: checkRunner))
    ..addCommand(InfoCommand(sink: sink))
    ..addCommand(ListSourcesCommand(sink: sink))
    ..addCommand(ListProvidersCommand(sink: sink))
    ..addCommand(SchemaCommand(sink: sink));

  return runner;
}

/// Runs the CLI with [args], handling [UsageException] by emitting a JSON
/// error event on [sink] when `--json` is present in [args], or plain text on
/// [errorSink] otherwise.
///
/// Returns the exit code. [sink] and [errorSink] default to [stdout] /
/// [stderr]; tests pass buffer-backed sinks to capture output in-process.
Future<int> runCliWithSink(
  List<String> args, {
  IOSink? sink,
  IOSink? errorSink,
  Future<MapService> Function()? mapServiceFactory,
  ProcessRunner? checkRunner,
}) async {
  final out = sink ?? stdout; // coverage:ignore-line
  final err = errorSink ?? stderr; // coverage:ignore-line
  final runner = buildRunner(
    sink: out,
    mapServiceFactory: mapServiceFactory,
    checkRunner: checkRunner,
  );
  try {
    return await runner.run(args) ?? ExitCodes.ok;
  } on UsageException catch (e) {
    if (args.contains('--json')) {
      out.writeln(
        jsonEncode({'event': 'error', 'code': 'bad_input', 'message': e.message}),
      );
    } else {
      err.writeln(e.message);
      err.writeln('');
      err.writeln(e.usage);
    }
    return ExitCodes.badInput;
  }
}
