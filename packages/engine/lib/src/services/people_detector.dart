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

/// Estimates a people/pet likelihood (0..1) for an image from its pixels.
///
/// Implementations are the Tier-2 fallback consulted only when Tier-1 metadata
/// yields nothing. Keep implementations cheap (operate on a thumbnail) and
/// total (never throw): a detector that can't decide returns null.
abstract interface class PeopleDetector {
  /// Whether this detector can actually score images right now (a model is
  /// loaded and the runtime is available). When false, callers must not call
  /// [scoreImage] and should rely on Tier-1 metadata alone.
  bool get isAvailable;

  /// A people/pet likelihood in 0..1 for the image encoded in [imageBytes]
  /// (a thumbnail/preview JPEG/PNG), or null when this detector can't decide
  /// (unavailable, undecodable, or inconclusive). Never throws.
  Future<double?> scoreImage(Uint8List imageBytes);
}

// TODO(Tier-2): wire a real on-device detector behind this seam for the GUI.
// Needs: a small COCO-class model (person/cat/dog/bird/horse…) bundled like
// exiftool (asset + fetch script, gitignored if large) and a desktop runtime
// (onnxruntime or opencv_dart/dartcv) that resolves with the current Flutter
// and keeps `flutter build macos --release` green. It was left stubbed because
// adding native ML libs is a build-stability / app-size risk that the spec said
// not to force; Tier 1 (metadata) ships and the rule falls through cleanly when
// metadata is silent and no detector is available.

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
}
