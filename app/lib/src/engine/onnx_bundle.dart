import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

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
