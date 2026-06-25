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

  /// Stable identifier. Currently only `'exiftool'`.
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

/// Probes the machine for exiftool, the one external tool Stunda can use.
///
/// The pure-Dart JPEG/PNG tagging path always works without any tools. ExifTool
/// unlocks RAW-embed and HEIC; the desktop app bundles its own copy, so a probe
/// here is only meaningful for the CLI/MCP (which use whatever is on `PATH`).
/// Detection is driven through an injected [ProcessRunner] so it can be tested
/// without the real binary.
class ToolkitChecker {
  /// Creates a checker that probes via [_runner].
  ToolkitChecker(this._runner);

  final ProcessRunner _runner;

  /// Probes every known tool. Never throws: a missing binary => `present:false`.
  Future<List<ToolStatus>> check() async => [await _checkExiftool()];

  /// True when RAW GPS embedding is possible (requires exiftool).
  bool canEmbedRaw(List<ToolStatus> statuses) => _present(statuses, 'exiftool');

  /// True when HEIC/HEIF decoding is possible (requires exiftool).
  bool canHeic(List<ToolStatus> statuses) => _present(statuses, 'exiftool');

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
      purpose:
          'Embed GPS into RAW (RAF/CR3) and read Fuji/Canon timestamps; '
          'tag HEIC.',
      required: false,
      installCommand: _exiftoolInstall(),
    );
  }

  String? _exiftoolInstall() {
    if (Platform.isMacOS) return 'brew install exiftool';
    if (Platform.isLinux) return 'sudo apt install libimage-exiftool-perl';
    if (Platform.isWindows) {
      return 'winget install -e --id OliverBetz.ExifTool';
    }
    return null;
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
