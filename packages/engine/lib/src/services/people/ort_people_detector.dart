/// The real Tier-2 [PeopleDetector]: an on-device SSD-MobileNet COCO model run
/// through a bundled ONNX Runtime via `dart:ffi`.
///
/// It composes the pure pieces — [resolveOnnxBundle] to find the lib + model,
/// [preprocessToNhwcUint8] to build the input tensor, [OrtSession] to run, and
/// [peopleScoreFromDetections] to fold the outputs into a 0..1 score. It is
/// total: any failure (missing bundle, load error, decode/inference error)
/// degrades to "unavailable"/null so the keep-rule falls back to Tier-1.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../people_detector.dart';
import 'detection_postprocess.dart';
import 'image_preprocess.dart';
import 'onnx_bundle.dart';
import 'ort_session.dart';

/// A [PeopleDetector] backed by a native ONNX Runtime session.
///
/// Construct via [OrtPeopleDetector.fromBundleDir], which resolves and loads the
/// bundle eagerly: [isAvailable] is true only when the session loaded. A failed
/// load leaves it unavailable (scoring returns null) instead of throwing.
class OrtPeopleDetector implements PeopleDetector {
  OrtPeopleDetector._(this._session);

  final OrtSession? _session;

  /// Builds a detector from a [bundleDir] (the dir holding the ORT library and
  /// model). Returns an unavailable detector when no bundle resolves, the files
  /// are absent, or the session fails to load — never throws.
  ///
  /// [operatingSystem] overrides the host OS for [resolveOnnxBundle] (testing).
  factory OrtPeopleDetector.fromBundleDir(
    String? bundleDir, {
    String? operatingSystem,
  }) {
    final bundle = resolveOnnxBundle(
      bundleDir,
      operatingSystem: operatingSystem,
    );
    if (bundle == null || !bundle.isComplete) {
      return OrtPeopleDetector._(null);
    }
    try {
      final session = OrtSession.open(
        libraryPath: bundle.libraryPath,
        modelPath: bundle.modelPath,
      );
      return OrtPeopleDetector._(session);
    } on Object {
      return OrtPeopleDetector._(null);
    }
  }

  @override
  bool get isAvailable => _session != null;

  @override
  Future<double?> scoreImage(Uint8List imageBytes) async {
    final session = _session;
    if (session == null) return null;
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(imageBytes);
    } on Object {
      return null;
    }
    if (decoded == null) return null;
    return _score(session, decoded);
  }

  @override
  Future<double?> scoreDecoded(img.Image image) async {
    final session = _session;
    if (session == null) return null;
    return _score(session, image);
  }

  /// Runs preprocess → inference → postprocess for [image], returning the 0..1
  /// score or null on any native failure.
  double? _score(OrtSession session, img.Image image) {
    try {
      final input = preprocessToNhwcUint8(image);
      final out = session.runDetection(input, side: kDetectorInputSide);
      return peopleScoreFromDetections(
        out.scores,
        out.classes,
        out.numDetections,
      );
    } on Object {
      return null;
    }
  }

  /// Releases the native session. Idempotent; safe when unavailable.
  void close() => _session?.close();
}
