import 'dart:io';

import 'package:meta/meta.dart';

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

  /// Extra directories to search on [os] (`macos`/`linux`/`windows`), appended
  /// to the inherited PATH. [home] is the user's home directory.
  ///
  /// Pure and parameterised so every platform branch is reachable under test;
  /// [run] calls it with the real [Platform] values.
  @visibleForTesting
  static List<String> extraPathDirs(String os, String home) {
    switch (os) {
      case 'macos':
        return const [
          '/opt/homebrew/bin', // Apple Silicon Homebrew
          '/usr/local/bin', // Intel Homebrew
          '/opt/local/bin', // MacPorts
        ];
      case 'linux':
        return [
          '/usr/local/bin',
          '/usr/bin',
          '/bin',
          '/snap/bin',
          if (home.isNotEmpty) '$home/.local/bin',
        ];
      default:
        return const []; // Windows GUI apps inherit the full PATH.
    }
  }

  /// The inherited [path] plus [extraPathDirs] for [os], de-duplicated with
  /// order preserved. [run] supplies the real [Platform] values.
  @visibleForTesting
  static String augmentedPath(String os, String home, String path) {
    final sep = os == 'windows' ? ';' : ':';
    final current = path.split(sep);
    final seen = <String>{};
    final merged = <String>[
      for (final d in [...current, ...extraPathDirs(os, home)])
        if (d.isNotEmpty && seen.add(d)) d,
    ];
    return merged.join(sep);
  }

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final r = await Process.run(
      executable,
      args,
      environment: {
        'PATH': augmentedPath(
          Platform.operatingSystem,
          Platform.environment['HOME'] ?? '',
          Platform.environment['PATH'] ?? '',
        ),
      },
    );
    return ProcResult(r.exitCode, r.stdout.toString(), r.stderr.toString());
  }
}
