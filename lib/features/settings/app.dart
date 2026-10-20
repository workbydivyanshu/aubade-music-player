import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/window.dart';
import '../../app/window_lifecycle.dart';
import '../../app/auth_gate.dart';
import '../../core/network/network_monitor.dart';
import '../../design_system/fluent/lw_scrollbar.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/scrobble_repository.dart';
import '../../ui/theme/fluent_theme.dart';
import '../../ui/theme/haze.dart';
import '../../ui/theme/tokens.dart';
import '../player/playback_service.dart';
import '../audio_output/output_controller.dart';
import '../mpris/mpris_service.dart';
import '../smtc/smtc_service.dart';
import '../presence/discord_presence_service.dart';
import 'theme_controller.dart';
import '../library/stream_props_backfill.dart';

/// Aubade desktop application root.
///
/// Single primary system: FluentApp router + Wave Fluent theme.
/// Native window material via flutter_acrylic/window_manager.
///
/// Last.fm authentication is optional (local-first): [AuthGate] is
/// seeded from the synchronously-loaded prefs session and follows the
/// live auth state, driving the router redirect — the app boots straight
/// into the library shell for signed-in users and keyless guests alike;
/// only a fresh install with neither a session nor a guest flag lands on
/// the welcome screen.
class AubadeApp extends ConsumerStatefulWidget {
  const AubadeApp({super.key});
  @override
  ConsumerState<AubadeApp> createState() => _AubadeAppState();
}

class _AubadeAppState extends ConsumerState<AubadeApp> {
  late final GoRouter _router;
  late final AuthGate _gate;

  @override
  void initState() {
    super.initState();
    // Prefs are fully loaded before runApp, and AuthRepository restores
    // the same state synchronously — the first frame routes correctly.
    _gate = AuthGate(
      initialInside: true,
    );
    _router = buildRouter(gate: _gate);
    // Warm start (non-blocking, best-effort): create the single
    // persistent media_kit/libmpv player and bring up the audio
    // output, presence and platform integrations.
    Future.microtask(() {
      try {
        ref.read(playbackServiceProvider.notifier).ensurePlayer();
      } catch (_) {}
      try {
        ref.read(audioOutputProvider.notifier).attach();
      } catch (_) {}
      try {
        // Discord Rich Presence: own block so an audio failure above can
        // never skip it; never throws (Discord closed degrades to silence).
        ref.read(discordPresenceProvider).startup();
      } catch (_) {}
      try {
        // MPRIS (Linux): exposes now-playing + transport on the session
        // bus for bars, playerctl and media keys. No-op elsewhere.
        ref.read(mprisProvider).startup();
      } catch (_) {}
      try {
        // SMTC (Windows): volume flyout, lock screen, Bluetooth and
        // hardware media keys. No-op elsewhere.
        ref.read(smtcProvider).startup();
      } catch (_) {}
      // One-shot stream-props backfill (sample rate / bit depth / size)
      // for libraries scanned before v0.01.08. Silent; runs on the
      // shared 16-worker idiom and flags itself done in prefs.
      unawaited(backfillStreamPropsOnceIfNeeded(ref));
    });
  }

  @override
  void dispose() {
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
        themeControllerProvider.select(
            (t) => (isLight: t.isLight, amoled: t.amoled)),
        (_, v) => applyWindowMaterial(
            isLight: v.isLight && !v.amoled));
    // Live auth state drives the gate (login, logout, guest entry,
    // session expiry). Guests count as inside.
    ref.listen(
        authRepositoryProvider.select((a) =>
            a.status == AuthStatus.signedIn ||
            a.status == AuthStatus.guest),
        (_, inside) => _gate.update(inside));
    // Reconnect edge: drain any scrobbles queued while offline as soon
    // as the network monitor comes back up (offline → online only).
    ref.listen(networkMonitorProvider, (prev, next) {
      if (next && (prev ?? false) == false) {
        unawaited(ref.read(scrobbleRepositoryProvider).flushQueue());
      }
    });
    final theme = ref.watch(themeControllerProvider);
    final accent = ref.watch(resolvedAccentProvider);
    // AMOLED is deep dark regardless of the Pearl/Midnight preference.
    final isLight = theme.isLight && !theme.amoled;

    final darkTheme = buildWaveFluentTheme(
      accent: accent,
      isLight: false,
      amoled: theme.amoled,
    );
    final lightTheme = buildWaveFluentTheme(
      accent: accent,
      isLight: true,
    );

    return WaveSurfaceScope(
      amoled: theme.amoled,
      liquidGlass: theme.liquidGlass,
      child: WaveHazeScope(
        material: switch (theme.hazeMaterial) {
          'haze' => WaveMaterialMode.haze,
          'solid' => WaveMaterialMode.solid,
          _ => WaveMaterialMode.automatic,
        },
        intensity: switch (theme.hazeIntensity) {
          'low' => WaveHazeIntensity.low,
          'high' => WaveHazeIntensity.high,
          _ => WaveHazeIntensity.medium,
        },
        child: WindowLifecycle(
          child: FluentApp.router(
            title: 'Aubade',
            debugShowCheckedModeBanner: false,
            theme: lightTheme,
            darkTheme: darkTheme,
            themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
            routerConfig: _router,
            // ONE Fluent scrollbar treatment everywhere: thin, fades when
            // idle, no browser-style horizontal bars under carousels.
            scrollBehavior: const WaveScrollBehavior(),
            // No acrylic anywhere: fluent MenuFlyout/ComboBox render a
            // fullscreen BackdropFilter blur unless DisableAcrylic is
            // present — that blur sample on the open frame is the hitch
            // on every toolbar popup. The app is opaque dark anyway, so
            // solid flyouts read identically. (Own haze system untouched.)
            builder: (context, child) =>
                DisableAcrylic(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}
