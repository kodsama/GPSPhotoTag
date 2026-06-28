import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Locates the exiftool distribution bundled into the built desktop app.
///
/// exiftool ships differently per platform:
///
/// - macOS/Linux: the Perl distribution (`exiftool` + its `lib/`) under
///   `assets/exiftool/`, launched via the system `perl`.
/// - Windows: the official self-contained `exiftool.exe` (+ its `exiftool_files/`
///   dir) under `assets/exiftool/windows/`, launched directly. Windows has no
///   Perl, so the Perl script cannot run there.
///
/// Flutter lays assets out differently per platform relative to
/// [Platform.resolvedExecutable]:
///
/// - macOS: inside the app bundle's `App.framework` resources.
/// - Linux/Windows: under the executable's sibling `data/flutter_assets`.
///
/// Returns the on-disk directory containing the runnable `exiftool` (or
/// `exiftool.exe`), or null when no bundled copy is present (e.g. running from a
/// plain `dart run`) so callers fall back to a `PATH` exiftool.
String? locateBundledExiftool() => exiftoolBundleDirFor(
  operatingSystem: Platform.operatingSystem,
  exeDir: p.dirname(Platform.resolvedExecutable),
);

/// The on-disk exiftool bundle directory for [operatingSystem], relative to the
/// app executable's [exeDir], or null when no runnable bundle exists there.
///
/// Pure aside from the final `existsSync` probe, so both the macOS app-bundle
/// layout and the Linux/Windows `data/flutter_assets` layout — and the Windows
/// `exiftool.exe` vs POSIX `perl` script split — are unit-testable on any host.
@visibleForTesting
String? exiftoolBundleDirFor({
  required String operatingSystem,
  required String exeDir,
}) {
  final root = operatingSystem == 'macos'
      ? p.joinAll([
          exeDir,
          '..',
          'Frameworks',
          'App.framework',
          'Resources',
          'flutter_assets',
          'assets',
          'exiftool',
        ])
      : p.join(exeDir, 'data', 'flutter_assets', 'assets', 'exiftool');
  // Windows ships a self-contained exe under a `windows/` subdir; macOS/Linux
  // keep the Perl script at the bundle root.
  final dir = operatingSystem == 'windows' ? p.join(root, 'windows') : root;
  final normalized = p.normalize(dir);
  final exeName = operatingSystem == 'windows' ? 'exiftool.exe' : 'exiftool';
  if (File(p.join(normalized, exeName)).existsSync()) return normalized;
  return null;
}
