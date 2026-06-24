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

/// Seam for invoking external binaries (exiftool, `perl`, `SetFile`).
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
///
/// Augments `PATH` with the usual package-manager install locations before
/// launching. This matters because a GUI app started from Finder/Dock inherits
/// a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits Homebrew
/// (`/opt/homebrew/bin`, `/usr/local/bin`) and MacPorts — so without this, a
/// system `exiftool` (or `perl`) would appear "missing" in the desktop app even
/// when installed.
class SystemProcessRunner implements ProcessRunner {
  /// Creates a system process runner.
  const SystemProcessRunner();

  /// Extra directories to search per platform, appended to the inherited PATH.
  static List<String> _extraPathDirs() {
    final home = Platform.environment['HOME'] ?? '';
    if (Platform.isMacOS) {
      return [
        '/opt/homebrew/bin', // Apple Silicon Homebrew
        '/usr/local/bin', // Intel Homebrew
        '/opt/local/bin', // MacPorts
      ];
    }
    if (Platform.isLinux) {
      return [
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
        '/snap/bin',
        if (home.isNotEmpty) '$home/.local/bin',
      ];
    }
    return const []; // Windows GUI apps inherit the full PATH.
  }

  /// The inherited PATH plus [_extraPathDirs], de-duplicated, order preserved.
  static String _augmentedPath() {
    final sep = Platform.isWindows ? ';' : ':';
    final current = (Platform.environment['PATH'] ?? '').split(sep);
    final seen = <String>{};
    final merged = <String>[
      for (final d in [...current, ..._extraPathDirs()])
        if (d.isNotEmpty && seen.add(d)) d,
    ];
    return merged.join(sep);
  }

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final r = await Process.run(
      executable,
      args,
      environment: {'PATH': _augmentedPath()},
    );
    return ProcResult(r.exitCode, r.stdout.toString(), r.stderr.toString());
  }
}
