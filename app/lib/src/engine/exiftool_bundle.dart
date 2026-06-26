import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates the exiftool distribution bundled into the built desktop app.
///
/// The Perl distribution (`exiftool` + its `lib/`) is shipped as a Flutter
/// asset under `assets/exiftool/`. Flutter lays assets out differently per
/// platform relative to [Platform.resolvedExecutable]:
///
/// - macOS: inside the app bundle's `App.framework` resources.
/// - Linux/Windows: under the executable's sibling `data/flutter_assets`.
///
/// Returns the on-disk directory containing `exiftool` (or `exiftool.exe`), or
/// null when no bundled copy is present (e.g. running from a plain `dart run`).
String? locateBundledExiftool() {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final dir = Platform.isMacOS
      ? p.join(
          exeDir,
          '..',
          'Frameworks',
          'App.framework',
          'Resources',
          'flutter_assets',
          'assets',
          'exiftool',
        )
      : p.join(exeDir, 'data', 'flutter_assets', 'assets', 'exiftool');
  final normalized = p.normalize(dir);
  final script = File(p.join(normalized, 'exiftool'));
  final exe = File(p.join(normalized, 'exiftool.exe'));
  if (script.existsSync() || exe.existsSync()) return normalized;
  return null;
}
