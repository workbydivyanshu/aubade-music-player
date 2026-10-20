import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/core/artwork/accent_extraction.dart';
import 'package:aubade/features/settings/system_accent.dart';
import 'package:aubade/features/settings/theme_controller.dart';
import 'package:aubade/ui/theme/fluent_theme.dart';
import 'package:aubade/ui/theme/tokens.dart';

void main() {
  group('WaveSurfaces AMOLED mapping', () {
    test('AMOLED forces every base surface to true black', () {
      expect(WaveSurfaces.background(isDark: true, amoled: true), Colors.black);
      expect(
        WaveSurfaces.background(isDark: false, amoled: true),
        Colors.black,
        reason: 'AMOLED is deep dark even when Pearl was selected',
      );
      expect(WaveSurfaces.surface(isDark: false, amoled: true), Colors.black);
      expect(
        WaveSurfaces.surfaceRaised(isDark: false, amoled: true),
        Colors.black,
      );
      expect(
        WaveSurfaces.surfaceOverlay(isDark: false, amoled: true),
        Colors.black,
      );
    });

    test('AMOLED off preserves the shipped surfaces', () {
      expect(
        WaveSurfaces.background(isDark: true, amoled: false),
        WaveColors.background,
      );
      expect(
        WaveSurfaces.background(isDark: false, amoled: false),
        WaveColors.lightBackground,
      );
      expect(
        WaveSurfaces.surface(isDark: true, amoled: false),
        WaveColors.surface,
      );
      expect(
        WaveSurfaces.surfaceRaised(isDark: false, amoled: false),
        WaveColors.lightSurfaceRaised,
      );
    });
  });

  group('deriveArtworkAccent', () {
    test('picks the most saturated usable swatch', () {
      final accent = deriveArtworkAccent(const [
        Color(0xFF808080), // grayscale, rejected
        Color(0xFF3A2418), // near-black brown
        Color(0xFF1E88E5), // saturated blue
        Color(0xFFE8DFD0), // cream, low saturation
      ]);
      final hsl = HSLColor.fromColor(accent);
      expect(hsl.saturation, greaterThan(0.5));
      // Blue hue retained (not a fallback crimson).
      expect(
        hsl.hue,
        closeTo(HSLColor.fromColor(const Color(0xFF1E88E5)).hue, 2),
      );
    });

    test('grayscale artwork falls back to the shipped accent', () {
      expect(
        deriveArtworkAccent(const [
          Color(0xFF000000),
          Color(0xFF808080),
          Color(0xFFFFFFFF),
        ]),
        const Color(0xFFE03030),
      );
    });
  });

  group('ThemeState.resolveAccent', () {
    const custom = Color(0xFF123456);
    const artwork = Color(0xFFAB12CD);
    const system = Color(0xFF0078D4);

    ThemeState state({String source = 'custom', bool dynamic = false}) =>
        ThemeState(
          accent: custom,
          amoled: false,
          accentSource: source,
          dynamicArtwork: dynamic,
        );

    test('custom/aubade/system/artwork each change the seed', () {
      expect(
        state().resolveAccent(artworkAccent: artwork, systemAccent: system),
        custom,
      );
      expect(state(source: 'aubade').resolveAccent(), WaveColors.neutralAccent);
      expect(
        const ThemeState(
          accent: custom,
          amoled: false,
          isLight: true,
          accentSource: 'aubade',
        ).resolveAccent(),
        WaveColors.lightTextPrimary,
      );
      expect(
        state(source: 'system').resolveAccent(systemAccent: system),
        system,
      );
      expect(
        state(source: 'artwork').resolveAccent(artworkAccent: artwork),
        artwork,
      );
    });

    test('dynamic artwork applies on the default custom source', () {
      expect(
        state(
          source: 'custom',
          dynamic: true,
        ).resolveAccent(artworkAccent: artwork),
        artwork,
      );
    });

    test('explicit accent sources still win while dynamic is on', () {
      expect(
        state(
          source: 'system',
          dynamic: true,
        ).resolveAccent(artworkAccent: artwork, systemAccent: system),
        system,
      );
      expect(
        state(
          source: 'aubade',
          dynamic: true,
        ).resolveAccent(artworkAccent: artwork),
        WaveColors.neutralAccent,
      );
    });

    test('missing artwork falls back to the user/default accent', () {
      expect(state(source: 'artwork', dynamic: true).resolveAccent(), custom);
    });
  });

  group('theme accent', () {
    test('Pearl seeds from the one shipped accent, never a blue fallback', () {
      final light = buildWaveFluentTheme(
        accent: WaveColors.defaultAccent,
        isLight: true,
      );
      expect(light.accentColor.normal, WaveColors.defaultAccent);
    });

    test('a fully transparent accent falls back to the shipped crimson', () {
      final light = buildWaveFluentTheme(
        accent: Colors.transparent,
        isLight: true,
      );
      expect(light.accentColor.normal, WaveColors.defaultAccent);
    });
  });

  group('system accent', () {
    test('parses DWM ARGB ColorizationColor as opaque RGB', () {
      expect(
        parseWindowsColorizationColor(
          '    ColorizationColor    REG_DWORD    0xc40078d7',
        ),
        const Color(0xFF0078D7),
      );
    });

    test('returns null when the value is absent', () {
      expect(parseWindowsColorizationColor('no value here'), isNull);
    });
  });
}
