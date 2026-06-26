import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_runner.dart';
import 'trash.dart';

/// Real, per-platform implementation of [Trash].
///
/// Moves files to the user's Trash on macOS (`~/.Trash`), the XDG trash on
/// Linux (`$XDG_DATA_HOME/Trash` with a `.trashinfo` record), and the Recycle
/// Bin on Windows (via PowerShell). Unsupported platforms throw.
///
/// The OS decision, the environment lookups, and the PowerShell invocation are
/// injectable seams (defaulting to the real platform). Production code uses the
/// zero-argument `const SystemTrash()`; tests drive a specific platform's
/// layout without depending on the host OS.
class SystemTrash implements Trash {
  /// Creates a system trash adapter.
  ///
  /// [operatingSystem] defaults to [Platform.operatingSystem]; [environment]
  /// to [Platform.environment]; [processRunner] to a real `Process.run`
  /// adapter. Overriding them keeps behaviour identical while making each
  /// platform branch reachable under test.
  const SystemTrash({
    String? operatingSystem,
    Map<String, String>? environment,
    ProcessRunner? processRunner,
  }) : _osOverride = operatingSystem,
       _envOverride = environment,
       _runnerOverride = processRunner;

  final String? _osOverride;
  final Map<String, String>? _envOverride;
  final ProcessRunner? _runnerOverride;

  String get _os => _osOverride ?? Platform.operatingSystem;
  Map<String, String> get _env => _envOverride ?? Platform.environment;
  ProcessRunner get _runner => _runnerOverride ?? const SystemProcessRunner();

  @override
  Future<void> toTrash(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('Cannot trash missing file', path);
    }
    switch (_os) {
      case 'macos':
        await _toMacTrash(file);
      case 'linux':
        await _toXdgTrash(file);
      case 'windows':
        await _toWindowsRecycleBin(path);
      default:
        throw UnsupportedError('Trash is not supported on $_os');
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
        _env['XDG_DATA_HOME'] ?? p.join(_home(), '.local', 'share');
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
    final result = await _runner.run('powershell', [
      '-NoProfile',
      '-Command',
      "Add-Type -AssemblyName Microsoft.VisualBasic; "
          "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("
          "'$escaped','OnlyErrorDialogs','SendToRecycleBin')",
    ]);
    if (!result.ok) {
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
    final home = _env['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME environment variable is not set');
    }
    return home;
  }
}
