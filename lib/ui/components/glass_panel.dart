import 'dart:ui' show ImageFilter;

import 'package:fluent_ui/fluent_ui.dart';

import '../theme/haze.dart';
import '../theme/tokens.dart';

/// Decorative panel/card container with an opt-in frosted-glass pass.
///
/// OFF (default): paints exactly the static [tint]/[border]/[shadow] the
/// caller passes — pixel-identical to the pre-existing container.
///
/// ON (`Extra translucency` / [WaveSurfaceScope.liquidGlass]): keeps the
/// same geometry, lowers the fill alpha and adds ONE bounded
/// [BackdropFilter] with a reusable blur sigma. Solid Haze and
/// high-contrast both keep the opaque fallback (blur is never forced on
/// against the material setting).
class GlassPanel extends StatelessWidget {
  final Widget child;
  final Color? tint;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry? padding;
  final Border? border;
  final List<BoxShadow>? shadow;
  final double blurSigma;

  const GlassPanel({
    super.key,
    required this.child,
    this.tint,
    this.borderRadius = BorderRadius.zero,
    this.padding,
    this.border,
    this.shadow,
    this.blurSigma = 20,
  });

  @override
  Widget build(BuildContext context) {
    final fill = tint ?? waveSurface(context);
    final liquid = WaveSurfaceScope.liquidGlassOf(context);
    final amoled = waveAmoled(context);
    final reduceT = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final blurOn = liquid && WaveHazeScope.blurEnabled(context) && !reduceT;
    // Near-transparent tints (the hero wash is ~12%) would vanish inside
    // the blur; lift them to a readable frosted fill when glass is on.
    final glassAlpha = fill.a < 0.3 ? 0.22 : fill.a * 0.55;

    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: amoled
            ? Colors.black
            : (blurOn ? fill.withValues(alpha: glassAlpha) : fill),
        borderRadius: borderRadius,
        border:
            border ??
            (blurOn
                ? Border.all(
                    color: (waveIsDark(context) ? Colors.white : Colors.black)
                        .withValues(alpha: amoled ? 0.08 : 0.14),
                  )
                : null),
        boxShadow: shadow,
      ),
      child: child,
    );

    if (!blurOn || amoled) return content;
    final radius = borderRadius is BorderRadius
        ? borderRadius as BorderRadius
        : BorderRadius.zero;
    final sigma = blurSigma * WaveHazeScope.blurScale(context);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: content,
      ),
    );
  }
}
