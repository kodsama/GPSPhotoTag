import 'package:stunda_engine/stunda_engine.dart';

/// One line in the rolling activity log shown in the slide-over panel.
class LogEntry {
  /// Creates a log entry at [time] (defaults to now).
  LogEntry(this.message, {this.level = LogLevel.info, DateTime? time})
    : time = time ?? DateTime.now();

  /// The message text.
  final String message;

  /// Severity, used to colour the row.
  final LogLevel level;

  /// When the entry was recorded.
  final DateTime time;

  /// `HH:MM:SS` clock stamp for display.
  String get clock =>
      '${_two(time.hour)}:${_two(time.minute)}:'
      '${_two(time.second)}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
