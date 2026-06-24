import 'dart:io';

import '../data/ports/process_runner.dart';

/// One required/optional external tool and its detected state.
class ToolStatus {
  /// Captures the detection result for a single external tool.
  const ToolStatus({
    required this.id,
    required this.name,
    required this.present,
    required this.purpose,
    required this.required,
    this.version,
    this.installCommand,
  });

  /// Stable identifier: `'exiftool'`, `'libheif'`, or `'package_manager'`.
  final String id;

  /// Human-readable display name.
  final String name;

  /// Whether the tool was detected on this machine.
  final bool present;

  /// Parsed version string when [present]; otherwise null.
  final String? version;

  /// One-line description of the capability this tool unlocks.
  final String purpose;

  /// True when the app cannot function without the tool; false = optional.
  final bool required;

  /// Suggested install command for the current OS, or null when unavailable.
  final String? installCommand;

  /// Serialises this status to a JSON-friendly map.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'present': present,
        'version': version,
        'purpose': purpose,
        'required': required,
        'installCommand': installCommand,
      };
}

/// Probes the machine for the external tools GPSPhotoTag can take advantage of.
///
/// The pure-Dart JPEG/PNG tagging path always works; this checker reports the
/// optional binaries (exiftool, libheif) that unlock RAW-embed and HEIC, plus
/// the system package manager used to install them. Detection logic is driven
/// through an injected [ProcessRunner] so it can be tested without the real
/// binaries.
class ToolkitChecker {
  /// Creates a checker that probes via [_runner].
  ToolkitChecker(this._runner);

  final ProcessRunner _runner;

  /// Probes every known tool. Never throws: a missing binary => `present:false`.
  Future<List<ToolStatus>> check() async => [
        await _checkExiftool(),
        await _checkLibheif(),
        await _checkPackageManager(),
      ];

  /// True when RAW GPS embedding is possible (requires exiftool).
  bool canEmbedRaw(List<ToolStatus> statuses) => _present(statuses, 'exiftool');

  /// True when HEIC/HEIF decoding is possible (requires either exiftool or
  /// libheif).
  bool canHeic(List<ToolStatus> statuses) =>
      _present(statuses, 'exiftool') || _present(statuses, 'libheif');

  bool _present(List<ToolStatus> statuses, String id) =>
      statuses.any((s) => s.id == id && s.present);

  Future<ToolStatus> _checkExiftool() async {
    String? version;
    var present = false;
    try {
      final result = await _runner.run('exiftool', const ['-ver']);
      if (result.ok) {
        present = true;
        version = _parseVersion(result.stdout);
      }
    } on Object {
      present = false;
    }
    return ToolStatus(
      id: 'exiftool',
      name: 'ExifTool',
      present: present,
      version: version,
      purpose: 'Embed GPS into RAW (RAF/CR3) and read Fuji/Canon timestamps; '
          'tag HEIC.',
      required: false,
      installCommand: _exiftoolInstall(),
    );
  }

  Future<ToolStatus> _checkLibheif() async {
    String? version;
    var present = false;
    try {
      final dec = await _runner.run('heif-dec', const ['--version']);
      if (dec.ok) {
        present = true;
        version = _parseVersion(dec.stdout);
      }
    } on Object {
      present = false;
    }
    if (!present) {
      try {
        // `heif-convert -h` exits non-zero on some builds but still proves the
        // binary is installed and runnable.
        await _runner.run('heif-convert', const ['-h']);
        present = true;
      } on Object {
        present = false;
      }
    }
    return ToolStatus(
      id: 'libheif',
      name: 'libheif',
      present: present,
      version: version,
      purpose: 'Decode HEIC/HEIF for reading and previews.',
      required: false,
      installCommand: _libheifInstall(),
    );
  }

  Future<ToolStatus> _checkPackageManager() async {
    final probes = _packageManagerProbes();
    String? version;
    var present = false;
    for (final probe in probes) {
      try {
        final result = await _runner.run(probe.executable, probe.args);
        if (result.ok) {
          present = true;
          version = _parseVersion(result.stdout);
          break;
        }
      } on Object {
        // Try the next candidate.
      }
    }
    return ToolStatus(
      id: 'package_manager',
      name: 'Package manager',
      present: present,
      version: version,
      purpose: 'Used to auto-install the tools above.',
      required: false,
      installCommand: null,
    );
  }

  List<_Probe> _packageManagerProbes() {
    if (Platform.isMacOS) return const [_Probe('brew', ['--version'])];
    if (Platform.isLinux) {
      return const [
        _Probe('apt', ['--version']),
        _Probe('apt-get', ['--version']),
      ];
    }
    if (Platform.isWindows) return const [_Probe('winget', ['--version'])];
    return const [];
  }

  String? _exiftoolInstall() {
    if (Platform.isMacOS) return 'brew install exiftool';
    if (Platform.isLinux) return 'sudo apt install libimage-exiftool-perl';
    if (Platform.isWindows) {
      return 'winget install -e --id OliverBetz.ExifTool';
    }
    return null;
  }

  String? _libheifInstall() {
    if (Platform.isMacOS) return 'brew install libheif';
    if (Platform.isLinux) return 'sudo apt install libheif-examples';
    return null; // Windows: no maintained CLI package.
  }

  /// Extracts a version-looking token from [output], falling back to the full
  /// trimmed text. Scans whitespace/line tokens for one that starts with a
  /// digit (optionally prefixed with `v`).
  String _parseVersion(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return trimmed;
    final tokens = trimmed.split(RegExp(r'\s+'));
    for (final token in tokens) {
      if (RegExp(r'^v?\d').hasMatch(token)) {
        return token.startsWith('v') ? token.substring(1) : token;
      }
    }
    return trimmed;
  }
}

/// A single executable+args invocation candidate.
class _Probe {
  const _Probe(this.executable, this.args);

  final String executable;
  final List<String> args;
}
