import 'package:args/command_runner.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../cli_output.dart';

/// `prune-raw` — trash (or delete) RAW files with no JPG/HEIC companion.
class PruneCommand extends Command<int> {
  /// Registers the `prune-raw` flags.
  PruneCommand() {
    argParser
      ..addMultiOption('photo',
          abbr: 'p', help: 'Root file or directory to scan (repeatable).')
      ..addFlag('rm',
          negatable: false,
          help: 'Permanently delete orphans instead of moving to Trash.')
      ..addFlag('dry-run',
          negatable: false, help: 'Report only; remove nothing.');
  }

  @override
  String get name => 'prune-raw';

  @override
  String get description =>
      'Move RAW files lacking a same-name JPG/HEIC companion to the Trash.';

  @override
  Future<int> run() async {
    final out = CliOutput(json: globalResults!.flag('json'));
    final roots = argResults!.multiOption('photo');
    if (roots.isEmpty) {
      out.add(const ErrorEvent('no roots given for --photo', code: 'bad_input'));
      return out.exitCode;
    }
    final pruner = Pruner(trash: const SystemTrash());
    return out.consume(pruner.prune(
      roots,
      PruneOptions(
        delete: argResults!.flag('rm'),
        dryRun: argResults!.flag('dry-run'),
      ),
    ));
  }
}
