import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Semantic Fluent surfaces — the single authoritative [LwColors] palette.
///
/// This is the only `LwColors` definition in the app. The retired ice-blue
/// copy from `lib/design_system/tokens.dart` was merged into the legacy
/// block at the bottom of this class; that file re-exports [LwColors] so
/// its existing consumers keep compiling unchanged.
///
/// New code should read surfaces through [LwSurfaces] (context-aware) or
/// the raw [LwColors] constants below. Do NOT scatter hex literals in
/// pages: import this file.
///
/// Mapping to the canonical Wave tokens (`lib/ui/theme/tokens.dart`):
/// - surfaceBase      → scaffold / Mica base
/// - surfaceLayer1/2  → content layering (cards stay flat, layers differ)
/// - surfaceMica      → native Mica base (window.dart paints this)
/// - surfaceAcrylic   → title chrome / suggestion flyout base
/// - surfaceHaze      → Haze Level 1/2 tonal wash (see aubade_materials.dart)
/// - surfaceElevated  → player dock / raised controls
/// - surfaceFlyout    → MenuFlyout / ContentDialog / popover (Haze L3)
/// - surfacePlayer    → persistent player dock (Haze L1 + hairline)
/// - surfaceSelection → selected row wash (accent 10%)
///
/// Text + interaction tokens mirror WinUI rest visuals:
/// hover 7% wash · pressed 12% · selected accent wash · focus 2px ring.
class LwColors {
  LwColors._();

  // -- Dark (graphite, zero navy) -----------------------------------------
  static const surfaceBase = WaveColors.background; // #0E0E0E
  static const surfaceBaseDeep = WaveColors.backgroundDeep; // #0A0A0A
  static const surfaceLayer1 = WaveColors.surface; // #161616
  static const surfaceLayer2 = WaveColors.surfaceRaised; // #1E1E1E
  static const surfaceMica = WaveColors.background;
  static const surfaceAcrylic = WaveColors.panelTranslucent; // 0xE6161616
  static const surfaceHaze = WaveColors.panelTranslucent;
  static const surfaceElevated = WaveColors.surfaceOverlay; // #262626
  static const surfaceFlyout = WaveColors.surfaceRaised; // #1E1E1E
  static const surfacePlayer = WaveColors.dockTranslucent; // 0xF2141414
  static const surfaceSelection = WaveColors.accentDim; // ring + wash base

  static const divider = WaveColors.outlineSoft; // #1F1F1F hairline
  static const dividerStrong = WaveColors.outline; // #2B2B2B

  static const accent = WaveColors.defaultAccent; // shipped default (crimson)
  static const success = WaveColors.success;
  static const warn = WaveColors.warn;
  static const danger = WaveColors.danger;

  // -- Light (neutral off-white, not beige / not pure white) ---------------
  static const lightSurfaceBase = WaveColors.lightBackground; // #F3F3F3
  static const lightSurfaceNav = WaveColors.lightNavBackground; // #ECECEC
  static const lightSurfaceLayer1 = WaveColors.lightContent; // #F9F9F9
  static const lightSurfaceLayer2 = WaveColors.lightSurface; // #FFFFFF
  static const lightSurfaceFlyout = WaveColors.lightSurface;
  static const lightSurfacePlayer = WaveColors.lightSurface;
  static const lightDivider = WaveColors.lightOutlineSoft;
  static const lightDividerStrong = WaveColors.lightOutline;

  // -- Legacy kit palette (verbatim values, frozen) ------------------------
  // `lib/design_system/components.dart` and
  // `lib/features/lyrics/lyrics_view.dart` still paint the retired
  // ice-blue palette below. Values are kept byte-for-byte so this token
  // consolidation changes no pixels. New code must use the Wave tokens
  // above (or [LwSurfaces]); the legacy block is deleted once those two
  // surfaces are re-tokenised.
  static const background = Color(0xFF070A12);
  static const surface = Color(0xFF0D1119);
  static const surfaceRaised = Color(0xFF131824);
  static const surfaceOverlay = Color(0xFF1A2130);
  static const outline = Color(0xFF26304A);
  static const outlineSoft = Color(0xFF151C2C);

  /// Fine luminous top edge used on floating docks / panels (8-10% white).
  static const luminousEdge = Color(0x1AFFFFFF);

  static const dockTranslucent = Color(0xE9131824);

  // Legacy text ramp — intentionally not the Wave ramp (see waveText* in
  // `lib/ui/theme/tokens.dart`); these consumers render the old values.
  static const textPrimary = Color(0xFFF2F4F9);
  static const textSecondary = Color(0xFFA7AEC0);
  static const textTertiary = Color(0xFF6B7386);

  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceOverlay = Color(0xFFE9EDF4);
  static const lightOutline = Color(0xFFDDE3EE);
  static const lightOutlineSoft = Color(0xFFEAEEF5);
  static const lightTextPrimary = Color(0xFF0E131C);
  static const lightTextSecondary = Color(0xFF4A5468);
  static const lightTextTertiary = Color(0xFF8A94A8);
  static const lightDockTranslucent = Color(0xF5FFFFFF);
}

/// Context-aware surface resolution (dark ↔ light).
class LwSurfaces {
  LwSurfaces._();

  static bool isDark(BuildContext context) => waveIsDark(context);

  static Color base(BuildContext context) =>
      isDark(context) ? LwColors.surfaceBase : LwColors.lightSurfaceBase;

  static Color layer1(BuildContext context) => isDark(context)
      ? LwColors.surfaceLayer1
      : LwColors.lightSurfaceLayer1;

  static Color layer2(BuildContext context) => isDark(context)
      ? LwColors.surfaceLayer2
      : LwColors.lightSurfaceLayer2;

  static Color flyout(BuildContext context) => isDark(context)
      ? LwColors.surfaceFlyout
      : LwColors.lightSurfaceFlyout;

  static Color player(BuildContext context) => isDark(context)
      ? LwColors.surfacePlayer
      : LwColors.lightSurfacePlayer.withValues(alpha: 0.97);

  static Color textPrimary(BuildContext context) => waveTextPrimary(context);
  static Color textSecondary(BuildContext context) =>
      waveTextSecondary(context);
  static Color textTertiary(BuildContext context) => waveTextTertiary(context);
  static Color divider(BuildContext context) => waveDivider(context);

  /// Artwork accent: runtime tint applied sparingly (Now Playing wash,
  /// hero wash ≤12%). Base surfaces stay neutral — artwork adds
  /// atmosphere, never floods the app.
  static Color artworkAccent(BuildContext context, Color? tint) =>
      tint ?? waveAccent(context);
}
