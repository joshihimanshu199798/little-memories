import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

/// Applies opaque black masks over detected face boxes.
///
/// The image is modified in place. Padding intentionally expands each box so
/// edges of a face are less likely to remain visible after re-encoding.
img.Image applyFacePrivacyMasks(
  img.Image image,
  List<Rect> faceBoxes, {
  double paddingFraction = 0.22,
}) {
  for (final box in faceBoxes) {
    if (box.isEmpty) continue;

    final paddingX = box.width * paddingFraction;
    final paddingY = box.height * paddingFraction;
    final paddedLeft = box.left - paddingX;
    final paddedTop = box.top - paddingY;
    final paddedRight = box.right + paddingX;
    final paddedBottom = box.bottom + paddingY;

    // Ignore detections wholly outside the image before clamping coordinates.
    if (paddedRight < 0 ||
        paddedBottom < 0 ||
        paddedLeft >= image.width ||
        paddedTop >= image.height) {
      continue;
    }

    final left = math.max(0, paddedLeft.floor());
    final top = math.max(0, paddedTop.floor());
    final right = math.min(image.width - 1, paddedRight.ceil());
    final bottom = math.min(image.height - 1, paddedBottom.ceil());
    if (right < left || bottom < top) continue;

    img.fillRect(
      image,
      x1: left,
      y1: top,
      x2: right,
      y2: bottom,
      color: img.ColorRgb8(0, 0, 0),
      alphaBlend: false,
    );
  }
  return image;
}
