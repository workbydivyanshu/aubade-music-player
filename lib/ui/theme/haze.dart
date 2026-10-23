import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';

import '../../design_system/fluent/fluent.dart';
import 'tokens.dart';

export '../../design_system/fluent/fluent.dart'
    show LwHaze, LwHazeLevel, LwAmbientWash, lwHazeSpecs;

/// UI-layer Haze convenience.
///
/// New pages should use [WaveHaze] directly (L0–L3 levels). It honours
/// the user's Material setting (Automatic / Haze / Solid) and intensity
/// (Low / Medium / High) via [WaveHazeScope] — pages never branch on
/// prefs themselves.
enum WaveMaterialMode { automatic, haze, solid }

enum WaveHazeIntensity { low, medium, high }

class WaveHazeScope extends InheritedWidget {
  final WaveMaterialMode material;
  final WaveHazeIntensity intensity;
  const WaveHazeScope({
    super.key,
    required this.material,
    required this.intensity,
    required super.child,
  });

  static WaveHazeScope of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<WaveHazeScope>() ??
        const WaveHazeScope(
          material: WaveMaterialMode.automatic,
          intensity: WaveHazeIntensity.medium,
          child: SizedBox.shrink(),
        );
  }

  /// Blur is disabled in Solid mode (static tonal fallback everywhere).
  static bool blurEnabled(BuildContext context) =>
      of(context).material != WaveMaterialMode.solid;

  /// Whether [level] may filter on this device/settings combination.
  ///
  /// A caller's `enableBlur` is a request, never an override: Solid keeps
  /// every surface static whatever the surface asks for, and L1 (the
  /// thinnest material) stays tonal at low intensity instead of paying for
  /// a faint blur nobody can see.
  static bool allowsBlur(BuildContext context, LwHazeLevel level) {
    final scope = of(context);
    if (scope.material == WaveMaterialMode.solid) return false;
    if (level == LwHazeLevel.l1 && scope.intensity == WaveHazeIntensity.low) {
      return false;
    }
    return true;
  }

  /// Intensity scales the L1–L3 sigma: low 0.6× · medium 1.0× · high 1.25×.
  /// L1 skips the filter entirely on low (see [allowsBlur]); the remaining
  /// levels get the multiplier, which is all `LwHaze` needs.
  static double blurScale(BuildContext context) =>
      switch (of(context).intensity) {
        WaveHazeIntensity.low => 0.6,
        WaveHazeIntensity.medium => 1.0,
        WaveHazeIntensity.high => 1.25,
      };

  @override
  bool updateShouldNotify(WaveHazeScope old) =>
      material != old.material || intensity != old.intensity;
}

/// Haze material container honouring the user's material setting.
///
/// Thin wrapper over [LwHaze]: pages pass a level + child, the scope
/// decides blur vs. static tonal fallback.
class WaveHaze extends StatelessWidget {
  final LwHazeLevel level;
  final Widget child;
  final Color? base;
  final Color? artworkTint;
  final BorderRadiusGeometry borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;

  /// Request a backdrop filter on this surface. A request, not an
  /// override: the effective value is this AND [WaveHazeScope.allowsBlur],
  /// so Solid mode and L1-at-low always win. Defaults to true (null).
  final bool? enableBlur;

  const WaveHaze({
    super.key,
    required this.level,
    required this.child,
    this.base,
    this.artworkTint,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.shadow,
    this.enableBlur,
  });

  const WaveHaze.chrome({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l1,
        enableBlur = null,
        borderRadius = BorderRadius.zero;

  const WaveHaze.panel({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l2,
        enableBlur = null,
        borderRadius = BorderRadius.zero;

  const WaveHaze.flyout({
    super.key,
    required this.child,
    this.base,
    this.artworkTint,
    this.border,
    this.shadow,
  })  : level = LwHazeLevel.l3,
        enableBlur = null,
        borderRadius = const BorderRadius.all(Radius.circular(7));

  @override
  Widget build(BuildContext context) {
    final amoled = waveAmoled(context);
    // AMOLED: fully opaque true black — no artwork wash, no translucency,
    // no blur cost. Border/shadow/radius stay exactly as designed.
    if (amoled) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: borderRadius,
          border: border,
          boxShadow: shadow,
        ),
        child: child,
      );
    }
    return LwHaze(
      level: level,
      base: base,
      artworkTint: artworkTint,
      borderRadius: borderRadius,
      border: border,
      shadow: shadow,
      // The flag says "this surface wants a filter"; the scope says whether
      // it may have one. Passing an explicit `true` straight through would
      // blur even in Solid mode.
      enableBlur: (enableBlur ?? true) &&
          WaveHazeScope.allowsBlur(context, level),
      child: child,
    );
  }
}

/// Frosted chip for small chrome sitting on a colorful or animated
/// backdrop (Now Playing controls, lyrics toolbar, quality / up-next).
///
/// Bounded blur only. Falls back to a stronger tonal fill when Haze is
/// Solid or the user requested reduced transparency.
class WaveGlass extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  /// When false, skips the [BackdropFilter] and renders the tonal fill
  /// only. Use on pages that already composite over a full-window ambient
  /// stage (e.g. Now Playing): each live backdrop blur retains a GPU
  /// surface sampling everything behind it, which is the dominant RSS
  /// cost on Windows ANGLE.
  final bool blur;

  const WaveGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(7)),
    this.padding,
    this.blur = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final amoled = waveAmoled(context);
    final liquid = WaveSurfaceScope.liquidGlassOf(context);
    final reduceT = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final blurOn = blur && WaveHazeScope.blurEnabled(context) && !reduceT;
    // Extra translucency: same geometry, stronger frost (lower fill
    // alpha, larger sigma). OFF is byte-identical to the original render.
    final fillBase = amoled
        ? Colors.black
        : (dark ? const Color(0xFF121212) : const Color(0xFFF4F4F4));
    final fill = fillBase.withValues(
      alpha: amoled
          ? 1.0
          : (liquid
              ? (blurOn ? 0.30 : 0.62)
              : (blurOn ? 0.46 : 0.78)),
    );
    final edge = (amoled || dark ? Colors.white : Colors.black)
        .withValues(alpha: amoled ? 0.10 : (dark ? 0.16 : 0.10));

    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: borderRadius,
        border: Border.all(color: edge),
      ),
      child: child,
    );

    if (!blurOn) return content;
    final sigma = (liquid ? 26.0 : 18.0) * WaveHazeScope.blurScale(context);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: content,
      ),
    );
  }
}
