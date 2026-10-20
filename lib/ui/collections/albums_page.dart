import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/library/local_library_providers.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/shared_providers.dart'
    show databaseProvider;
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

class _Album {
  final String title;
  final String artist;
  final String artwork;
  final String browseId;
  const _Album(this.title, this.artist, this.artwork, this.browseId);
}

/// Albums grid reads straight from the on-device library: local
/// albums only, no last.fm top-albums / YouTube new-releases legs.
/// `browseId` carries the album name as the /album/:id route key —
/// the detail page resolves it against `local_tracks` (and falls
/// back to the YouTube catalog for real YT browseIds routed from
/// search/track links).
final _waveAlbumsProvider =
    FutureProvider<List<_Album>>((ref) async {
  final rows = ref.watch(localAlbumsProvider);
  return rows
      .map((m) => _Album(
            (m['album'] as String?) ?? 'Unknown Album',
            (m['album_artist'] as String?) ?? 'Unknown Artist',
            (m['artwork_path'] as String?) ?? '',
            (m['album'] as String?) ?? 'Unknown Album',
          ))
      .toList();
});

/// Albums — premium responsive grid (max180/extent218, 160px art radius 6,
/// hover quick-play 44px + more + playing indicator).
class WaveAlbumsPage extends ConsumerWidget {
  const WaveAlbumsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_waveAlbumsProvider);
    return albums.when(
      loading: () => const WaveLoading(label: 'Loading albums…'),
      error: (e, _) => WaveError(
        title: 'Could not load albums',
        message: '$e',
        onRetry: () => ref.invalidate(_waveAlbumsProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'No albums yet',
            subtitle:
                'Add your music folders in Library, scan, and your albums appear here.',
          );
        }
        return WaveEntranceGroup(
          child: CustomScrollView(
            slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(28, 22, 28, 12),
                child: WaveEntrance(
                  rise: 10,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text('Albums',
                          style: WaveType.pageTitle
                              .copyWith(fontSize: 24)),
                      Text('${list.length} records',
                          style: WaveType.meta.copyWith(
                              color: waveTextSecondary(
                                  context))),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(28, 0, 28, 28),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 218,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final a = list[i];
                    return WaveEntrance(
                      index: i,
                      rise: 10,
                      child: _AlbumCard(album: a),
                    );
                  },
                  childCount: list.length,
                ),
              ),
            ),
          ],
          ),
        );
      },
    );
  }
}

class _AlbumCard extends ConsumerStatefulWidget {
  final _Album album;
  const _AlbumCard({required this.album});
  @override
  ConsumerState<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<_AlbumCard> {
  bool _hover = false;
  bool _pressed = false;

  Future<void> _open() async {
    final a = widget.album;
    // browseId carries the local album name; the detail page resolves
    // it against the local library.
    context.go('/album/${Uri.encodeComponent(a.browseId)}');
  }

  Future<void> _quickPlay() async {
    final a = widget.album;
    try {
      final tracks =
          ref.read(databaseProvider).getLocalTracksForAlbum(a.browseId);
      if (tracks.isNotEmpty) {
        final queue = tracks
            .map((t) => GeneratedTrack(
                  name: t.title,
                  artist: t.artist,
                  album: t.album,
                  artworkUrl: t.artworkPath != null
                      ? 'file://${t.artworkPath}'
                      : '',
                  videoId: '',
                  durationSeconds: t.duration.inSeconds,
                  // Absolute file path → PlaybackService local fast path.
                  playbackUrl: t.path,
                ))
            .toList();
        await playGenerated(ref, context, queue.first,
            sourceLabel: a.title, queueAll: queue);
        return;
      }
    } catch (_) {}
    if (mounted) await _open();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.album;
    final dark = waveIsDark(context);
    final playing = ref.watch(
      playbackServiceProvider.select(
        (s) =>
            s.current != null &&
            (s.sourceLabel == a.title ||
                (s.current!.album == a.title &&
                    s.current!.artist == a.artist)),
      ),
    );
    
    void play() => _open();
    void quickPlay() => _quickPlay();
    return MouseRegion(
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
        onTap: play,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: WaveMotion.normal,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: _hover
                  ? (waveIsDark(context) ? Colors.white : Colors.black)
                      .withValues(alpha: 0.05)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                if (_hover)
                  BoxShadow(
                    color: Colors.black.withValues(
                        alpha: dark ? 0.45 : 0.18),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
              ],
            ),
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                        url: a.artwork,
                        size: 160,
                        radius: 6,
                        label: a.title,
                        title: a.title,
                        artist: a.artist,
                        kind: ArtworkKind.album),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: WaveMotion.fast,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.55),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Center(
                            child: AnimatedScale(
                              scale: _hover ? 1.0 : 0.70,
                              duration: WaveMotion.fast,
                              curve: Curves.easeOutBack,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  LWTooltip(
                                    message: 'Play ${a.title}',
                                    child: GestureDetector(
                                      onTap: quickPlay,
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        decoration:
                                            const BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                            FluentIcons.play,
                                            size: 18,
                                            color: Colors.black),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  WaveOverflowButton(
                                    tooltip: 'More',
                                    items: waveTrackMenuItems(
                                      ref: ref,
                                      title: a.title,
                                      artist: a.artist,
                                      artworkUrl: a.artwork,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (playing)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black
                              .withValues(alpha: 0.7),
                          borderRadius:
                              BorderRadius.circular(999),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(WaveIcons.queue,
                                size: 11,
                                color: Colors.white),
                            SizedBox(width: 4),
                            Text('PLAYING',
                                style: TextStyle(
                                    fontSize: 9,
                                    fontWeight:
                                        FontWeight.w700,
                                    letterSpacing: 0.6,
                                    color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle.copyWith(
                      fontSize: 12.5,
                      color: playing
                          ? waveAccent(context)
                          : null)),
              Text(a.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta
                      .copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    )
    );
  }
}



