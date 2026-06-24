import 'package:args/command_runner.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../cli_output.dart';
import '../source_loader.dart';

/// `map` — render a density heatmap PNG of where photos were taken (read-only).
class MapCommand extends Command<int> {
  /// Registers the `map` flags.
  MapCommand() {
    argParser
      ..addMultiOption('photo',
          abbr: 'p', help: 'Photo file or directory (repeatable, recursive).')
      ..addOption('out', abbr: 'o', help: 'Output PNG path.')
      ..addOption('dpi',
          defaultsTo: '200', help: 'Output resolution (clamped 30..1200).')
      ..addFlag('names',
          negatable: false, help: 'Label areas with collapsed filename ranges.')
      ..addOption('clusters',
          help: 'Cluster selection: "all" (default) or e.g. "1,2".');
  }

  @override
  String get name => 'map';

  @override
  String get description =>
      'Render a heatmap PNG of where photos were taken (read-only).';

  @override
  Future<int> run() async {
    final out = CliOutput(json: globalResults!.flag('json'));

    final photos = Collectors.photos(argResults!.multiOption('photo'));
    if (photos.isEmpty) {
      out.add(const ErrorEvent('no photos found for --photo', code: 'bad_input'));
      return out.exitCode;
    }

    final outPath = argResults!.option('out');
    if (outPath == null || outPath.isEmpty) {
      out.add(const ErrorEvent('--out is required', code: 'bad_input'));
      return out.exitCode;
    }

    final dpi = int.tryParse(argResults!.option('dpi') ?? '200');
    if (dpi == null || dpi <= 0) {
      out.add(const ErrorEvent('--dpi must be a positive integer',
          code: 'bad_input'));
      return out.exitCode;
    }

    const runner = SystemProcessRunner();
    final exiftool = await detectExiftool(runner);
    final service = MapService(runner: runner, exiftoolAvailable: exiftool);

    final options = MapOptions(
      outputPng: outPath,
      dpi: dpi,
      clusters: _parseClusters(argResults!.option('clusters')),
      labelNames: argResults!.flag('names'),
    );

    return out.consume(service.render(photos, options));
  }

  /// Parses `--clusters` into 1-based numbers; null for "all"/empty/absent.
  Set<int>? _parseClusters(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'all') return null;
    final ids = <int>{};
    for (final part in trimmed.split(',')) {
      final n = int.tryParse(part.trim());
      if (n != null) ids.add(n);
    }
    return ids.isEmpty ? null : ids;
  }
}
