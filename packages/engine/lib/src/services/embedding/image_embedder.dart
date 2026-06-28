/// The on-device image-embedding seam used by the Smart duplicate metric.
///
/// The Fast metric compares perceptual hashes; the Smart metric instead asks a
/// small on-device CNN for a feature vector per image and compares directions
/// (cosine), which is far more robust to crop/rotation/recolour. Producing that
/// vector needs a bundled model and native runtime, so — exactly like the
/// Tier-2 [PeopleDetector] — it is expressed as this narrow interface with a
/// [NoopImageEmbedder] default that always reports "unavailable". With the
/// default in place the duplicate finder has no embeddings, so the Smart metric
/// gracefully degrades to Fast (the CLI, MCP, and a GUI without a model all
/// behave correctly with no embedder wired in).
library;

import 'package:image/image.dart' as img;

/// Produces an L2-normalized embedding vector (0..1-direction) for an image.
///
/// Implementations are the on-device CNN behind the Smart metric. Keep them
/// cheap (operate on a thumbnail) and total (never throw): an embedder that
/// can't produce a vector returns null.
abstract interface class ImageEmbedder {
  /// Whether this embedder can actually embed images right now (a model is
  /// loaded and the runtime is available). When false, callers must not call
  /// [embedDecoded] and should fall back to the Fast perceptual metric.
  bool get isAvailable;

  /// An L2-normalized embedding vector for the already-decoded [image] — used by
  /// the hashing pipeline, which has decoded the thumbnail already, to avoid a
  /// re-decode. Returns null when this embedder can't decide (unavailable or
  /// inference failed). Never throws.
  Future<List<double>?> embedDecoded(img.Image image);
}

// The real implementation behind this seam is [OrtImageEmbedder] (see
// embedding/ort_image_embedder.dart): a small Apache-2.0 MobileNetV2 model run
// through the bundled ONNX Runtime via dart:ffi, vendored like the SSD-MobileNet
// detector (tool/fetch-onnx.sh). Callers construct it from a resolved bundle dir
// and fall back to [NoopImageEmbedder] when the lib + model are absent, so the
// Smart metric degrades to Fast cleanly with no embedder.

/// The default [ImageEmbedder]: always unavailable, embeds nothing.
///
/// Used everywhere no real model is wired in (CLI, MCP, and the GUI before a
/// model is bundled) so the Smart metric degrades to the Fast metric cleanly.
class NoopImageEmbedder implements ImageEmbedder {
  /// Creates the no-op embedder.
  const NoopImageEmbedder();

  @override
  bool get isAvailable => false;

  @override
  Future<List<double>?> embedDecoded(img.Image image) async => null;
}
