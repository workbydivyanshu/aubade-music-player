import 'package:aubade/ui/components/artwork.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The widget derives memCacheWidth/Height and the on-disk tier from this
  // bucket, so the pure selection is what every decode cache key rides on.
  group('artworkDecodeBucket', () {
    test('small tiles decode at display size, not a fixed floor', () {
      // 56 dp at DPR 1.0 paints 56 px: snap to the next 16px step.
      expect(artworkDecodeBucket(56, 1.0), 64);
      // 220 dp no longer jumps to 320; it decodes near what it paints.
      expect(artworkDecodeBucket(220, 1.0), 224);
    });

    test('display size drives the bucket at DPR 2.0', () {
      // 56 dp at DPR 2.0 wants 112 physical px.
      expect(artworkDecodeBucket(56, 2.0), 112);
      // 220 dp at DPR 2.0 wants 440 physical px, not the old 640 bucket.
      expect(artworkDecodeBucket(220, 2.0), 448);
    });

    test('works between grid steps of the requested physical edge', () {
      expect(artworkDecodeBucket(112, 1.0), 112);
      expect(artworkDecodeBucket(113, 1.0), 128);
      expect(artworkDecodeBucket(480, 2.0), 960);
    });

    test('caps huge displays at the 1024 top bucket', () {
      // 600 dp at DPR 2.0 wants 1200 physical px; stay on the top bucket
      // instead of decoding the CDN master at native size.
      expect(artworkDecodeBucket(600, 2.0), 1024);
      expect(artworkDecodeBucket(1920, 1.0), 1024);
      expect(artworkDecodeBucket(2000, 2.0), 1024);
    });

    test('returns null when there is nothing to decode', () {
      expect(artworkDecodeBucket(0, 2.0), isNull);
      expect(artworkDecodeBucket(-10, 1.0), isNull);
    });
  });
}
