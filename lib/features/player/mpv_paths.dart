/// mpv on-disk paths. Split out of `playback_service.dart` so the pure
/// parts stay unit-testable without the generated secrets import chain.
library;

import 'dart:io';

/// Demuxer on-disk cache dir (mpv `cache-dir`). mpv's default location
/// fails to create on this setup (`Failed to create file cache` on
/// every open), so the app pins an explicit dir it creates itself.
/// Root is `XDG_CACHE_HOME` when set, else `$HOME/.cache`; the system
/// temp dir is the last-resort fallback when neither is available.
/// [environment] is a test seam (defaults to [Platform.environment]).
String mpvCacheDirPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final sep = Platform.pathSeparator;
  final xdg = env['XDG_CACHE_HOME']?.trim();
  final home = env['HOME']?.trim();
  final root = (xdg != null && xdg.isNotEmpty)
      ? xdg
      : (home != null && home.isNotEmpty)
          ? '$home$sep.cache'
          : Directory.systemTemp.path;
  return '$root${sep}aubade${sep}mpv-cache';
}

/// Best-effort recursive mkdir. Never throws; empty path is a no-op.
Future<void> ensureDirExists(String path) async {
  if (path.trim().isEmpty) return;
  try {
    await Directory(path).create(recursive: true);
  } catch (_) {}
}
