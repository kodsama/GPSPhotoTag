import 'dart:io';

import 'process_runner.dart';

/// How to invoke exiftool: the executable plus any fixed leading arguments.
///
/// A bundled exiftool ships as a Perl script (`exiftool` + its `lib/`), so it is
/// launched as `perl <bundleDir>/exiftool …`. A system install (or a bundled
/// Windows `exiftool.exe`) is launched directly with no prefix.
class ExiftoolInvocation {
  /// Creates an invocation from an [executable] and fixed [prefixArgs].
  const ExiftoolInvocation(this.executable, this.prefixArgs);

  /// The program to launch (`exiftool`, `perl`, or an absolute `exiftool.exe`).
  final String executable;

  /// Arguments prepended before every call's own arguments.
  final List<String> prefixArgs;

  /// Resolves how to run exiftool given an optional on-disk [bundleDir].
  ///
  /// - [bundleDir] == null → run `exiftool` from `PATH`.
  /// - non-null, non-Windows → run the vendored Perl script via `perl`.
  /// - non-null, Windows → use `<bundleDir>/exiftool.exe` if present, else fall
  ///   back to `exiftool` on `PATH`.
  static ExiftoolInvocation resolve(String? bundleDir) {
    if (bundleDir == null) return const ExiftoolInvocation('exiftool', []);
    if (!Platform.isWindows) {
      return ExiftoolInvocation('perl', ['$bundleDir/exiftool']);
    }
    final exe = '$bundleDir/exiftool.exe';
    if (File(exe).existsSync()) return ExiftoolInvocation(exe, const []);
    return const ExiftoolInvocation('exiftool', []);
  }
}

/// A [ProcessRunner] that rewrites `exiftool` invocations to a resolved
/// [ExiftoolInvocation] (e.g. a bundled `perl <bundleDir>/exiftool`), passing
/// every other executable straight through to a [base] runner unchanged.
///
/// This lets the dozen bare `runner.run('exiftool', …)` call sites stay as-is
/// while the desktop app transparently routes them to its bundled copy.
class ExiftoolRunner implements ProcessRunner {
  /// Wraps [base], rewriting `exiftool` calls per [invocation].
  const ExiftoolRunner(this.base, this.invocation);

  /// The underlying runner that actually launches processes.
  final ProcessRunner base;

  /// How to invoke exiftool.
  final ExiftoolInvocation invocation;

  @override
  Future<ProcResult> run(String executable, List<String> args) {
    if (executable == 'exiftool') {
      return base.run(invocation.executable, [
        ...invocation.prefixArgs,
        ...args,
      ]);
    }
    return base.run(executable, args);
  }
}
