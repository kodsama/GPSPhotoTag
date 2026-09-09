import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../cli_output.dart';

/// `prune-raw` — trash (or delete) one side of the RAW/photo pairing.
///
/// `--direction orphan-raws` (the default) removes RAWs with no JPG/HEIC
/// companion; `orphan-images` removes non-RAW photos with no RAW. Paired
/// files are never touched.
class PruneCommand extends Command<int> {
  /// Registers the `prune-raw` flags. [sink] overrides stdout (for tests).
  // ignore: prefer_initializing_formals
  PruneCommand({IOSink? sink}) : _sink = sink {
    argParser
      ..addMultiOption(
        'photo',
        abbr: 'p',
        help: 'Root file or directory to scan (repeatable).',
      )
      ..addOption(
        'direction',
        allowed: ['orphan-raws', 'orphan-images'],
        defaultsTo: 'orphan-raws',
        help: 'Which side to trash: RAWs with no photo, or photos with no RAW.',
      )
      ..addFlag(
        'rm',
        negatable: false,
        help: 'Permanently delete orphans instead of moving to Trash.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report only; remove nothing.',
      );
  }

  final IOSink? _sink;

  @override
  String get name => 'prune-raw';

  @override
  String get description => 'Move orphan RAWs (or orphan images) to the Trash.';

  @override
  Future<int> run() async {
    final out = CliOutput(
      json: globalResults!.flag('json'),
      sink: _sink,
      errorSink: _sink,
    );
    final roots = argResults!.multiOption('photo');
    if (roots.isEmpty) {
      out.add(
        const ErrorEvent('no roots given for --photo', code: 'bad_input'),
      );
      return out.exitCode;
    }
    final pruner = Pruner(trash: const SystemTrash());
    return out.consume(
      pruner.prune(
        roots,
        PruneOptions(
          delete: argResults!.flag('rm'),
          dryRun: argResults!.flag('dry-run'),
          direction: PruneDirection.byWire(argResults!.option('direction')!)!,
        ),
      ),
    );
  }
}
