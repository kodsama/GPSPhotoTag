import 'package:args/command_runner.dart';

import 'commands/check_command.dart';
import 'commands/fix_dates_command.dart';
import 'commands/info_command.dart';
import 'commands/list_command.dart';
import 'commands/prune_command.dart';
import 'commands/schema_command.dart';
import 'commands/tag_command.dart';

/// Builds the GPSPhotoTag command runner with every subcommand registered.
///
/// Global flags (`--json`, `--verbose`) live on the runner and are read by each
/// command via `globalResults`.
CommandRunner<int> buildRunner() {
  final runner = CommandRunner<int>(
    'gpsphototag',
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
    ..addCommand(TagCommand())
    ..addCommand(PruneCommand())
    ..addCommand(FixDatesCommand())
    ..addCommand(CheckCommand())
    ..addCommand(InfoCommand())
    ..addCommand(ListSourcesCommand())
    ..addCommand(ListProvidersCommand())
    ..addCommand(SchemaCommand());

  return runner;
}
