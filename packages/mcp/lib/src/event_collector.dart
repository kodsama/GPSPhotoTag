import 'dart:io';

import 'package:stunda_engine/stunda_engine.dart';

/// Drains an [EngineEvent] stream into a single structured result map suitable
/// for an MCP `tools/call` response: `{summary, items, logs, [error, code]}`.
Future<Map<String, Object?>> collectResult(Stream<EngineEvent> stream) async {
  final items = <Map<String, Object?>>[];
  final logs = <Map<String, Object?>>[];
  var summary = <String, int>{};
  String? error;
  String? code;

  await for (final e in stream) {
    switch (e) {
      case ItemEvent(:final row):
        items.add(row.toJson());
      case LogEvent(:final message, :final level):
        logs.add({'level': level.name, 'message': message});
      case DoneEvent(summary: final s):
        summary = s;
      case ErrorEvent(message: final m, code: final c):
        error = m;
        code = c;
      case ProgressEvent():
        break;
    }
  }

  final out = <String, Object?>{
    'ok': error == null,
    'summary': summary,
    'count': items.length,
    'items': items,
  };
  if (error != null) out['error'] = error;
  if (code != null) out['code'] = code;
  if (logs.isNotEmpty) out['logs'] = logs;
  return out;
}

/// Reads and parses every GPX and Google-history file under [gpxInputs] /
/// [historyInputs] into time-ordered point lists for the locator.
({List<TimedPoint> gpx, List<TimedPoint> google}) loadSources(
  List<String> gpxInputs,
  List<String> historyInputs,
) {
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
  return (gpx: gpx, google: google);
}
