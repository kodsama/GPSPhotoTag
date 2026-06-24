import 'package:meta/meta.dart';

import 'photo_row.dart';

/// Severity for [LogEvent] lines.
enum LogLevel {
  /// Fine-grained tracing, hidden unless verbose.
  debug,

  /// Normal progress information.
  info,

  /// A recoverable concern the user should see.
  warning,

  /// A failure affecting one item or the whole run.
  error,
}

/// A single observable thing that happened during an operation.
///
/// Both adapters consume the same stream: the CLI serialises each event to one
/// JSON line ([toJson]); the GUI routes events to controllers. The type is a
/// sealed hierarchy so exhaustive `switch` handling is enforced at compile time.
@immutable
sealed class EngineEvent {
  const EngineEvent();

  /// The `event` discriminator used in `--json` output.
  String get kind;

  /// JSON form: one object per line on stdout in `--json` mode.
  Map<String, Object?> toJson();
}

/// A human-readable log line.
final class LogEvent extends EngineEvent {
  /// Creates a log event.
  const LogEvent(this.message, {this.level = LogLevel.info});

  /// The message text.
  final String message;

  /// Severity.
  final LogLevel level;

  @override
  String get kind => 'log';

  @override
  Map<String, Object?> toJson() => {
    'event': kind,
    'level': level.name,
    'message': message,
  };
}

/// Overall progress: [done] of [total] items processed.
final class ProgressEvent extends EngineEvent {
  /// Creates a progress event.
  const ProgressEvent({required this.done, required this.total});

  /// Items completed so far.
  final int done;

  /// Total items in the run (may be 0 before counting completes).
  final int total;

  /// Fraction complete in 0..1, or 0 when [total] is 0.
  double get fraction => total == 0 ? 0 : done / total;

  @override
  String get kind => 'progress';

  @override
  Map<String, Object?> toJson() => {
    'event': kind,
    'done': done,
    'total': total,
  };
}

/// One file finished processing.
final class ItemEvent extends EngineEvent {
  /// Creates an item event wrapping [row].
  const ItemEvent(this.row);

  /// The per-file result.
  final PhotoRow row;

  @override
  String get kind => 'item';

  @override
  Map<String, Object?> toJson() => {'event': kind, ...row.toJson()};
}

/// The operation finished; [summary] maps each status wire-name to a count.
final class DoneEvent extends EngineEvent {
  /// Creates a done event.
  const DoneEvent(this.summary);

  /// Count per [PhotoStatus.wire].
  final Map<String, int> summary;

  /// Total items across all statuses.
  int get total => summary.values.fold(0, (a, b) => a + b);

  @override
  String get kind => 'done';

  @override
  Map<String, Object?> toJson() => {
    'event': kind,
    'summary': summary,
    'total': total,
  };
}

/// A fatal error aborted the operation.
final class ErrorEvent extends EngineEvent {
  /// Creates an error event.
  const ErrorEvent(this.message, {this.code = 'internal'});

  /// The error message.
  final String message;

  /// A short machine code (e.g. `bad_input`, `missing_toolkit`, `internal`).
  final String code;

  @override
  String get kind => 'error';

  @override
  Map<String, Object?> toJson() => {
    'event': kind,
    'code': code,
    'message': message,
  };
}
