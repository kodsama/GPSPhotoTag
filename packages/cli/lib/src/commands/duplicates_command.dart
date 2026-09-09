import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../cli_output.dart';

/// `duplicates` — group visually-similar photos and trash the non-kept copies.
///
/// Review-first like the GUI: without `--apply` it reports the groups and
/// removes nothing.
class DuplicatesCommand extends Command<int> {
  /// Creates the command. [sink] overrides stdout and [service] the engine
  /// service (both for tests).
  DuplicatesCommand({IOSink? sink, DuplicatesService? service})
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
      ..addOption(
        'metric',
        allowed: ['fast', 'smart'],
        defaultsTo: 'fast',
        help: 'fast: perceptual hash + colour. smart: on-device embedding.',
      )
      ..addOption(
        'similarity',
        defaultsTo: '0.92',
        help: 'Match cutoff 0..1; higher groups only near-identical photos.',
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
        help: 'Remove the duplicates (default is a report-only dry run).',
      )
      ..addFlag(
        'rm',
        negatable: false,
        help: 'With --apply, delete permanently instead of trashing.',
      );
  }

  final IOSink? _sink;
  final DuplicatesService? _service;

  @override
  String get name => 'duplicates';

  @override
  String get description =>
      'Find visually-similar photos; keep the best of each group.';

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
    final similarity = double.tryParse(argResults!.option('similarity')!);
    if (similarity == null || similarity < 0 || similarity > 1) {
      out.add(
        const ErrorEvent(
          '--similarity must be a number between 0 and 1',
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
        DuplicatesService(
          runner: const SystemProcessRunner(),
          trash: const SystemTrash(),
        );
    return out.consume(
      service.findDuplicates(
        roots,
        DuplicatesOptions(
          minSimilarity: similarity,
          metric: SimilarityMetric.values.byName(argResults!.option('metric')!),
          pipeline: pipeline,
          delete: argResults!.flag('rm'),
          dryRun: !argResults!.flag('apply'),
        ),
      ),
    );
  }
}
