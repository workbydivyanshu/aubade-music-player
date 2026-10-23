import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;
import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/stream_models.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/scrobble_repository.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/library/local_track.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart';
import '../../features/settings/theme_controller.dart';
import '../components/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, LWVolumeSlider;
import '../components/focus_glyph.dart';
import '../components/marquee.dart';
import '../components/menus.dart';
import '../theme/haze.dart' show WaveHazeScope;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Coherent desktop music player — ONE floating plasma island, 82px,
/// three zones.
///
/// Geometry: margins LTRB(16, 0, 16, 12) floating over the window
/// background (Mica + page ambient glow shows through the gap), radius
/// 16 island, acrylic 24px blur, `0xCC16161A` fill lerp-ed with the
/// artwork tint at 6% (light theme: white `0xCCFFFFFF` fill + softer
/// black rims/shadows), chamfered rim (top 0x24 / rim 0x0C white),
/// black elevation + artwork aura shadows.
///
/// LEFT (290px): 52px artwork r8 + title 13.5/600 + artist 12 secondary +
/// like + more (truncate). CENTER (max 560): shuffle/prev/play/next/repeat
/// 18px + 3px timeline + tabular 11px timestamps. RIGHT (300px): quality
/// badge — streaming LOSSLESS/HI-RES pill (preserved verbatim) or local
/// `FLAC 24/96` capsule (format + bit depth/kHz, honest degradation when
/// header data is still null pre-backfill) + lyrics + queue + device +
/// 84px volume + expand + overflow (speed/sleep/Open Now Playing).
///
/// Always visible — placeholder when nothing is playing, never collapses.
/// Position ticks are scoped to [_DockProgress] only via
/// `select((s) => position/buffered/duration)`; the shell never rebuilds.

/// Local stream properties for the dock capsule — keyed by the SAME track
/// handle that drives artwork resolution ([PlayableTrack.playbackUrl]):
/// an absolute file path for local items, a videoId/query id for
/// streaming items (no `local_tracks` row → cleanly null, so the
/// streaming quality pill keeps its zone untouched). autoDispose: dies
/// with the dock identity, one sync SQLite point lookup per item change.
final _dockLocalTrackProvider =
    FutureProvider.autoDispose.family<LocalTrack?, String>((ref, key) {
  if (key.isEmpty) return null;
  try {
    // getLocalTrackByPath already nulls on failure; the guard is here so
    // a provider-level error can never cancel a future mid-flight.
    return ref.watch(databaseProvider).getLocalTrackByPath(key);
  } catch (_) {
    return null;
  }
});

/// kHz label — one decimal ONLY when fractional: 96000 → `96`,
/// 44100 → `44.1`.
String _khzLabel(int sampleRate) {
  final khz = sampleRate / 1000;
  final whole = khz.roundToDouble();
  return (khz - whole).abs() < 0.05
      ? whole.toStringAsFixed(0)
      : khz.toStringAsFixed(1);
}

/// Local capsule label, `[FLAC 24/96]`-style: uppercase format +
/// `bitDepth/kHz`; honest degradation — format only while header props
/// are still null (pre-backfill), depth-only `FLAC 24-bit`, rate-only
/// `FLAC 96`.
String _localQualityLabel(LocalTrack track) {
  final fmt = track.format.toUpperCase();
  final depth = track.bitDepth;
  final rate = track.sampleRate;
  if (depth == null && rate == null) return fmt;
  if (depth != null && rate != null) {
    return '$fmt $depth/${_khzLabel(rate)}';
  }
  if (depth != null) return '$fmt $depth-bit';
  return '$fmt ${_khzLabel(rate!)}';
}

/// Chamfered rim of the island — top 12% white, rim 5% white in dark;
/// softer black hairlines in light. Own helper (the spotlight surface
/// built its own rim; the two stay independent).
Border _dockRim(bool dark) => Border(
      top: BorderSide(
        color: dark ? const Color(0x33FFFFFF) : const Color(0x22000000),
      ),
      left: BorderSide(
        color: dark ? const Color(0x14FFFFFF) : const Color(0x0C000000),
      ),
      right: BorderSide(
        color: dark ? const Color(0x14FFFFFF) : const Color(0x0C000000),
      ),
      bottom: BorderSide(
        color: dark ? const Color(0x14FFFFFF) : const Color(0x0C000000),
      ),
    );

class WavePlayerDock extends ConsumerWidget {
  final VoidCallback onExpand;
  final VoidCallback onToggleQueue;
  final VoidCallback onToggleLyrics;
  final bool queueActive;
  final bool lyricsActive;
  final VoidCallback onToggleMini;
  const WavePlayerDock({
    super.key,
    required this.onExpand,
    required this.onToggleQueue,
    required this.onToggleLyrics,
    this.queueActive = false,
    this.lyricsActive = false,
    required this.onToggleMini,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    // NOTE: position/duration/buffered/volume/speed deliberately excluded
    // here so 1s ticks and volume drags never rebuild the whole dock.
    // _DockProgress owns position; _VolumeSection owns volume; _DockOverflow
    // owns speed/sleep. See perf audit.
    final player = ref.watch(playbackServiceProvider.select((s) => (
          current: s.current,
          stream: s.stream,
          shuffleEnabled: s.shuffleEnabled,
          isPlaying: s.isPlaying,
          isBuffering: s.isBuffering,
          repeatMode: s.repeatMode,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = player.current;
    final artworkUrl = player.current?.artworkUrl ?? '';
    final dockTint = ref.watch(artworkSeedProvider(artworkUrl)).valueOrNull;
    // Local stream properties for the current item. Streaming ids never
    // match a local_tracks row, so the capsule data degrades to null and
    // the streaming quality pill below keeps its zone untouched.
    final localTrack = current == null
        ? null
        : ref
            .watch(_dockLocalTrackProvider(current.playbackUrl))
            .valueOrNull;

    // Plasma island material (D1). One bounded blur layer over the
    // window background: the page ambient glow + Mica show through the
    // fill's translucency and the 12px/16px island margins — the
    // water-like effect arrives naturally, no scrim. Solid-material or
    // reduced-transparency users skip the live filter and get a stronger
    // tonal fill instead (the same guard the haze family uses: the
    // backdrop behind the island is static chrome, never ticking
    // content).
    final amoled = waveAmoled(context);
    final blurred = !amoled &&
        WaveHazeScope.blurEnabled(context) &&
        !(MediaQuery.maybeOf(context)?.highContrast ?? false);
    final islandFill = amoled
        ? Colors.black
        : (dark
            ? const Color(0xCC16161A)
            : const Color(0xCCFFFFFF)); // light: softer white equivalent.
    final baseFill = blurred
        ? islandFill
        : islandFill.withValues(alpha: amoled ? 1.0 : (dark ? 0.95 : 0.97));
    // 14% artwork-tint lerp; null seed (upstream clamp) → plain fill.
    // Liquid glass caustics: dynamic artwork radiance permeates the dock.
    final targetBase = amoled
        ? Colors.black
        : (dockTint == null
            ? baseFill
            : Color.lerp(baseFill, dockTint, 0.14) ?? baseFill);
    // Island shadows: deep black elevation + vibrant artwork caustic aura.
    final islandShadows = [
      BoxShadow(
        color: dark ? const Color(0x55000000) : const Color(0x1A000000),
        blurRadius: 28,
        offset: const Offset(0, 10),
      ),
      if (!amoled && dockTint != null)
        BoxShadow(
          color: dockTint.withValues(alpha: dark ? 0.22 : 0.14),
          blurRadius: 42,
          offset: const Offset(0, 6),
        ),
    ];
    // Fill + rim layer. Shadows live on the OUTER elevation container so
    // the blur clip never cuts them.
    final islandSurface = AnimatedContainer(
      duration: WaveMotion.normal,
      curve: WaveMotion.standard,
      decoration: BoxDecoration(
        color: targetBase,
        borderRadius: WaveRadius.islandRadius,
        border: _dockRim(dark),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
              // dockW = island content width (16px side margins already
              // eaten) — never MediaQuery window width, which also
              // ignores the rail (~200px). Thresholds stay
              // dock-relative; the island is deliberately narrower than
              // the old full-bleed dock.
              final dockW = constraints.maxWidth;
              final narrow = dockW < 680;
              return Row(
                children: [
                  // LEFT — identity (290px, placeholder when idle).
                  SizedBox(
                    width: narrow ? 200 : 290,
                    child: AnimatedSwitcher(
                      duration: WaveMotion.normal,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: child,
                      ),
                      child: current == null
                          ? _IdleIdentity(
                              key: const ValueKey('idle'),
                              onExpand: onExpand,
                            )
                          : KeyedSubtree(
                              key: ValueKey(current.queueKey),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: onExpand,
                                    child: LWTooltip(
                                      message: 'Open Now Playing',
                                      child: WaveArtwork(
                                        url: current.artworkUrl,
                                        videoId: current.videoId,
                                        // Island artwork: 52px r8.
                                        size: 52,
                                        radius: 8,
                                        label: current.title,
                                        title: current.title,
                                        artist: current.artist,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: onExpand,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          WaveMarqueeText(
                                            current.title,
                                            key: ValueKey(
                                                'dock-title-${current.queueKey}'),
                                            maxLines: 1,
                                            style:
                                                WaveType.trackTitle.copyWith(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            current.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: WaveType.meta.copyWith(
                                              fontSize: 12,
                                              color: dark
                                                  ? WaveColors.textSecondary
                                                  : WaveColors
                                                      .lightTextSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  _LikeGlyph(track: current),
                                  if (!narrow)
                                    _Glyph(
                                      tooltip: 'More',
                                      icon: WaveIcons.more,
                                      onTap: null,
                                      menuItems: waveTrackMenuItems(
                                        ref: ref,
                                        title: current.title,
                                        artist: current.artist,
                                        artworkUrl: current.artworkUrl,
                                        videoId: current.videoId,
                                        playable: current,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  // CENTER — transport + timeline. No minWidth: squeezes
                  // gracefully on tiny windows instead of overflowing.
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 560,
                          minWidth: 0,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _Glyph(
                                  tooltip: 'Shuffle',
                                  icon: WaveIcons.shuffle,
                                  active: player.shuffleEnabled,
                                  onTap: notifier.toggleShuffle,
                                ),
                                _Glyph(
                                  tooltip: 'Previous',
                                  icon: WaveIcons.previous,
                                  large: true,
                                  onTap: current == null
                                      ? null
                                      : notifier.previous,
                                ),
                                _PlayGlyph(
                                  playing: player.isPlaying,
                                  buffering: player.isBuffering,
                                  enabled: current != null,
                                  onTap: notifier.toggle,
                                ),
                                _Glyph(
                                  tooltip: 'Next',
                                  icon: WaveIcons.next,
                                  large: true,
                                  onTap: current == null
                                      ? null
                                      : notifier.next,
                                ),
                                _Glyph(
                                  tooltip:
                                      'Repeat ${player.repeatMode.name}',
                                  icon: player.repeatMode ==
                                          RepeatMode.one
                                      ? WaveIcons.repeatOne
                                      : WaveIcons.repeat,
                                  active: player.repeatMode !=
                                      RepeatMode.off,
                                  onTap: notifier.cycleRepeat,
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            _DockProgress(compact: narrow),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // RIGHT — priority groups, never icon soup (spec §7–8).
                  // HIGH: queue + volume + lyrics · MEDIUM: device + quality ·
                  // LOW: expand + mini + extras → overflow. No control ever
                  // leaves the viewport; secondary actions collapse into More.
                  Builder(builder: (context) {
                    // Thresholds are dock-relative (content width), aligned
                    // to canonical 900 breakpoint family.
                    final showLyrics = dockW >= 560;
                    // Capsule suppression thresholds untouched: quality
                    // shows at 900+ and despawns into More below. The
                    // streaming pill is preserved verbatim; the LOCAL
                    // capsule gets its own gate at the same width.
                    final showQuality =
                        dockW >= 900 && player.stream != null;
                    final localFormat = localTrack?.format ?? '';
                    final showLocalQuality = dockW >= 900 &&
                        player.stream == null &&
                        localFormat.isNotEmpty;
                    final showDevice = dockW >= 800;
                    final showVolumeSlider = dockW >= 800;
                    final showExpand = dockW >= 850;
                    final showMini = dockW >= 950;
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: dockW < 560
                            ? 110.0
                            : dockW < 800
                                ? 170.0
                                : 260.0,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (showQuality) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: 2),
                              child: _QualityFlyout(
                                stream: player.stream!,
                              ),
                            ),
                            const _StreamPathGlyph(),
                          ],
                          // LOCAL: [FLAC 24/96] capsule at the same slot
                          // (queue-panel region), same 900 width gate —
                          // fires only when the file actually carries
                          // header data and no stream resolved; rate /
                          // depth degrade honestly inside the label.
                          if (showLocalQuality)
                            _LocalQualityCapsule(track: localTrack!),
                          if (showLyrics)
                            _Glyph(
                              tooltip: 'Lyrics (Ctrl+L)',
                              icon: WaveIcons.lyrics,
                              active: lyricsActive,
                              onTap: onToggleLyrics,
                            ),
                          _Glyph(
                            tooltip: 'Queue',
                            icon: WaveIcons.queue,
                            active: queueActive,
                            onTap: onToggleQueue,
                          ),
                          if (showDevice) const _DeviceGlyph(),
                          if (showVolumeSlider)
                            const _VolumeSection()
                          else
                            const _VolumeFlyoutSection(),
                          if (showExpand)
                            _Glyph(
                              tooltip: 'Now Playing',
                              icon: WaveIcons.expand,
                              onTap: onExpand,
                            ),
                          if (showMini)
                            _Glyph(
                              tooltip: 'Mini player',
                              icon: WaveIcons.miniPlayer,
                              onTap: onToggleMini,
                            ),
                          _DockOverflow(
                            showLyricsItem: !showLyrics,
                            showQualityItem: !showQuality &&
                                player.stream != null,
                            localQualityLabel:
                                !showLocalQuality &&
                                        player.stream == null &&
                                        localTrack != null
                                    ? _localQualityLabel(localTrack)
                                    : null,
                            showDeviceItem: !showDevice,
                            showExpandItem: !showExpand,
                            showMiniItem: !showMini,
                            onToggleLyrics: onToggleLyrics,
                            onExpand: onExpand,
                            onToggleMini: onToggleMini,
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: WaveDensity.dock,
        child: RepaintBoundary(
          // Elevation paints the shadows OUTSIDE the blur clip; the aura
          // animates alongside the fill as the artwork seed changes.
          child: AnimatedContainer(
            duration: WaveMotion.normal,
            curve: WaveMotion.standard,
            decoration: BoxDecoration(
              borderRadius: WaveRadius.islandRadius,
              boxShadow: islandShadows,
            ),
            child: ClipRRect(
              borderRadius: WaveRadius.islandRadius,
              child: blurred
                  ? BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: islandSurface,
                    )
                  : islandSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder identity — dock never collapses to zero height.
class _IdleIdentity extends StatelessWidget {
  final VoidCallback onExpand;
  const _IdleIdentity({super.key, required this.onExpand});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Row(
      children: [
        const WaveArtwork(
          url: '',
          // Island artwork: 52px r8 (matches the identity slot).
          size: 52,
          radius: 8,
          label: 'Nothing playing',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nothing playing',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(fontSize: 13.5),
              ),
              Text(
                'Pick something to start',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                  fontSize: 12,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact quality status → Fluent MenuFlyout.
///
/// Badge stays tiny (LOSSLESS / HI-RES / AAC / OPUS). Click opens
/// format · sample rate · bit depth · codec · stream/download prefs.
class _QualityFlyout extends ConsumerStatefulWidget {
  final ResolvedStream stream;
  const _QualityFlyout({required this.stream});
  @override
  ConsumerState<_QualityFlyout> createState() => _QualityFlyoutState();
}

class _QualityFlyoutState extends ConsumerState<_QualityFlyout> {
  bool _hover = false;
  final _flyout = FlyoutController();
  @override
  void dispose() {
    _flyout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final s = widget.stream;
    return FlyoutTarget(
      controller: _flyout,
      child: LWTooltip(
        message:
            '${s.audioCodec}${s.bitrateKbps > 0 ? ' · ${s.bitrateKbps} kbps' : ''} — details',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () {
              _flyout.showFlyout(
                barrierColor: Colors.transparent,
                placementMode: FlyoutPlacementMode.topCenter,
                transitionDuration:
                    const Duration(milliseconds: 90),
                transitionBuilder: fastFlyoutTransition,
                builder: (context) => WaveFlyoutPanel.items(
                  entries: [
                    WaveMenuAction(
                      leading: const Icon(WaveIcons.gauge, size: 15),
                      label: '${s.qualityBadge} · ${s.audioCodec}',
                      onPressed: () {},
                    ),
                    const WaveMenuSeparator(),
                    WaveMenuAction(
                      leading: const Icon(WaveIcons.music, size: 15),
                      label: 'Sample rate · ${s.samplingRateKhz} kHz',
                      onPressed: () {},
                    ),
                    WaveMenuAction(
                      leading: const Icon(WaveIcons.mixes, size: 15),
                      label: 'Bit depth · ${s.bitDepth}-bit',
                      onPressed: () {},
                    ),
                    if (s.bitrateKbps > 0)
                      WaveMenuAction(
                        leading: const Icon(WaveIcons.clock, size: 15),
                        label: 'Bitrate · ${s.bitrateKbps} kbps',
                        onPressed: () {},
                      ),
                    const WaveMenuSeparator(),
                    WaveMenuAction(
                      leading: const Icon(WaveIcons.settings, size: 15),
                      label: 'Quality settings',
                      onPressed: () => context.go('/settings'),
                    ),
                  ],
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _hover
                    ? (dark ? Colors.white : Colors.black)
                        .withValues(alpha: WaveState.hoverAlpha)
                    : Colors.transparent,
                border: Border.all(
                  color: dark
                      ? WaveColors.outline
                      : WaveColors.lightOutline,
                ),
                borderRadius:
                    BorderRadius.circular(WaveRadius.controls),
              ),
              child: Text(
                s.qualityBadge,
                style: WaveType.overline.copyWith(
                  fontSize: 9,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Local-file quality capsule — `FLAC 24/96` twin of the streaming pill.
///
/// Static (no flyout): the details ARE the label; the tooltip carries the
/// full readout. Degrades honestly — format only while header props are
/// still null (pre-backfill); never invents values. Same slot / same
/// 900px gate as the streaming pill, and it despawns into More identically.
class _LocalQualityCapsule extends StatelessWidget {
  final LocalTrack track;
  const _LocalQualityCapsule({required this.track});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final fmt = track.format.toUpperCase();
    final details = <String>[
      fmt,
      if (track.bitDepth != null) '${track.bitDepth}-bit',
      if (track.sampleRate != null)
        '${_khzLabel(track.sampleRate!)} kHz',
    ].join(' · ');
    return LWTooltip(
      message: '$details — local file',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(
            color: dark ? WaveColors.outline : WaveColors.lightOutline,
          ),
          borderRadius: BorderRadius.circular(WaveRadius.controls),
        ),
        child: Text(
          _localQualityLabel(track),
          style: WaveType.overline.copyWith(
            fontSize: 9,
            color: dark
                ? WaveColors.textSecondary
                : WaveColors.lightTextSecondary,
          ),
        ),
      ),
    );
  }
}

/// Compact WASAPI / bit-perfect path — WinUI 3 MenuFlyout, dock-sized.
class _StreamPathGlyph extends ConsumerWidget {
  const _StreamPathGlyph();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(audioOutputProvider.select((s) => s.path));
    final outputLabel = path.outputLabel;
    return _Glyph(
      tooltip: path.bitPerfect
          ? '$outputLabel · Bit-Perfect'
          : '$outputLabel · Stream path',
      icon: WaveIcons.streamPath,
      active: path.bitPerfect,
      menuItems: [
        WaveMenuAction(
          leading: const Icon(WaveIcons.music, size: 15),
          label: 'Source · ${path.sourceLabel}',
          onPressed: () {},
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.device, size: 15),
          label: 'Output · ${path.outputLabel}',
          onPressed: () {},
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.speaker, size: 15),
          label: Platform.isWindows ? (
            path.exclusiveActive
                ? 'WASAPI · Exclusive'
                : 'WASAPI · Shared') : 'Output · System Default',
          onPressed: () {},
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.volume, size: 15),
          label: path.hardwareVolume
              ? 'Volume · DAC hardware'
              : (path.softwareVolume
                  ? 'Volume · Software'
                  : 'Volume · Unity'),
          onPressed: () {},
        ),
        const WaveMenuSeparator(),
        WaveMenuAction(
          leading: Icon(
            path.bitPerfect ? WaveIcons.likedFill : WaveIcons.streamPath,
            size: 15,
          ),
          label: path.bitPerfect ? 'Bit-Perfect' : path.reason.label,
          onPressed: () {},
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.settings, size: 15),
          label: 'Output settings',
          onPressed: () => context.go('/settings?section=audio'),
        ),
      ],
    );
  }
}

/// Plain glyph button — no coloured square wrapping.
class _Glyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool large;
  final VoidCallback? onTap;
  final List<WaveMenuEntry>? menuItems;
  const _Glyph({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.large = false,
    this.onTap,
    this.menuItems,
  });
  @override
  State<_Glyph> createState() => _GlyphState();
}

class _GlyphState extends State<_Glyph> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final disabled = widget.onTap == null && widget.menuItems == null;
    // B9 scale family, reduced-motion aware: one table (1.10 hover /
    // 0.90 press) instead of per-widget magic numbers.
    final scale = WaveMotion.interactionScaleFor(
      context,
      hovered: _hover,
      pressed: _pressed,
      hoverScale: 1.10,
      pressScale: 0.90,
    );
    final color = widget.active
        ? accent
        : disabled
            ? (dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary)
                .withValues(alpha: 0.5)
            : _hover
                ? (dark
                    ? WaveColors.textPrimary
                    : WaveColors.lightTextPrimary)
                : (dark
                    ? WaveColors.textSecondary
                    : WaveColors.lightTextSecondary);
    Widget glyph = FocusGlyph(
      enabled: !disabled,
      onActivate: widget.onTap,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
          onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
          onTapCancel: disabled ? null : () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: scale,
            duration: WaveMotion.fast,
            curve: Curves.easeOutCubic,
            child: Container(
              width: 34,
              height: 34,
              color: Colors.transparent,
              // Transport icons 18px, utility glyphs 15px (canonical).
              child: Icon(widget.icon,
                  size: widget.large ? 18 : 15, color: color),
            ),
          ),
        ),
      ),
    );
    if (widget.menuItems != null) {
      glyph = WaveMenuButton(
        entries: widget.menuItems!,
        placement: FlyoutPlacementMode.topRight,
        buttonBuilder: (context, onOpen) => FocusGlyph(
          onActivate: onOpen,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
            child: GestureDetector(
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              onTap: onOpen,
              child: AnimatedScale(
                scale: scale,
                duration: WaveMotion.fast,
                curve: Curves.easeOutCubic,
                child: Container(
                  width: 34,
                  height: 34,
                  color: Colors.transparent,
                  child: Icon(widget.icon, size: 15, color: color),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return LWTooltip(message: widget.tooltip, child: glyph);
  }
}

/// Fluent media transport button — 36px accent disc, NOT a giant FAB.
///
/// Uses the active [waveAccent] (Aubade / System / Artwork accent) with
/// contrast glyph, 1px tonal ring + restrained shadow. Hover 92%,
/// pressed 85%, focus ring 2px, tooltip with shortcut. Both themes.
class _PlayGlyph extends StatefulWidget {
  final bool playing;
  final bool buffering;
  final bool enabled;
  final VoidCallback onTap;
  const _PlayGlyph({
    required this.playing,
    required this.buffering,
    this.enabled = true,
    required this.onTap,
  });
  @override
  State<_PlayGlyph> createState() => _PlayGlyphState();
}

class _PlayGlyphState extends State<_PlayGlyph> {
  bool _hover = false;
  bool _pressed = false;
  final FocusNode _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final onAccent =
        accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    Color bg;
    if (!widget.enabled) {
      bg = accent.withValues(alpha: 0.35);
    } else if (_pressed) {
      bg = accent.withValues(alpha: 0.82);
    } else if (_hover) {
      bg = accent.withValues(alpha: 0.93);
    } else {
      bg = accent;
    }
    final fg = widget.enabled
        ? onAccent
        : onAccent.withValues(alpha: 0.5);
    return LWTooltip(
      message: widget.playing ? 'Pause (Space)' : 'Play (Space)',
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (node, event) {
          // Space is owned by the global shell handler (always toggles
          // playback, even when this glyph has focus). Enter still
          // activates the focused glyph natively.
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (widget.enabled) widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) {
            setState(() {
              _hover = false;
              _pressed = false;
            });
          },
          child: GestureDetector(
            onTapDown: (_) =>
                setState(() => _pressed = true),
            onTapUp: (_) =>
                setState(() => _pressed = false),
            onTapCancel: () =>
                setState(() => _pressed = false),
            onTap: widget.enabled ? widget.onTap : null,
            child: AnimatedScale(
              scale: WaveMotion.interactionScaleFor(
                context,
                hovered: _hover,
                pressed: _pressed,
                hoverScale: 1.06,
                pressScale: 0.92,
              ),
              duration: WaveMotion.fast,
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: WaveMotion.fast,
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg,
                  border: Border.all(
                    color: (_focus.hasFocus
                            ? accent
                            : (dark
                                ? Colors.white
                                : Colors.black))
                        .withValues(
                            alpha: _focus.hasFocus ? 0.9 : 0.14),
                    width: _focus.hasFocus ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: dark ? 0.45 : 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: widget.buffering
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: ProgressRing(
                            strokeWidth: 2.5,
                            activeColor: fg,
                            backgroundColor:
                                fg.withValues(alpha: 0.25),
                          ),
                        )
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                            scale: CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutBack,
                            ),
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          ),
                          child: Icon(
                            widget.playing
                                ? WaveIcons.pause
                                : WaveIcons.play,
                            key: ValueKey(widget.playing),
                            size: 15,
                            color: fg,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Position scope boundary: ONLY this widget subscribes to the 1s
/// position/buffered/duration stream. Thin 3px bar at rest with a small
/// thumb; hover enlarges the interaction region and shows a timestamp
/// via tooltip overlay (never clipped by the dock island); drag/click seeks;
/// ←/→ keys seek ±5s (Shift ±15s) when focused.
class _DockProgress extends ConsumerStatefulWidget {
  final bool compact;
  const _DockProgress({this.compact = false});
  @override
  ConsumerState<_DockProgress> createState() => _DockProgressState();
}

class _DockProgressState extends ConsumerState<_DockProgress> {
  final FocusNode _focus = FocusNode();
  final GlobalKey _barKey = GlobalKey();
  double? _hoverRatio;
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _seekBy(Duration base, Duration total, int seconds) {
    final target = base + Duration(seconds: seconds);
    final clamped = target.isNegative
        ? Duration.zero
        : (target > total ? total : target);
    ref.read(playbackServiceProvider.notifier).seek(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final clock = ref.watch(playbackServiceProvider.select((s) => (
          position: s.position,
          buffered: s.buffered,
          duration: s.duration,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final wavy = ref.watch(
      themeControllerProvider.select((t) => t.wavySeekbar),
    );
    final playing = ref.watch(
      playbackServiceProvider.select((s) => s.isPlaying),
    );

    final timeStyle = WaveType.meta.copyWith(
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
    );
    final totalMs = clock.duration.inMilliseconds;
    final hoverLabel = _hoverRatio == null || totalMs <= 0
        ? null
        : _fmt(Duration(
            milliseconds: (_hoverRatio! * totalMs).round()));
    // Compact windows hide timestamps so the timeline never overflows;
    // the hover tooltip still announces the seek target.
    final showTimes = !widget.compact;
    final progressFraction = totalMs > 0
        ? (clock.position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final bufferedFraction = totalMs > 0
        ? (clock.buffered.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final barColor = dark ? Colors.white : Colors.black;
    return Row(
      children: [
        if (showTimes)
          SizedBox(
            width: 38,
            child: Text(_fmt(clock.position),
                textAlign: TextAlign.right, style: timeStyle),
          ),
        if (showTimes) const SizedBox(width: 8),
        Expanded(
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (_, e) {
              if (e is! KeyDownEvent) return KeyEventResult.ignored;
              final shift = HardwareKeyboard.instance.logicalKeysPressed
                  .contains(LogicalKeyboardKey.shiftLeft) ||
                  HardwareKeyboard.instance.logicalKeysPressed
                      .contains(LogicalKeyboardKey.shiftRight);
              final step = shift ? 15 : 5;
              if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
                _seekBy(clock.position, clock.duration, step);
                return KeyEventResult.handled;
              }
              if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _seekBy(clock.position, clock.duration, -step);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: LWTooltip(
              message: hoverLabel ?? 'Seek (←/→ ±5s)',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onExit: (_) =>
                    setState(() => _hoverRatio = null),
                onHover: (e) {
                  final box = _barKey.currentContext
                      ?.findRenderObject() as RenderBox?;
                  if (box == null || !box.hasSize) return;
                  final ratio = (e.localPosition.dx / box.size.width)
                      .clamp(0.0, 1.0);
                  // Debounced: only rebuild on meaningful movement.
                  if ((ratio - (_hoverRatio ?? -1)).abs() > 0.01) {
                    setState(() => _hoverRatio = ratio);
                  }
                },
                child: GestureDetector(
                  onTapDown: (_) => _focus.requestFocus(),
                  behavior: HitTestBehavior.translucent,
                  child: Container(
                    key: _barKey,
                    // Larger interaction region without visibly bloating
                    // the bar: transparent padding.
                    padding:
                        const EdgeInsets.symmetric(vertical: 7),
                    color: Colors.transparent,
                    child: RepaintBoundary(
                      child: wavy
                          ? Stack(
                              children: [
                                // Decorative only: the real ProgressBar sits
                                // on top with transparent paint, keeping the
                                // exact same hit region and drag semantics.
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: _WavySeekTrack(
                                      progress: progressFraction,
                                      buffered: bufferedFraction,
                                      playing: playing,
                                      color: barColor,
                                      accent: accent,
                                    ),
                                  ),
                                ),
                                avp.ProgressBar(
                                  progress: clock.position,
                                  buffered: clock.buffered,
                                  total: clock.duration,
                                  onSeek: notifier.seek,
                                  barHeight: 3,
                                  thumbRadius: 5,
                                  thumbColor: Colors.transparent,
                                  thumbGlowColor: Colors.transparent,
                                  progressBarColor: Colors.transparent,
                                  bufferedBarColor: Colors.transparent,
                                  baseBarColor: Colors.transparent,
                                  timeLabelLocation:
                                      avp.TimeLabelLocation.none,
                                ),
                              ],
                            )
                          : avp.ProgressBar(
                              progress: clock.position,
                              buffered: clock.buffered,
                              total: clock.duration,
                              onSeek: notifier.seek,
                              barHeight: 3,
                              thumbRadius: 5,
                              thumbColor: barColor,
                              thumbGlowColor:
                                  accent.withValues(alpha: 0.25),
                              progressBarColor: barColor,
                              bufferedBarColor:
                                  barColor.withValues(alpha: 0.18),
                              baseBarColor:
                                  barColor.withValues(alpha: 0.12),
                              timeLabelLocation:
                                  avp.TimeLabelLocation.none,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showTimes) const SizedBox(width: 8),
        if (showTimes)
          SizedBox(
            width: 38,
            child: Text(_fmt(clock.duration), style: timeStyle),
          ),
      ],
    );
  }
}

/// Animated sine-warped seek track painted behind the transparent
/// [avp.ProgressBar]. Runs only while playing; paused/finished keeps the
/// last phase static. Purely decorative — no gesture handling here.
class _WavySeekTrack extends StatefulWidget {
  final double progress;
  final double buffered;
  final bool playing;
  final Color color;
  final Color accent;

  const _WavySeekTrack({
    required this.progress,
    required this.buffered,
    required this.playing,
    required this.color,
    required this.accent,
  });

  @override
  State<_WavySeekTrack> createState() => _WavySeekTrackState();
}

class _WavySeekTrackState extends State<_WavySeekTrack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase;

  @override
  void initState() {
    super.initState();
    _phase = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPhase();
  }

  @override
  void didUpdateWidget(covariant _WavySeekTrack old) {
    super.didUpdateWidget(old);
    _syncPhase();
  }

  void _syncPhase() {
    final run = widget.playing && !WaveMotion.respectReduce(context);
    if (run && !_phase.isAnimating) {
      _phase.repeat();
    } else if (!run && _phase.isAnimating) {
      // Leave the phase where it stopped: it is a static decoration when
      // paused/reduced, and resuming continues smoothly.
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _phase,
        builder: (context, _) => CustomPaint(
          painter: _WavySeekPainter(
            progress: widget.progress,
            buffered: widget.buffered,
            phase: _phase.value,
            color: widget.color,
            accent: widget.accent,
          ),
        ),
      ),
    );
  }
}

class _WavySeekPainter extends CustomPainter {
  final double progress;
  final double buffered;
  final double phase;
  final Color color;
  final Color accent;

  const _WavySeekPainter({
    required this.progress,
    required this.buffered,
    required this.phase,
    required this.color,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;
    // 3px visual band with a 1.4px undulation — the same footprint as the
    // stock 3px bar, just alive while playing.
    const amplitude = 1.4;
    const wavelength = 26.0;

    Path wave(double upto, {double amp = amplitude, double phaseShift = 0}) {
      final path = Path();
      final end = (size.width * upto.clamp(0.0, 1.0));
      for (var x = 0.0; x <= end + 0.5; x += 1.5) {
        final y = midY +
            math.sin((x / wavelength) * 2 * math.pi + phase * 2 * math.pi +
                    phaseShift) *
                amp;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.12);
    canvas.drawPath(wave(1), base);

    if (buffered > 0) {
      final bufferedPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.18);
      canvas.drawPath(wave(buffered), bufferedPaint);
    }

    if (progress > 0) {
      final progressPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [color, Color.lerp(color, accent, 0.55)!],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawPath(
        wave(progress, amp: amplitude + 0.6),
        progressPaint,
      );
    }

    // Thumb follows the wave crest so the seek affordance stays visible.
    final x = size.width * progress.clamp(0.0, 1.0);
    final y = midY +
        math.sin((x / wavelength) * 2 * math.pi + phase * 2 * math.pi) *
            amplitude;
    canvas.drawCircle(
      Offset(x, y),
      9,
      Paint()
        ..color = accent.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(x, y),
      5,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _WavySeekPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.phase != phase ||
      old.color != color ||
      old.accent != accent;
}

class _LikeGlyph extends ConsumerStatefulWidget {
  final PlayableTrack track;
  const _LikeGlyph({required this.track});

  @override
  ConsumerState<_LikeGlyph> createState() => _LikeGlyphState();
}

class _LikeGlyphState extends ConsumerState<_LikeGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      lowerBound: 0.8,
      upperBound: 1.25,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _onToggle() async {
    final liked =
        ref.read(likedKeysSetProvider).contains(widget.track.queueKey);
    // Pop only on like: 1.0 → 1.25 eased out, then settle to 1.0 with a
    // slight overshoot bounce. (Previously `forward(from: 0.8)` ran the
    // grow phase linear to the 1.25 bound — a visible jump — and the pop
    // fired on unlike too.) Settle is mounted-guarded so a track change
    // mid-pop can't drive a disposed controller.
    if (!liked && !WaveMotion.respectReduce(context)) {
      _anim
          .animateTo(1.25,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut)
          .then((_) => mounted
              ? _anim.animateTo(1.0,
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOutBack)
              : null);
    }
    final loved = await ref
        .read(playlistRepositoryProvider.notifier)
        .toggleLiked(
          StoredTrack(
            name: widget.track.title,
            artist: widget.track.artist,
            artworkUrl: widget.track.artworkUrl,
            videoId: widget.track.videoId,
          ),
        );
    if (!mounted) return;
    _syncLovedToLastFm(
      ref,
      artist: widget.track.artist,
      track: widget.track.title,
      loved: loved,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch the derived key set, not the playlist list: the notifier's
    // `updateShouldNotify` compares with setEquals, so this rebuilds only
    // when a like/unlike flips a key — not on rename/reorder/refresh.
    final liked = ref.watch(likedKeysSetProvider).contains(widget.track.queueKey);
    return ScaleTransition(
      scale: _anim,
      child: _Glyph(
        tooltip: liked ? 'Unlike' : 'Like',
        icon: liked ? WaveIcons.likedFill : WaveIcons.liked,
        active: liked,
        onTap: _onToggle,
      ),
    );
  }
}

/// Output device — WASAPI endpoints from the isolated engine.
class _DeviceGlyph extends ConsumerWidget {
  const _DeviceGlyph();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(audioOutputProvider);
    final name = output.selected?.displayName ?? 'System default';
    return _Glyph(
      tooltip: 'Output: $name',
      icon: WaveIcons.device,
      menuItems: [
        WaveMenuAction(
          leading: const Icon(WaveIcons.device, size: 15),
          label: 'System Default',
          onPressed: () =>
              ref.read(audioOutputProvider.notifier).selectDevice(''),
        ),
        for (final d in output.devices.take(8))
          WaveMenuAction(
            leading: Icon(
              WaveIcons.device,
              size: 15,
              color: d.id == output.selectedId ? waveAccent(context) : null,
            ),
            label: d.displayName,
            onPressed: () =>
                ref.read(audioOutputProvider.notifier).selectDevice(d.id),
          ),
        const WaveMenuSeparator(),
        WaveMenuAction(
          leading: const Icon(WaveIcons.settings, size: 15),
          label: 'Output settings',
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}

/// Isolated volume section — owns the volume select so drags never rebuild
/// the whole dock (perf audit).
class _VolumeSection extends ConsumerWidget {
  const _VolumeSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume =
        ref.watch(playbackServiceProvider.select((s) => s.volume));
    final output = ref.read(audioOutputProvider.notifier);
    return _VolumeGlyph(
      volume: volume,
      onMute: output.toggleMute,
      onVolume: output.setVolume,
    );
  }
}

/// Isolated collapsed-volume section with a real slider in the flyout.
class _VolumeFlyoutSection extends ConsumerWidget {
  const _VolumeFlyoutSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume =
        ref.watch(playbackServiceProvider.select((s) => s.volume));
    final output = ref.read(audioOutputProvider.notifier);
    return _VolumeFlyoutGlyph(
      volume: volume,
      onMute: output.toggleMute,
      onVolume: output.setVolume,
    );
  }
}

/// Fluent volume: mute glyph + 84px thin slider with percentage tooltip.
/// Keyboard arrows supported via [LWVolumeSlider] focus.
class _VolumeGlyph extends StatelessWidget {
  final double volume;
  final VoidCallback onMute;
  final ValueChanged<double> onVolume;
  const _VolumeGlyph({
    required this.volume,
    required this.onMute,
    required this.onVolume,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Glyph(
          tooltip: volume == 0
              ? 'Unmute'
              : 'Mute (${(volume * 100).round()}%)',
          icon: volume == 0
              ? WaveIcons.volumeMute
              : WaveIcons.volume,
          onTap: onMute,
        ),
        LWTooltip(
          message: '${(volume * 100).round()}%',
          child: LWVolumeSlider(
            value: volume.clamp(0.0, 1.0),
            onChanged: onVolume,
          ),
        ),
      ],
    );
  }
}

/// Collapsed volume: glyph opens a Fluent flyout WITH a real slider
/// (previously text-only, so volume could not be adjusted <1050px).
class _VolumeFlyoutGlyph extends ConsumerStatefulWidget {
  final double volume;
  final VoidCallback onMute;
  final ValueChanged<double> onVolume;
  const _VolumeFlyoutGlyph({
    required this.volume,
    required this.onMute,
    required this.onVolume,
  });
  @override
  ConsumerState<_VolumeFlyoutGlyph> createState() =>
      _VolumeFlyoutGlyphState();
}

class _VolumeFlyoutGlyphState extends ConsumerState<_VolumeFlyoutGlyph> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.volume;
    return FlyoutTarget(
      controller: _controller,
      child: LWTooltip(
        message: 'Volume (${(volume * 100).round()}%)',
        child: _Glyph(
          tooltip: 'Volume',
          icon: volume == 0
              ? WaveIcons.volumeMute
              : WaveIcons.volume,
          onTap: () {
            _controller.showFlyout(
              barrierColor: Colors.transparent,
              placementMode: FlyoutPlacementMode.topCenter,
              transitionDuration: const Duration(milliseconds: 90),
              transitionBuilder: fastFlyoutTransition,
              builder: (context) => WaveFlyoutPanel.child(
                maxWidth: 240,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Volume ${(volume * 100).round()}%',
                        style: WaveType.label,
                      ),
                      const SizedBox(height: 8),
                      LWVolumeSlider(
                        value: volume.clamp(0.0, 1.0),
                        onChanged: widget.onVolume,
                      ),
                      const SizedBox(height: 4),
                      HyperlinkButton(
                        onPressed: () {
                          widget.onMute();
                          _controller.close();
                        },
                        child: Text(volume == 0 ? 'Unmute' : 'Mute',
                            style: WaveType.label),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DockOverflow extends ConsumerWidget {
  final bool showLyricsItem;
  final bool showQualityItem;

  /// Local `[FLAC 24/96]` capsule label when it collapsed (narrow width
  /// or a streaming item owns the pill zone). Null = nothing to show.
  final String? localQualityLabel;
  final bool showDeviceItem;
  final bool showExpandItem;
  final bool showMiniItem;
  final VoidCallback onToggleLyrics;
  final VoidCallback onExpand;
  final VoidCallback onToggleMini;
  const _DockOverflow({
    this.showLyricsItem = false,
    this.showQualityItem = false,
    this.localQualityLabel,
    this.showDeviceItem = false,
    this.showExpandItem = false,
    this.showMiniItem = false,
    required this.onToggleLyrics,
    required this.onExpand,
    required this.onToggleMini,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playbackServiceProvider.notifier);
    final sleep = ref.watch(
      playbackServiceProvider.select((s) => s.sleepRemaining),
    );
    final stream = ref.watch(
      playbackServiceProvider.select((s) => s.stream),
    );
    final speed =
        ref.watch(playbackServiceProvider.select((s) => s.speed));
    final speedLabel =
        speed == speed.roundToDouble() ? '${speed.toInt()}' : '$speed';
    final localLabel = localQualityLabel;
    final hasCollapsed =
        showLyricsItem ||
        showQualityItem ||
        localLabel != null ||
        showDeviceItem ||
        showExpandItem ||
        showMiniItem;
    return _Glyph(
      tooltip: 'More',
      icon: WaveIcons.more,
      menuItems: [
        // Collapsed priority controls reappear here — nothing is lost
        // at narrow widths, nothing overflows the window.
        if (showLyricsItem)
          WaveMenuAction(
            leading: const Icon(WaveIcons.lyrics, size: 15),
            label: 'Lyrics  (Ctrl+L)',
            onPressed: onToggleLyrics,
          ),
        if (showQualityItem && stream != null)
          WaveMenuAction(
            leading: const Icon(WaveIcons.gauge, size: 15),
            label: '${stream.qualityBadge} · ${stream.audioCodec}',
            onPressed: () => context.go('/settings'),
          ),
        if (showQualityItem)
          WaveMenuAction(
            leading: const Icon(WaveIcons.streamPath, size: 15),
            label: ref.watch(audioOutputProvider.select((s) => s.path.bitPerfect))
                ? 'Stream path · Bit-Perfect'
                : 'Stream path',
            onPressed: () => context.go('/settings'),
          ),
        if (localLabel != null)
          WaveMenuAction(
            leading: const Icon(WaveIcons.gauge, size: 15),
            label: localLabel,
            onPressed: () => context.go('/settings'),
          ),
        if (showDeviceItem)
          WaveMenuAction(
            leading: const Icon(WaveIcons.device, size: 15),
            label: 'Output: System default',
            onPressed: () {},
          ),
        if (showExpandItem)
          WaveMenuAction(
            leading: const Icon(WaveIcons.expand, size: 15),
            label: 'Open Now Playing',
            onPressed: onExpand,
          ),
        if (showMiniItem)
          WaveMenuAction(
            leading:
                const Icon(WaveIcons.miniPlayer, size: 15),
            label: 'Mini player',
            onPressed: onToggleMini,
          ),
        if (hasCollapsed) const WaveMenuSeparator(),
        WaveMenuAction(
          leading: const Icon(WaveIcons.gauge, size: 15),
          label: 'Speed $speedLabel×',
          onPressed: notifier.cycleSpeed,
        ),
        WaveMenuAction(
          leading: const Icon(WaveIcons.clock, size: 15),
          label: sleep == null
              ? 'Sleep timer · 30 min'
              : 'Sleep ${sleep.inMinutes}m (tap to clear)',
          onPressed: () {
            if (sleep != null) {
              notifier.setSleepTimer(null);
            } else {
              notifier.setSleepTimer(const Duration(minutes: 30));
            }
          },
        ),
      ],
    );
  }
}

/// Mirrors a local like/unlike into Last.fm (`track.love` /
/// `track.unlove`). Fire-and-forget by design: the local toggle already
/// landed, the call is only made for a signed-in session, and
/// [ScrobbleRepository.setLoved] itself no-ops without one — nothing
/// here may block the UI. (Duplicated in menus.dart and track_row.dart
/// to keep the component domains dependency-light.)
void _syncLovedToLastFm(
  WidgetRef ref, {
  required String artist,
  required String track,
  required bool loved,
}) {
  if (artist.isEmpty || track.isEmpty) return;
  if (ref.read(authRepositoryProvider).status != AuthStatus.signedIn) {
    return;
  }
  unawaited(ref.read(scrobbleRepositoryProvider).setLoved(
        artist: artist,
        track: track,
        loved: loved,
      ));
}
