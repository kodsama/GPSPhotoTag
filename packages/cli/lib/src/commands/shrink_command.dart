import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../cli_output.dart';

/// `shrink` — run the opt-in shrink stages over a library.
///
/// Mirrors the GUI wizard: stages are opt-in, a file staged by an earlier stage
/// is never re-counted by a later one, and nothing is removed without
/// `--apply`.
class ShrinkCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout and [service] the engine
  /// service (both for tests).
  ShrinkCommand({IOSink? sink, ShrinkService? service})
    // ignore: prefer_initializing_formals
    : _sink = sink,
      // ignore: prefer_initializing_formals
      _service = service {
    argParser
      ..addMultiOption(
        'photo',
        abbr: 'p',
        help: 'Root file or directory to scan (repeatable).',
      )
      ..addMultiOption(
        'stage',
        allowed: ['duplicates', 'orphans', 'pairs', 'low-quality'],
        help: 'Stage to run (repeatable). At least one is required.',
      )
      ..addOption(
        'metric',
        allowed: ['fast', 'smart'],
        defaultsTo: 'fast',
        help: 'Similarity metric for the duplicates stage.',
      )
      ..addOption(
        'similarity',
        defaultsTo: '0.92',
        help: 'Match cutoff 0..1 for the duplicates stage.',
      )
      ..addOption(
        'quality-threshold',
        defaultsTo: '0.35',
        help: 'Composite quality below this is staged by low-quality.',
      )
      ..addOption(
        'pair-drop',
        allowed: ['raw', 'photo'],
        defaultsTo: 'raw',
        help: 'Which half of a RAW+photo pair the pairs stage drops.',
      )
      ..addMultiOption(
        'keep',
        allowed: ['resolution', 'quality', 'people'],
        help:
            'Keep-rule priority, highest first (repeatable). Rules left out '
            'are disabled. Default: resolution, quality, people.',
      )
      ..addFlag(
        'apply',
        negatable: false,
        help: 'Remove the staged files (default is a report-only dry run).',
      )
      ..addFlag(
        'rm',
        negatable: false,
        help: 'With --apply, delete permanently instead of trashing.',
      );
  }

  final IOSink? _sink;
  final ShrinkService? _service;

  @override
  String get name => 'shrink';

  @override
  String get description =>
      'Stage duplicate, orphan, redundant and low-quality photos for removal.';

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
    final stages = {
      for (final s in argResults!.multiOption('stage')) ShrinkStage.byWire(s)!,
    };
    if (stages.isEmpty) {
      out.add(
        const ErrorEvent(
          'no stages given: pass --stage at least once',
          code: 'bad_input',
        ),
      );
      return out.exitCode;
    }
    final similarity = double.tryParse(argResults!.option('similarity')!);
    final threshold = double.tryParse(argResults!.option('quality-threshold')!);
    if (similarity == null || similarity < 0 || similarity > 1) {
      out.add(
        const ErrorEvent(
          '--similarity must be a number between 0 and 1',
          code: 'bad_input',
        ),
      );
      return out.exitCode;
    }
    if (threshold == null || threshold < 0 || threshold > 1) {
      out.add(
        const ErrorEvent(
          '--quality-threshold must be a number between 0 and 1',
          code: 'bad_input',
        ),
      );
      return out.exitCode;
    }

    // `allowed:` on --keep already rejects anything that is not a rule name,
    // so the parser cannot fail here.
    final pipeline = keepPipelineFromNames(argResults!.multiOption('keep'))!;

    final service =
        _service ??
        ShrinkService(
          runner: const SystemProcessRunner(),
          trash: const SystemTrash(),
        );
    return out.consume(
      service.shrink(
        roots,
        ShrinkOptions(
          stages: stages,
          minSimilarity: similarity,
          metric: SimilarityMetric.values.byName(argResults!.option('metric')!),
          pipeline: pipeline,
          qualityThreshold: threshold,
          pairDropSide: PairDropSide.byWire(argResults!.option('pair-drop')!)!,
          delete: argResults!.flag('rm'),
          dryRun: !argResults!.flag('apply'),
        ),
      ),
    );
  }
}
