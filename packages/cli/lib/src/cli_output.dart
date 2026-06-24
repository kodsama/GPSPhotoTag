import 'dart:convert';
import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;

import 'exit_codes.dart';

/// Consumes an [EngineEvent] stream and renders it, deriving the process exit
/// code along the way.
///
/// In `--json` mode every event is printed as one JSON object per line on
/// stdout (the machine/LLM contract). In human mode it prints a compact
/// per-item line and a final summary; progress events are suppressed.
class CliOutput {
  /// Creates an output renderer. [json] selects machine mode.
  ///
  /// [sink] receives normal output (defaults to [stdout]); [errorSink] receives
  /// human-mode error/warning lines (defaults to [stderr]). Tests pass
  /// buffer-backed sinks to capture output in-process.
  CliOutput({required this.json, IOSink? sink, IOSink? errorSink})
    : _sink = sink ?? stdout,
      _errorSink = errorSink ?? stderr;

  /// Whether to emit newline-delimited JSON.
  final bool json;

  final IOSink _sink;
  final IOSink _errorSink;

  int _exit = ExitCodes.ok;
  bool _sawError = false;

  /// The exit code implied by the events seen so far.
  int get exitCode => _exit;

  /// Renders [event] and updates the exit code.
  void add(EngineEvent event) {
    if (json) {
      _sink.writeln(jsonEncode(event.toJson()));
    } else {
      _human(event);
    }
    switch (event) {
      case ErrorEvent(:final code):
        _sawError = true;
        _exit = _mapErrorCode(code);
      case DoneEvent(:final summary):
        if (!_sawError) _exit = _exitForSummary(summary);
      case _:
        break;
    }
  }

  /// Drains [stream] into this renderer and returns the final exit code.
  Future<int> consume(Stream<EngineEvent> stream) async {
    await for (final e in stream) {
      add(e);
    }
    return exitCode;
  }

  void _human(EngineEvent event) {
    switch (event) {
      case LogEvent(:final message, :final level):
        final sink = level == LogLevel.error || level == LogLevel.warning
            ? _errorSink
            : _sink;
        sink.writeln('${level.name}: $message');
      case ItemEvent(:final row):
        final coords = row.location == null
            ? ''
            : '  ${row.location!.latitude.toStringAsFixed(5)}, '
                  '${row.location!.longitude.toStringAsFixed(5)} '
                  '(${row.location!.provenance})';
        final note = row.note == null ? '' : '  — ${row.note}';
        _sink.writeln(
          '${p.basename(row.path).padRight(28)} '
          '${row.status.wire.padRight(15)}$coords$note',
        );
      case DoneEvent(:final summary):
        _sink.writeln('—' * 40);
        final keys = summary.keys.toList()..sort();
        for (final k in keys) {
          _sink.writeln('${k.padRight(20)} ${summary[k]}');
        }
        _sink.writeln(
          '${'total'.padRight(20)} '
          '${summary.values.fold(0, (a, b) => a + b)}',
        );
      case ErrorEvent(:final message):
        _errorSink.writeln('error: $message');
      case ProgressEvent():
        break;
    }
  }

  int _mapErrorCode(String code) => switch (code) {
    'bad_input' => ExitCodes.badInput,
    'missing_toolkit' => ExitCodes.missingToolkit,
    _ => ExitCodes.internal,
  };

  /// Any no-match / no-timestamp / per-item error makes the run "partial".
  int _exitForSummary(Map<String, int> summary) {
    const partialKeys = {'no_gps', 'no_timestamp', 'error'};
    final partial = partialKeys.any((k) => (summary[k] ?? 0) > 0);
    return partial ? ExitCodes.partial : ExitCodes.ok;
  }
}
