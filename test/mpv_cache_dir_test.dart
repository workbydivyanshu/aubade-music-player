import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aubade/features/player/mpv_paths.dart';

void main() {
  final sep = Platform.pathSeparator;

  test('mpv cache dir honours XDG_CACHE_HOME', () {
    final xdg = '${Directory.systemTemp.path}${sep}xdg-cache';
    final path = mpvCacheDirPath(environment: {
      'XDG_CACHE_HOME': xdg,
      'HOME': '${sep}ignored-home',
    });
    expect(path, '$xdg${sep}aubade${sep}mpv-cache');
  });

  test('mpv cache dir falls back to \$HOME/.cache', () {
    final home = '${Directory.systemTemp.path}${sep}fake-home';
    final path = mpvCacheDirPath(environment: {'HOME': home});
    expect(path, '$home$sep.cache${sep}aubade${sep}mpv-cache');
  });

  test('ensureDirExists creates missing dirs and never throws', () async {
    final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}aubade-test-cache-probe');
    if (await dir.exists()) await dir.delete(recursive: true);
    await ensureDirExists(dir.path);
    expect(await dir.exists(), isTrue);
    await ensureDirExists(dir.path); // idempotent
    await ensureDirExists('');
    await dir.delete(recursive: true);
  });
}
