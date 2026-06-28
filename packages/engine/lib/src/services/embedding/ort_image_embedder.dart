/// The real [ImageEmbedder]: an on-device MobileNetV2 model run through a
/// bundled ONNX Runtime via `dart:ffi`.
///
/// It composes the pure pieces — [resolveEmbeddingBundle] to find the lib +
/// model, [preprocessToNchwFloat] to build the normalized input tensor,
/// [OrtSession] to run, and [l2Normalize] to turn the output feature vector into
/// a unit direction. It is total: any failure (missing bundle, load error,
/// decode/inference error) degrades to "unavailable"/null so the duplicate
/// finder falls back to the Fast perceptual metric.
library;

import 'package:image/image.dart' as img;

import '../people/onnx_bundle.dart';
import '../people/ort_session.dart';
import 'embedding_math.dart';
import 'embedding_preprocess.dart';
import 'image_embedder.dart';

/// An [ImageEmbedder] backed by a native ONNX Runtime session.
///
/// Construct via [OrtImageEmbedder.fromBundleDir], which resolves and loads the
/// bundle eagerly: [isAvailable] is true only when the session loaded. A failed
/// load leaves it unavailable (embedding returns null) instead of throwing.
class OrtImageEmbedder implements ImageEmbedder {
  OrtImageEmbedder._(this._session);

  final OrtSession? _session;

  /// Builds an embedder from a [bundleDir] (the dir holding the ORT library and
  /// the embedding model). Returns an unavailable embedder when no bundle
  /// resolves, the files are absent, or the session fails to load — never
  /// throws.
  ///
  /// [operatingSystem] overrides the host OS for [resolveEmbeddingBundle]
  /// (testing).
  factory OrtImageEmbedder.fromBundleDir(
    String? bundleDir, {
    String? operatingSystem,
  }) {
    final bundle = resolveEmbeddingBundle(
      bundleDir,
      operatingSystem: operatingSystem,
    );
    if (bundle == null || !bundle.isComplete) {
      return OrtImageEmbedder._(null);
    }
    try {
      final session = OrtSession.open(
        libraryPath: bundle.libraryPath,
        modelPath: bundle.modelPath,
      );
      return OrtImageEmbedder._(session);
    } on Object {
      return OrtImageEmbedder._(null);
    }
  }

  @override
  bool get isAvailable => _session != null;

  @override
  Future<List<double>?> embedDecoded(img.Image image) async {
    final session = _session;
    if (session == null) return null;
    try {
      final input = preprocessToNchwFloat(image);
      final out = session.runEmbedding(input, side: kEmbedderInputSide);
      if (out.isEmpty) return null;
      return l2Normalize(out);
    } on Object {
      return null;
    }
  }

  /// Releases the native session. Idempotent; safe when unavailable.
  void close() => _session?.close();
}
