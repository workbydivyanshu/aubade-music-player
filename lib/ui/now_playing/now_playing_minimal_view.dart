import 'package:fluent_ui/fluent_ui.dart' hide Colors;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/animated_artwork_service.dart';
import '../../core/artwork/animated_artwork_session.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/performance/performance_controller.dart';
import '../components/ambient.dart';
import '../components/animated_artwork_video.dart';
import '../components/artwork.dart';
import '../queue/queue_panel.dart';
import 'immersive.dart';
import 'now_playing_overflow_menu.dart';

/// Minimal Now Playing layout: Sharp cover art (with motion art and
/// hi-res official artwork), centered metadata, and distraction-free synced lyrics.
class NowPlayingMinimalView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final VoidCallback onClose;

  const NowPlayingMinimalView({
    super.key,
    required this.track,
    required this.onClose,
  });

  @override
  ConsumerState<NowPlayingMinimalView> createState() =>
      _NowPlayingMinimalViewState();
}

class _NowPlayingMinimalViewState extends ConsumerState<NowPlayingMinimalView> {
  bool _showQueue = false;
  String _lastClipUrl = '';
  bool _sleeveGone = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isPerfMode = ref.watch(performanceModeProvider);
    final isImmersive = ref.watch(nowPlayingImmersiveProvider);

    final motionAsync = isPerfMode
        ? const AsyncData<AnimatedArtwork?>(null)
        : ref.watch(
            animatedArtworkProvider(
              AnimatedArtworkQuery(
                artist: track.artist,
                album: track.album,
                title: track.title,
              ),
            ),
          );
    final motionArt = motionAsync.valueOrNull;
    final clipUrl = motionArt?.hasUrl == true ? motionArt!.url : '';
    if (!motionAsync.isLoading || clipUrl.isNotEmpty) {
      _lastClipUrl = clipUrl;
    }
    final activeUrl = isPerfMode
        ? ''
        : (clipUrl.isNotEmpty
            ? clipUrl
            : (motionAsync.isLoading ? _lastClipUrl : ''));
    final videoReady = !isPerfMode &&
        clipUrl.isNotEmpty &&
        ref.watch(
          animatedArtworkSessionProvider.select((s) => s.isReadyFor(clipUrl)),
        );
    if (!videoReady) _sleeveGone = false;
    final showSleeve = !videoReady || !_sleeveGone;

    return Stack(
      children: [
        // 1. Backdrop: Cached single-pass artwork-tinted ambient stage
        Positioned.fill(
          child: RepaintBoundary(
            child: WaveAmbientMesh(
              artworkUrl: track.artworkUrl,
              isFullBleed: true,
              cinematic: true,
            ),
          ),
        ),

        // 2. Main Two-Column Row (Album Cover + Centered Info on Left, Synced Lyrics on Right)
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
            child: Row(
              children: [
                // Left Column: Sharp square cover (Motion / Hi-Res Art) + centered title & artist
                Expanded(
                  flex: 42,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 420,
                        maxHeight: 520,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: 420,
                              maxHeight: 420,
                            ),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: LayoutBuilder(
                                builder: (context, box) {
                                  final side = box.maxWidth;
                                  return RepaintBoundary(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(2.0),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (activeUrl.isNotEmpty)
                                            AnimatedArtworkVideo(
                                              url: activeUrl,
                                              size: side,
                                            ),
                                          if (showSleeve)
                                            AnimatedOpacity(
                                              opacity: videoReady ? 0.0 : 1.0,
                                              duration: const Duration(
                                                milliseconds: 320,
                                              ),
                                              curve: Curves.easeOut,
                                              onEnd: () {
                                                if (videoReady &&
                                                    !_sleeveGone &&
                                                    mounted) {
                                                  setState(
                                                    () => _sleeveGone = true,
                                                  );
                                                }
                                              },
                                              child: WaveArtwork(
                                                url: track.artworkUrl,
                                                videoId: track.videoId,
                                                size: side,
                                                radius: 2.0,
                                                label: track.title,
                                                title: track.title,
                                                artist: track.artist,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Centered Track Title
                          Text(
                            track.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Centered Artist Name
                          Text(
                            track.artist,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 48),

                // Right Column: Synced Lyrics at full height or Queue
                Expanded(
                  flex: 58,
                  child: ClipRect(
                    child: _showQueue
                        ? const WaveQueuePanel(
                            onClose: null,
                            embedded: true,
                          )
                        : WaveKaraokeLyricsView(
                            track: track,
                            compact: false,
                            showHeaderControls: false,
                            fontSize: 34.0,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 3. Top-Left Back / Close button (when in immersive fullscreen)
        if (isImmersive)
          Positioned(
            top: 18,
            left: 20,
            child: _MinimalIconButton(
              icon: FluentIcons.chevron_left,
              tooltip: 'Exit fullscreen (F11)',
              onTap: () {
                ref.read(nowPlayingImmersiveProvider.notifier).state = false;
              },
            ),
          ),

        // 4. Unified Top-Right Action Bar
        Positioned(
          top: 18,
          right: 20,
          child: NowPlayingTopActions(
            track: track,
            showAmbientToggle: true,
            isQueueOpen: _showQueue,
            onToggleQueue: () => setState(() => _showQueue = !_showQueue),
          ),
        ),
      ],
    );
  }
}

class _MinimalIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MinimalIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_MinimalIconButton> createState() => _MinimalIconButtonState();
}

class _MinimalIconButtonState extends State<_MinimalIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _hover ? 0.20 : 0.10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: 15,
                color: Colors.white.withValues(alpha: _hover ? 1.0 : 0.85),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
