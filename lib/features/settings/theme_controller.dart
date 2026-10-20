import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../ui/components/ambient.dart' show artworkAccentColorProvider;
import '../../ui/theme/tokens.dart';
import '../player/playback_service.dart';
import 'system_accent.dart';

/// App theme state (accent + AMOLED + pearl/midnight mode + Haze prefs).
class ThemeState {
  final Color accent;
  final bool amoled;
  final bool isLight;
  final bool dynamicArtwork;
  final bool liquidGlass;
  final bool wavySeekbar;
  final String hazeMaterial;
  final String hazeIntensity;
  final String accentSource;
  const ThemeState({
    required this.accent,
    required this.amoled,
    this.isLight = false,
    this.dynamicArtwork = false,
    this.liquidGlass = false,
    this.wavySeekbar = false,
    this.hazeMaterial = 'automatic',
    this.hazeIntensity = 'medium',
    this.accentSource = 'custom',
  });

  /// Resolves the accent actually painted by the theme.
  ///
  /// - Explicit sources win: `aubade` is the designed neutral, `system`
  ///   uses the OS accent, `artwork` uses the cover accent.
  /// - `custom` (the default) keeps the user's swatch, unless the Dynamic
  ///   artwork theme toggle is on and a cover accent is available.
  /// - Any unavailable artwork/system value falls back to the user accent
  ///   (which itself defaults to the shipped crimson).
  Color resolveAccent({Color? artworkAccent, Color? systemAccent}) {
    switch (accentSource) {
      case 'aubade':
        return isLight && !amoled
            ? WaveColors.lightTextPrimary
            : WaveColors.neutralAccent;
      case 'system':
        return systemAccent ?? accent;
      case 'artwork':
        return artworkAccent ?? accent;
      default:
        if (dynamicArtwork && artworkAccent != null) return artworkAccent;
        return accent;
    }
  }
}

class ThemeController extends StateNotifier<ThemeState> {
  final Prefs _prefs;
  ThemeController(this._prefs)
      : super(ThemeState(
          accent: Color(_prefs.accentColor),
          amoled: _prefs.amoled,
          isLight: _prefs.isLight,
          dynamicArtwork: _prefs.dynamicNowPlaying,
          liquidGlass: _prefs.liquidGlass,
          wavySeekbar: _prefs.wavySeekbar,
          hazeMaterial: _prefs.hazeMaterial,
          hazeIntensity: _prefs.hazeIntensity,
          accentSource: _prefs.accentSource,
        ));

  void refresh() {
    state = ThemeState(
      accent: Color(_prefs.accentColor),
      amoled: _prefs.amoled,
      isLight: _prefs.isLight,
      dynamicArtwork: _prefs.dynamicNowPlaying,
      liquidGlass: _prefs.liquidGlass,
      wavySeekbar: _prefs.wavySeekbar,
      hazeMaterial: _prefs.hazeMaterial,
      hazeIntensity: _prefs.hazeIntensity,
      accentSource: _prefs.accentSource,
    );
  }

  Future<void> setThemeMode(bool light) async {
    await _prefs.setThemeMode(light ? 'light' : 'dark');
    refresh();
  }
}

final themeControllerProvider =
    StateNotifierProvider<ThemeController, ThemeState>((ref) {
  return ThemeController(ref.watch(prefsProvider));
});

/// The single accent source for the whole app. Kept outside widgets so
/// no page reads prefs or extracts palette colours itself.
final resolvedAccentProvider = Provider.autoDispose<Color>((ref) {
  final theme = ref.watch(themeControllerProvider);
  final wantsArtwork = theme.accentSource == 'artwork' ||
      (theme.dynamicArtwork && theme.accentSource == 'custom');

  Color? artworkAccent;
  if (wantsArtwork) {
    final url = ref.watch(
      playbackServiceProvider.select((s) => s.current?.artworkUrl ?? ''),
    );
    if (url.isNotEmpty) {
      artworkAccent =
          ref.watch(artworkAccentColorProvider(url)).valueOrNull;
    }
  }

  Color? systemAccent;
  if (theme.accentSource == 'system') {
    systemAccent = ref.watch(systemAccentProvider).valueOrNull;
  }

  return theme.resolveAccent(
    artworkAccent: artworkAccent,
    systemAccent: systemAccent,
  );
});
