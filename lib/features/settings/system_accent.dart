import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// OS accent fallbacks used when the platform does not expose one (or
/// the query fails). Each platform's stock accent, not a second branded
/// default — selecting "System accent" on any OS still visibly changes
/// the seed.
Color platformSystemAccentDefault() {
  if (Platform.isWindows) return const Color(0xFF0078D4);
  if (Platform.isMacOS) return const Color(0xFF0A84FF);
  return const Color(0xFF3584E4);
}

/// Parses `reg query ... /v ColorizationColor` output
/// (`ColorizationColor    REG_DWORD    0xc40078d7`). DWM stores ARGB;
/// the accent is the RGB triplet, opaque. Returns null when no value is
/// present so callers can fall back.
Color? parseWindowsColorizationColor(String output) {
  final match = RegExp(r'0x([0-9A-Fa-f]{8})').firstMatch(output);
  if (match == null) return null;
  final argb = int.tryParse(match.group(1)!, radix: 16);
  if (argb == null) return null;
  return Color(0xFF000000 | (argb & 0x00FFFFFF));
}

Future<Color> _querySystemAccent() async {
  if (Platform.isWindows) {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\DWM',
        '/v',
        'ColorizationColor',
      ]);
      final parsed = parseWindowsColorizationColor(result.stdout.toString());
      if (parsed != null) return parsed;
    } catch (_) {
      // Best-effort: fall through to the stock platform accent.
    }
  }
  return platformSystemAccentDefault();
}

/// Effective OS accent. Async because Windows reads DWM; every other
/// platform resolves immediately to its stock accent.
final systemAccentProvider = FutureProvider<Color>((ref) {
  return _querySystemAccent();
});
