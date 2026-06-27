/// The Tier-2 on-device people/pet detector seam.
///
/// Tier 1 ([peopleScoreFromTags]) reads people/pet signals from metadata that
/// is already in the file. When a duplicate group's candidates carry NO such
/// metadata, the `people` keep-rule can fall back to *looking at the pixels* —
/// running a small on-device model over each candidate's thumbnail to estimate
/// whether it contains a person or pet.
///
/// That fallback is optional and platform-specific (it needs a bundled model
/// and native runtime), so it is expressed as this narrow interface with a
/// [NoopPeopleDetector] default that always reports "unavailable". With the
/// default in place the rule simply relies on Tier 1 and falls through when
/// metadata is silent — so the CLI, the MCP server, and a GUI without a model
/// all behave correctly with no detector wired in.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Estimates a people/pet likelihood (0..1) for an image from its pixels.
///
/// Implementations are the Tier-2 fallback consulted only when Tier-1 metadata
/// yields nothing. Keep implementations cheap (operate on a thumbnail) and
/// total (never throw): a detector that can't decide returns null.
abstract interface class PeopleDetector {
  /// Whether this detector can actually score images right now (a model is
  /// loaded and the runtime is available). When false, callers must not call
  /// [scoreImage]/[scoreDecoded] and should rely on Tier-1 metadata alone.
  bool get isAvailable;

  /// A people/pet likelihood in 0..1 for the image encoded in [imageBytes]
  /// (a thumbnail/preview JPEG/PNG), or null when this detector can't decide
  /// (unavailable, undecodable, or inconclusive). Never throws.
  Future<double?> scoreImage(Uint8List imageBytes);

  /// Like [scoreImage] but for an already-decoded [image] — used by the hashing
  /// pipeline, which has decoded the thumbnail already, to avoid a re-decode.
  /// Returns a 0..1 score or null when it can't decide. Never throws.
  Future<double?> scoreDecoded(img.Image image);
}

// The real Tier-2 implementation behind this seam is [OrtPeopleDetector] (see
// people/ort_people_detector.dart): a small COCO-class SSD-MobileNet model run
// through a bundled ONNX Runtime via dart:ffi, both vendored like exiftool
// (tool/fetch-onnx.sh). Callers construct it from a resolved bundle dir and fall
// back to [NoopPeopleDetector] when the lib + model are absent, so Tier 1
// (metadata) still ships and the rule falls through cleanly with no detector.

/// The default [PeopleDetector]: always unavailable, scores nothing.
///
/// Used everywhere no real model is wired in (CLI, MCP, and the GUI before a
/// model is bundled) so the `people` rule degrades to Tier-1-only cleanly.
class NoopPeopleDetector implements PeopleDetector {
  /// Creates the no-op detector.
  const NoopPeopleDetector();

  @override
  bool get isAvailable => false;

  @override
  Future<double?> scoreImage(Uint8List imageBytes) async => null;

  @override
  Future<double?> scoreDecoded(img.Image image) async => null;
}
