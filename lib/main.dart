import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/open_with.dart';
import 'app/window.dart';
import 'core/artwork/artwork_resolver.dart';
import 'core/artwork/official_artwork_service.dart';
import 'core/error/fatal_crumbs.dart';
import 'core/platform/allocator_tuning.dart';
import 'core/storage/app_database.dart';
import 'core/storage/prefs.dart';
import 'features/settings/app.dart';
import 'features/search/shared_providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // macOS launch services deliver Finder opens on this channel. Register
  // before prefs, database or window work so the native flush at launch
  // end is never dropped; early paths wait in the pending-intent hook.
  registerOpenWithChannel();

  // "Open with Aubade": decide before prefs, database or window work.
  // A second launch forwards its files to the owner and exits silently.
  final runMode = await decideRunMode(args);
  if (runMode is Handoff) exit(0);
  // Append, not replace: channel paths may already be waiting.
  addPendingOpenPaths(runMode.paths);

  // Fatal breadcrumbs: log-and-continue-handling (return false) so the
  // next fail-fast names its line in mpv-ops.log. Sync writes only.
  FlutterError.onError = (details) {
    writeFatalCrumb(fatalCrumb(details.exception, details.stack));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    writeFatalCrumb(fatalCrumb(error, stack));
    return false;
  };
  // Freeze glibc's dynamic mmap/trim thresholds before anything large is
  // allocated: without this, libmpv's per-track multi-MB buffers end up
  // on a heap that never gives the pages back (+80 MB of RSS per track
  // change, measured). Linux-only and best-effort; see
  // core/platform/allocator_tuning.dart.
  applyAllocatorTuning();
  // High-performance desktop image cache budget: 384 MiB / 1,000 images
  // prevents texture thrashing, frame drops, and repeat decoding while scrolling.
  PaintingBinding.instance.imageCache.maximumSize = 1000;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      384 << 20; // 384 MiB
  // libmpv is deliberately NOT dlopened here. MediaKit.ensureInitialized()
  // just dlopens a multi-MB .so (media_kit's NativeLibrary), pure
  // first-frame latency, and nothing on the first frame needs it: the
  // warm-start player is created on a post-first-frame microtask, and
  // motion art only after a track plays. The call now lives at the top of
  // PlaybackService.ensurePlayer (and defensively in the motion-art
  // session), so the dlopen happens after the shell has painted. It is
  // idempotent, so ordering is preserved for both Player() call sites.

  // Image-cache database (cached_network_image → sqflite) needs the
  // desktop FFI backend, otherwise every thumbnail silently fails.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Secrets are compiled in (obfuscated) via `dart tool/obfuscate_secrets.dart`.
  final prefs = await Prefs.load();
  final database = await AppDatabase.open();
  OfficialArtworkService.instance.init(db: database);

  await setupWindow();

  // Cap the on-disk image cache that backs CachedNetworkImage (default
  // keeps 200+ files / 30 days → 759 CacheObjects in the heap dump).
  // Bounded disk cache also keeps decoded-image re-creation cheap.
  ArtworkResolver.trimDiskCacheIfNeeded();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
      ],
      child: const AubadeApp(),
    ),
  );
}
