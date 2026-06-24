import 'dart:io';

/// The result of running an external process.
class ProcResult {
  /// Wraps an exit code and captured output.
  const ProcResult(this.exitCode, this.stdout, this.stderr);

  /// Process exit code (0 = success).
  final int exitCode;

  /// Captured standard output.
  final String stdout;

  /// Captured standard error.
  final String stderr;

  /// Whether the process exited successfully.
  bool get ok => exitCode == 0;
}

/// Seam for invoking external binaries (exiftool, package managers, `SetFile`).
///
/// Injected everywhere a subprocess is needed so tests can supply a fake that
/// records calls and returns canned results without touching the real system.
abstract interface class ProcessRunner {
  /// Runs [executable] with [args] and returns its captured result.
  ///
  /// Implementations must not throw on a non-zero exit; they return it in
  /// [ProcResult.exitCode]. They may throw only when the binary cannot be
  /// launched at all (e.g. not found), which callers treat as "tool missing".
  Future<ProcResult> run(String executable, List<String> args);
}

/// A [ProcessRunner] backed by `dart:io` [Process.run].
class SystemProcessRunner implements ProcessRunner {
  /// Creates a system process runner.
  const SystemProcessRunner();

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final r = await Process.run(executable, args);
    return ProcResult(r.exitCode, r.stdout.toString(), r.stderr.toString());
  }
}
