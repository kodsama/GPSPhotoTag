/// Locating the bundled ONNX Runtime native library + detector model on disk.
///
/// The Tier-2 detector needs two files shipped alongside the app like the
/// vendored exiftool: the platform's ONNX Runtime shared library and the
/// SSD-MobileNet model. Both live under one *bundle directory*; this file maps a
/// bundle dir to the concrete file paths and reports whether a complete pair is
/// present, so callers can decide between [OrtPeopleDetector] and the no-op.
///
/// Resolution is pure given an [operatingSystem] override, so the per-platform
/// library name is unit-testable on any host.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The detector model file name shipped in every bundle (Apache-2.0 SSD-
/// MobileNet v1, used by the Tier-2 people/animal detector).
const String kOnnxModelFileName = 'ssd_mobilenet_v1_12.onnx';

/// The embedding model file name shipped in every bundle (Apache-2.0
/// MobileNetV2-12 from the ONNX Model Zoo, used by the Smart duplicate metric).
const String kEmbeddingModelFileName = 'mobilenetv2-12.onnx';

/// The ONNX Runtime shared-library file name for [operatingSystem]
/// ([Platform.operatingSystem] by default): `libonnxruntime.dylib` on macOS,
/// `libonnxruntime.so` on Linux, `onnxruntime.dll` on Windows. Other platforms
/// (where a desktop ORT build is not bundled) yield null.
String? ortLibraryFileName({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  switch (os) {
    case 'macos':
      return 'libonnxruntime.dylib';
    case 'linux':
      return 'libonnxruntime.so';
    case 'windows':
      return 'onnxruntime.dll';
    default:
      return null;
  }
}

/// The resolved on-disk paths of a detector bundle: the ORT [libraryPath] and
/// the [modelPath]. Built by [resolveOnnxBundle]; [isComplete] is true only when
/// both files exist.
class OnnxBundle {
  /// Creates a bundle descriptor from a [libraryPath] and [modelPath].
  const OnnxBundle({required this.libraryPath, required this.modelPath});

  /// Absolute/relative path to the ONNX Runtime shared library.
  final String libraryPath;

  /// Path to the SSD-MobileNet model file.
  final String modelPath;

  /// Whether both the library and the model exist on disk right now.
  bool get isComplete =>
      File(libraryPath).existsSync() && File(modelPath).existsSync();
}

/// Resolves the detector [OnnxBundle] for [bundleDir], or null when no bundle is
/// possible here (no [bundleDir], or an unsupported platform).
///
/// The returned bundle may still be incomplete (files absent) — callers check
/// [OnnxBundle.isComplete]. [operatingSystem] overrides the host OS so the
/// per-platform library name is testable on any machine.
OnnxBundle? resolveOnnxBundle(String? bundleDir, {String? operatingSystem}) =>
    _resolveBundle(bundleDir, kOnnxModelFileName, operatingSystem);

/// Resolves the embedding [OnnxBundle] for [bundleDir] — the same per-platform
/// ONNX Runtime library paired with the [kEmbeddingModelFileName] model — or
/// null when no bundle is possible here (no [bundleDir] or an unsupported
/// platform). The returned bundle may still be incomplete (files absent), which
/// callers check via [OnnxBundle.isComplete] so the Smart metric degrades to
/// Fast when the model is not present.
OnnxBundle? resolveEmbeddingBundle(
  String? bundleDir, {
  String? operatingSystem,
}) => _resolveBundle(bundleDir, kEmbeddingModelFileName, operatingSystem);

OnnxBundle? _resolveBundle(
  String? bundleDir,
  String modelFileName,
  String? operatingSystem,
) {
  if (bundleDir == null) return null;
  final libName = ortLibraryFileName(operatingSystem: operatingSystem);
  if (libName == null) return null;
  return OnnxBundle(
    libraryPath: p.join(bundleDir, libName),
    modelPath: p.join(bundleDir, modelFileName),
  );
}
