import 'package:aubade/ui/components/artwork.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The widget derives memCacheWidth/Height and the on-disk tier from this
  // bucket, so the pure selection is what every decode cache key rides on.
  group('artworkDecodeBucket', () {
    test('snaps small tiles to the 320 bucket at DPR 1.0', () {
      expect(artworkDecodeBucket(56, 1.0), 320);
      expect(artworkDecodeBucket(220, 1.0), 320);
    });

    test('snaps mid tiles to the 640 bucket at DPR 2.0', () {
      // 220 dp at DPR 2.0 wants 440 physical px: the 640 bucket, below
      // the 1024 top bucket memCacheWidth can ever reach on these tiers.
      expect(artworkDecodeBucket(220, 2.0), 640);
    });

    test('caps at the 1024 top bucket, native above it', () {
      // 480 dp hero at DPR 2.0 wants 960 physical px.
      expect(artworkDecodeBucket(480, 2.0), 1024);
      expect(artworkDecodeBucket(600, 2.0), isNull);
    });
  });
}
