import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';

/// Loaded location sources, ready for the [TagService].
class LoadedSources {
  /// Wraps parsed GPX and Google points.
  const LoadedSources(this.gpx, this.google);

  /// Time-ordered points from all GPX inputs.
  final List<TimedPoint> gpx;

  /// Time-ordered points from all Google history inputs.
  final List<TimedPoint> google;
}

/// Reads and parses every GPX and Google-history file referenced by [gpxInputs]
/// and [historyInputs] (each may be a file or directory).
LoadedSources loadSources({
  required List<String> gpxInputs,
  required List<String> historyInputs,
}) {
  final gpx = <TimedPoint>[];
  for (final path in Collectors.gpx(gpxInputs)) {
    gpx.addAll(parseGpx(File(path).readAsStringSync()));
  }
  gpx.sort();

  final google = <TimedPoint>[];
  for (final path in Collectors.googleHistory(historyInputs)) {
    google.addAll(parseGoogleAuto(File(path).readAsStringSync()));
  }
  google.sort();

  return LoadedSources(gpx, google);
}

/// Whether the `exiftool` binary is usable, via the toolkit checker.
Future<bool> detectExiftool(ProcessRunner runner) async {
  final tools = await ToolkitChecker(runner).check();
  return tools.any((t) => t.id == 'exiftool' && t.present);
}
