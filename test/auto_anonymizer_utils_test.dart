import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:little_memories/auto_anonymizer_utils.dart';

void main() {
  group('applyFacePrivacyMasks', () {
    test('masks detected regions and preserves pixels outside them', () {
      final image = img.Image(width: 32, height: 24);
      img.fill(image, color: img.ColorRgb8(240, 240, 240));

      applyFacePrivacyMasks(image, [const Rect.fromLTWH(8, 6, 8, 10)]);

      expect(image.getPixel(10, 8).r, 0);
      expect(image.getPixel(0, 0).r, 240);
      expect(image.getPixel(31, 23).r, 240);
    });

    test('expands masks by the configured padding fraction', () {
      final image = img.Image(width: 20, height: 20);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));

      applyFacePrivacyMasks(
        image,
        [const Rect.fromLTWH(6, 6, 4, 4)],
        paddingFraction: 0.5,
      );

      expect(image.getPixel(4, 4).r, 0);
      expect(image.getPixel(3, 3).r, 255);
    });

    test('clips partly off-image boxes safely', () {
      final image = img.Image(width: 8, height: 8);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));

      expect(
        () => applyFacePrivacyMasks(
          image,
          [const Rect.fromLTWH(-20, -20, 30, 30)],
        ),
        returnsNormally,
      );
      expect(image.getPixel(0, 0).r, 0);
    });

    test('ignores empty and wholly out-of-bounds boxes', () {
      final image = img.Image(width: 8, height: 8);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));

      applyFacePrivacyMasks(image, [
        const Rect.fromLTWH(2, 2, 0, 0),
        const Rect.fromLTWH(20, 20, 4, 4),
      ]);

      expect(image.getPixel(2, 2).r, 255);
      expect(image.getPixel(7, 7).r, 255);
    });
  });
}
