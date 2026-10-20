import 'package:flutter/material.dart';

// [LwColors] now has a single definition in
// `lib/design_system/fluent/aubade_colors.dart` (the Fluent alias palette).
// Re-exported here so existing frozen-kit imports keep resolving.
export 'fluent/aubade_colors.dart' show LwColors;

/// Aubade editorial design tokens — single source of spacing, radius,
/// type, motion, density and breakpoint values.
///
/// Direction: premium editorial desktop music experience with restrained
/// futuristic details. Composition carries richness (rail + ledger +
/// dock + contextual panel), not decorative glass. Translucency is
/// selective (shell, dock, overlays); content stays readable.
///
/// Replaces the previous "observatory" boxed dashboard values:
/// - rail replaces 232px sidebar (now 76px icon ledger)
/// - header 52px unifies identity + history + compact search
/// - dock 76px three-zone replaces 96px bar
/// - ledger rows 52px replace 60px boxed rows
class LwSpacing {
  LwSpacing._();
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 48;
}

class LwRadius {
  LwRadius._();
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;
}

class LwMotion {
  LwMotion._();
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
}

/// Global motion/transparency kill-switches (accessibility + perf).
class LwMotionScope extends InheritedWidget {
  final bool reduceMotion;
  final bool reduceTransparency;
  const LwMotionScope({
    super.key,
    required this.reduceMotion,
    required this.reduceTransparency,
    required super.child,
  });

  static LwMotionScope of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<LwMotionScope>() ??
        const LwMotionScope(
          reduceMotion: false,
          reduceTransparency: false,
          child: SizedBox.shrink(),
        );
  }

  static bool motionOK(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LwMotionScope>();
    return !(scope?.reduceMotion ?? false);
  }

  static bool transparencyOK(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LwMotionScope>();
    return !(scope?.reduceTransparency ?? false);
  }

  @override
  bool updateShouldNotify(LwMotionScope old) =>
      reduceMotion != old.reduceMotion ||
      reduceTransparency != old.reduceTransparency;
}

/// Editorial type: display leads pages, headline leads sections, micro
/// kickers label hierarchy. Tabular figures for times/counts.
class LwType {
  LwType._();

  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.1,
  );
  static const headline = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.25,
  );
  static const title = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 13, height: 1.5);
  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
  static const caption = TextStyle(fontSize: 12, height: 1.45);
  static const micro = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
  );

  /// Large editorial numeral (charts, counts).
  static const numeral = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Lyrics reading styles.
  static const lyricActive = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.55,
    letterSpacing: -0.2,
  );
  static const lyricIdle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.55,
  );
}

/// Desktop breakpoints — editorial responsive rules.
///
/// - compact (<900): mini rail + single column, dock condenses,
///   Now Playing becomes tabbed single column.
/// - normal (900–1300): rail + content, dock full three-zone.
/// - expanded (1300–1700): + contextual queue/lyrics panel 320px.
/// - ultrawide (1700+): content max-width centers, panel 360px.
enum LwBreakpoint { compact, normal, expanded, ultrawide }

LwBreakpoint breakpointFor(double width) {
  if (width >= 1700) return LwBreakpoint.ultrawide;
  if (width >= 1300) return LwBreakpoint.expanded;
  if (width >= 900) return LwBreakpoint.normal;
  return LwBreakpoint.compact;
}

/// Editorial density targets (px).
///
/// Old boxed values retired: sidebar 232, player 96, track 60.
/// New ledger values enforce the replacement composition even in
/// monochrome (no decoration needed to tell them apart).
class LwDensity {
  LwDensity._();

  // Legacy names kept for any lingering call sites — now rail values.
  static const double sidebarExpanded = 76;
  static const double sidebarCollapsed = 56;
  static const double topBar = 52;
  static const double trackRow = 52;
  static const double playerBar = 76;

  // Editorial canonicals.
  static const double rail = 76;
  static const double railMini = 56;
  static const double header = 52;
  static const double dock = 76;
  static const double ledgerRow = 52;
  static const double ledgerArt = 40;
  static const double queueRow = 52;
  static const double collectionArt = 160;
  static const double featureArt = 272;
  static const double panel = 320;
  static const double panelWide = 360;
  static const double contentMax = 1160;
  static const double lyricMax = 640;

  static const double navIcon = 18;
  static const double icon = 16;
  static const double controlIcon = 20;
  static const double cardMin = 150;
  static const double cardMax = 210;
}

/// Bounded blur radii — only these surfaces may use backdrop blur.
/// Never blur rows, lists, or full windows.
class LwBlur {
  LwBlur._();
  static const double dock = 18;
  static const double panel = 14;
  static const double dialog = 12;
}
