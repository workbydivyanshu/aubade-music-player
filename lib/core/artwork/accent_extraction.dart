import 'package:flutter/painting.dart';

/// Shipped accent (crimson). Kept local so this core helper has no UI
/// token dependency; [WaveColors.defaultAccent] is the same value.
const _defaultAccent = Color(0xFFE03030);

/// Picks a usable theme accent out of an artwork palette.
///
/// Pure function (no image decode): callers pass the palette swatches
/// extracted by the existing artwork pipeline. The winner is the most
/// saturated, mid-lightness swatch; its lightness is then clamped so the
/// result stays legible both as a fill and as 1px text on dark and light
/// surfaces. Grayscale / near-black / blown-out covers fall back to the
/// shipped accent rather than painting a muddy tint.
Color deriveArtworkAccent(
  Iterable<Color> swatches, {
  Color fallback = _defaultAccent,
}) {
  Color? best;
  var bestScore = double.negativeInfinity;
  for (final c in swatches) {
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.18) continue;
    final luminance = c.computeLuminance();
    if (luminance < 0.02 || luminance > 0.92) continue;
    // Prefer chroma; gently penalise extremes of lightness.
    final score = hsl.saturation - (hsl.lightness - 0.5).abs();
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  final picked = best ?? fallback;
  final hsl = HSLColor.fromColor(picked);
  return hsl
      .withLightness(hsl.lightness.clamp(0.38, 0.66))
      .withSaturation(hsl.saturation.clamp(0.35, 1.0))
      .toColor();
}
