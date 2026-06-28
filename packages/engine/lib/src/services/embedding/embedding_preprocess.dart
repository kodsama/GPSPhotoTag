/// Pure pre-processing of a decoded image into the embedding model's input
/// tensor.
///
/// MobileNetV2 (ONNX Model Zoo) takes a `[1, 3, H, W]` tensor of **float32** RGB
/// pixels in NCHW (channel-major) order, each pixel scaled to `[0, 1]` then
/// normalized with the ImageNet per-channel mean/std. This file resizes a
/// decoded [img.Image] to the model's square input and flattens it to that
/// layout. It is pure (image in, floats out) so the sizing, channel order, and
/// normalization are unit-testable without a model or native runtime.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The embedding model's square input side in pixels (MobileNetV2 is 224×224).
const int kEmbedderInputSide = 224;

/// The ImageNet per-channel normalization mean (R, G, B), applied after the
/// pixels are scaled to `[0, 1]`.
const List<double> kImageNetMean = [0.485, 0.456, 0.406];

/// The ImageNet per-channel normalization standard deviation (R, G, B).
const List<double> kImageNetStd = [0.229, 0.224, 0.225];

/// Resizes [image] to [side]×[side] and flattens it to a float32 NCHW RGB buffer
/// of length `3 * side * side` (channel-major: every R, then every G, then every
/// B), with each pixel scaled to `[0, 1]` and ImageNet-normalized.
///
/// The resize ignores aspect ratio (square input), matching the reference
/// MobileNet pre-processing. Alpha is dropped.
Float32List preprocessToNchwFloat(
  img.Image image, {
  int side = kEmbedderInputSide,
}) {
  final resized = (image.width == side && image.height == side)
      ? image
      : img.copyResize(image, width: side, height: side);
  final plane = side * side;
  final out = Float32List(3 * plane);
  var i = 0;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final px = resized.getPixel(x, y);
      out[i] = ((px.r / 255) - kImageNetMean[0]) / kImageNetStd[0];
      out[plane + i] = ((px.g / 255) - kImageNetMean[1]) / kImageNetStd[1];
      out[2 * plane + i] = ((px.b / 255) - kImageNetMean[2]) / kImageNetStd[2];
      i++;
    }
  }
  return out;
}
