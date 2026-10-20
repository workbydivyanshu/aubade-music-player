import 'package:fluent_ui/fluent_ui.dart';

/// App-wide surface flags resolved once at the root from [ThemeState].
///
/// Widgets read these via [of] / the `WaveSurfaces` helpers instead of
/// re-reading prefs at each call site. Defaults keep every standalone
/// widget (tests, previews) on the stock rendering.
class WaveSurfaceScope extends InheritedWidget {
  /// AMOLED black: force opaque-black surfaces regardless of Pearl/Midnight.
  final bool amoled;

  /// "Extra translucency": frosted glass on decorative panels/cards.
  final bool liquidGlass;

  const WaveSurfaceScope({
    super.key,
    this.amoled = false,
    this.liquidGlass = false,
    required super.child,
  });

  static WaveSurfaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WaveSurfaceScope>();

  static bool amoledOf(BuildContext context) =>
      maybeOf(context)?.amoled ?? false;

  static bool liquidGlassOf(BuildContext context) =>
      maybeOf(context)?.liquidGlass ?? false;

  @override
  bool updateShouldNotify(WaveSurfaceScope old) =>
      amoled != old.amoled || liquidGlass != old.liquidGlass;
}
