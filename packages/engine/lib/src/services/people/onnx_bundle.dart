/// Locating the bundled ONNX Runtime native library + detector model on disk.
///
/// The Tier-2 detector needs two files shipped alongside the app like the
/// vendored exiftool: the platform's ONNX Runtime shared library and the
/// SSD-MobileNet model. Both live under one *bundle directory*; this file maps a
/// bundle dir to the concrete file paths and reports whether a complete pair is
/// present, so callers can decide between [OrtPeopleDetector] and the no-op.
///
/// On mobile the ONNX Runtime library is provided by the OS dynamic loader (the
/// Android AAR's `libonnxruntime.so`, the iOS CocoaPod framework) rather than a
/// file in the bundle dir, so only the model is a real file there.
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

/// The ONNX Runtime shared-library name for [operatingSystem]
/// ([Platform.operatingSystem] by default).
///
/// Desktop returns a bundled file name resolved relative to the bundle dir:
/// `libonnxruntime.dylib` (macOS), `libonnxruntime.so` (Linux),
/// `onnxruntime.dll` (Windows). Mobile returns a name the dynamic loader
/// resolves itself (see [ortLibraryIsLoaderResolved]): `libonnxruntime.so`
/// (Android, packaged from the AAR), `onnxruntime.framework/onnxruntime` (iOS,
/// the embedded CocoaPod framework). Unsupported platforms yield null.
String? ortLibraryFileName({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  switch (os) {
    case 'macos':
      return 'libonnxruntime.dylib';
    case 'linux':
      return 'libonnxruntime.so';
    case 'windows':
      return 'onnxruntime.dll';
    case 'android':
      return 'libonnxruntime.so';
    case 'ios':
      return 'onnxruntime.framework/onnxruntime';
    default:
      return null;
  }
}

/// Whether [operatingSystem]'s ONNX Runtime library is resolved by the OS
/// dynamic loader (mobile) rather than living as a file inside the bundle dir
/// (desktop). When true the library path is a bare soname / framework path that
/// cannot be `stat`'d, so [OnnxBundle.isComplete] only requires the model.
bool ortLibraryIsLoaderResolved({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return os == 'android' || os == 'ios';
}

/// The resolved paths of a detector bundle: the ORT [libraryPath] and the
/// [modelPath]. Built by [resolveOnnxBundle]; [isComplete] reports whether the
/// pieces this platform needs are present.
class OnnxBundle {
  /// Creates a bundle descriptor. [libraryLoaderResolved] is true on mobile,
  /// where [libraryPath] is a loader-resolved soname/framework path rather than
  /// a file on disk.
  const OnnxBundle({
    required this.libraryPath,
    required this.modelPath,
    this.libraryLoaderResolved = false,
  });

  /// Path to the ONNX Runtime shared library (desktop) or the loader-resolved
  /// soname/framework path (mobile, when [libraryLoaderResolved]).
  final String libraryPath;

  /// Path to the model file.
  final String modelPath;

  /// Whether [libraryPath] is resolved by the OS loader (mobile) instead of
  /// being a file in the bundle dir (desktop).
  final bool libraryLoaderResolved;

  /// Whether the pieces needed on this platform are present: the model always,
  /// plus the library file on desktop (on mobile the loader provides it).
  bool get isComplete {
    if (!File(modelPath).existsSync()) return false;
    return libraryLoaderResolved || File(libraryPath).existsSync();
  }
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
  final loaderResolved = ortLibraryIsLoaderResolved(
    operatingSystem: operatingSystem,
  );
  return OnnxBundle(
    // On mobile the loader finds the library by its bare soname/framework path;
    // on desktop it lives next to the model in the bundle dir.
    libraryPath: loaderResolved ? libName : p.join(bundleDir, libName),
    modelPath: p.join(bundleDir, modelFileName),
    libraryLoaderResolved: loaderResolved,
  );
}
