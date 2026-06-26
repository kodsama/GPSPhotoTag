/// Stable process exit codes, part of the CLI/LLM contract (see `schema`).
abstract final class ExitCodes {
  /// Completed; every item succeeded.
  static const ok = 0;

  /// Completed, but some items had no match / no timestamp / per-item errors.
  static const partial = 2;

  /// Invalid input or arguments.
  static const badInput = 3;

  /// A required external tool is missing.
  static const missingToolkit = 4;

  /// An unexpected internal error aborted the run.
  static const internal = 5;
}
