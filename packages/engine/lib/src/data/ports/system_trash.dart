import 'dart:io';

import 'package:path/path.dart' as p;

import 'trash.dart';

/// Real, per-platform implementation of [Trash].
///
/// Moves files to the user's Trash on macOS (`~/.Trash`), the XDG trash on
/// Linux (`$XDG_DATA_HOME/Trash` with a `.trashinfo` record), and the Recycle
/// Bin on Windows (via PowerShell). Unsupported platforms throw.
class SystemTrash implements Trash {
  /// Creates a system trash adapter.
  const SystemTrash();

  @override
  Future<void> toTrash(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('Cannot trash missing file', path);
    }
    if (Platform.isMacOS) {
      await _toMacTrash(file);
    } else if (Platform.isLinux) {
      await _toXdgTrash(file);
    } else if (Platform.isWindows) {
      await _toWindowsRecycleBin(path);
    } else {
      throw UnsupportedError(
        'Trash is not supported on ${Platform.operatingSystem}',
      );
    }
  }

  /// Moves [file] into `~/.Trash`, de-duplicating the name on conflict.
  Future<void> _toMacTrash(File file) async {
    final home = _home();
    final trashDir = Directory(p.join(home, '.Trash'));
    trashDir.createSync(recursive: true);
    final dest = _uniqueDest(trashDir.path, p.basename(file.path));
    await _move(file, dest);
  }

  /// Moves [file] into the XDG trash and writes its `.trashinfo` record.
  Future<void> _toXdgTrash(File file) async {
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(_home(), '.local', 'share');
    final filesDir = Directory(p.join(dataHome, 'Trash', 'files'));
    final infoDir = Directory(p.join(dataHome, 'Trash', 'info'));
    filesDir.createSync(recursive: true);
    infoDir.createSync(recursive: true);

    final dest = _uniqueDest(filesDir.path, p.basename(file.path));
    final absSource = p.absolute(file.path);
    await _move(file, dest);

    final info = File(p.join(infoDir.path, '${p.basename(dest)}.trashinfo'));
    final deletionDate = DateTime.now().toIso8601String();
    info.writeAsStringSync(
      '[Trash Info]\nPath=$absSource\nDeletionDate=$deletionDate\n',
    );
  }

  /// Sends [path] to the Recycle Bin via PowerShell / VisualBasic FileSystem.
  Future<void> _toWindowsRecycleBin(String path) async {
    final escaped = path.replaceAll("'", "''");
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Add-Type -AssemblyName Microsoft.VisualBasic; "
          "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("
          "'$escaped','OnlyErrorDialogs','SendToRecycleBin')",
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException('Failed to recycle (${result.stderr})', path);
    }
  }

  /// Renames [file] to [dest], falling back to copy+delete across volumes.
  Future<void> _move(File file, String dest) async {
    try {
      await file.rename(dest);
    } on FileSystemException {
      await file.copy(dest);
      await file.delete();
    }
  }

  /// Returns a destination path in [dir] for [name], appending ` <n>` before
  /// the extension until the path is free.
  String _uniqueDest(String dir, String name) {
    var candidate = p.join(dir, name);
    if (!_exists(candidate)) return candidate;

    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var counter = 1;
    do {
      candidate = p.join(dir, '$stem $counter$ext');
      counter++;
    } while (_exists(candidate));
    return candidate;
  }

  bool _exists(String path) =>
      File(path).existsSync() || Directory(path).existsSync();

  String _home() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME environment variable is not set');
    }
    return home;
  }
}
