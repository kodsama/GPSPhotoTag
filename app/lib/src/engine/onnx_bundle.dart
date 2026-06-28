import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

/// Prepares the ONNX bundle dir on mobile (Android/iOS), or returns null on
/// desktop (use [locateBundledOnnx] there).
///
/// On mobile the two `.onnx` models ship as Flutter assets — not real files —
/// and the ONNX Runtime native library is provided by the OS dynamic loader
/// (the Android AAR / the iOS CocoaPod framework). This copies both models from
/// the asset bundle into `<supportDir>/onnx/` (idempotent) and returns that dir
/// to use as the engine's `onnxBundleDir`. The library is resolved by name at
/// FFI load time, so only the models need to be materialised here.
Future<String?> prepareMobileOnnxBundle(String supportDir) async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  final dir = Directory(p.join(supportDir, 'onnx'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  for (final name in const [kOnnxModelFileName, kEmbeddingModelFileName]) {
    final out = File(p.join(dir.path, name));
    if (out.existsSync() && out.lengthSync() > 0) continue;
    final data = await rootBundle.load('assets/onnx/$name');
    await out.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
  return dir.path;
}

/// Locates the bundled ONNX Runtime library + detector model inside the built
/// desktop app, mirroring [locateBundledExiftool].
///
/// `tool/fetch-onnx.sh` vendors the per-platform ONNX Runtime library and the
/// shared SSD-MobileNet model under `assets/onnx/`, with the host platform's
/// library and a copy of the model together in `assets/onnx/<platform>/`.
/// Flutter lays assets out per platform relative to
/// [Platform.resolvedExecutable] (see [locateBundledExiftool]); this returns the
/// platform subdir that holds BOTH files, or null when the complete pair is not
/// present (e.g. a plain `dart run`, or a build without the fetched assets) so
/// callers fall back to the Tier-1-only [NoopPeopleDetector].
String? locateBundledOnnx() {
  final platform = onnxPlatformSubdir(Platform.operatingSystem);
  if (platform == null) return null;
  final dir = onnxBundleDirFor(
    operatingSystem: Platform.operatingSystem,
    exeDir: p.dirname(Platform.resolvedExecutable),
    platformSubdir: platform,
  );
  return (resolveOnnxBundle(dir)?.isComplete ?? false) ? dir : null;
}

/// The on-disk `assets/onnx/<platformSubdir>/` directory for [operatingSystem],
/// relative to the app executable's [exeDir]. Pure (no I/O) so both the macOS
/// app-bundle layout and the Linux/Windows `data/flutter_assets` layout are
/// unit-testable on any host.
@visibleForTesting
String onnxBundleDirFor({
  required String operatingSystem,
  required String exeDir,
  required String platformSubdir,
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
          'onnx',
        ])
      : p.join(exeDir, 'data', 'flutter_assets', 'assets', 'onnx');
  return p.normalize(p.join(root, platformSubdir));
}

/// The `assets/onnx/<platform>/` subdir name for [operatingSystem]
/// (a [Platform.operatingSystem] value), or null on a platform with no bundled
/// ONNX Runtime build. On macOS the arm64 vs x64 split follows the host arch.
@visibleForTesting
String? onnxPlatformSubdir(String operatingSystem) {
  switch (operatingSystem) {
    case 'macos':
      return Platform.version.contains('arm64') ? 'osx-arm64' : 'osx-x64';
    case 'linux':
      return 'linux-x64';
    case 'windows':
      return 'win-x64';
    default:
      return null;
  }
}
