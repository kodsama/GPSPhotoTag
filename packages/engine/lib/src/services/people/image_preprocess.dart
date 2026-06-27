/// Pure pre-processing of a decoded image into the detector's input tensor.
///
/// SSD-MobileNet takes a `[1, H, W, 3]` tensor of **uint8** RGB pixels in NHWC
/// order. This file resizes a decoded [img.Image] to the model's square input
/// and flattens it to that byte layout. It is pure (image in, bytes out) so the
/// sizing and channel order are unit-testable without a model or native runtime.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The model's square input side in pixels (SSD-MobileNet v1 is 300×300).
const int kDetectorInputSide = 300;

/// Resizes [image] to [side]×[side] and flattens it to a uint8 NHWC RGB buffer
/// of length `side * side * 3` (row-major: for each pixel, R then G then B).
///
/// The resize ignores aspect ratio (the model was trained on squashed inputs),
/// matching the reference SSD-MobileNet pre-processing. Alpha is dropped.
Uint8List preprocessToNhwcUint8(
  img.Image image, {
  int side = kDetectorInputSide,
}) {
  final resized = (image.width == side && image.height == side)
      ? image
      : img.copyResize(image, width: side, height: side);
  final out = Uint8List(side * side * 3);
  var i = 0;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final px = resized.getPixel(x, y);
      out[i++] = px.r.toInt();
      out[i++] = px.g.toInt();
      out[i++] = px.b.toInt();
    }
  }
  return out;
}
