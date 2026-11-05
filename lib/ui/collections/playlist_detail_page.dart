import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../core/storage/prefs.dart' show prefsProvider, PlaylistSortDirection, PlaylistSortMode, PlaylistSortPreference;
import '../../features/downloads/download_manager.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart' show LWTooltip, WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/menus.dart';
import '../components/states.dart';
import 'playlist_dialogs.dart'
    show
        showWaveDeletePlaylist,
        showWaveRenamePlaylist;
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Playlist detail: artwork hero + filter + indexed track table.
///
/// Play/Shuffle are prioritized; Pin/Rename/Delete live in overflow.
/// Multi-select is supported via Shift+click range (checkbox column
/// appears when selection is active).
class WavePlaylistDetailPage extends ConsumerStatefulWidget {
  final int id;
  const WavePlaylistDetailPage({super.key, required this.id});

  @override
  ConsumerState<WavePlaylistDetailPage> createState() =>
      _WavePlaylistDetailPageState();
}

class _WavePlaylistDetailPageState
    extends ConsumerState<WavePlaylistDetailPage> {
  final _filter = TextEditingController();
  String _q = '';
  PlaylistSortPreference _sort = PlaylistSortPreference.defaults;

  @override
  void initState() {
    super.initState();
    // Restore this playlist's persisted selection before the first
    // frame so the dropdown label and row order never jump.
    _sort = ref
        .read(prefsProvider)
        .playlistSort(widget.id);
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _changeSort(PlaylistSortPreference next) {
    setState(() => _sort = next);
    unawaited(
      ref.read(prefsProvider).setPlaylistSort(widget.id, next),
    );
  }

  /// Header tap → next option: a new column starts ascending, tapping
  /// the active column flips its direction. Default order is reachable
  /// only from the dropdown, mirroring the keyboard/table contract.
  void _changePlaylistSortFromHeader(int col) {
    _changeSort(nextPlaylistSortOnHeader(_sort, col));
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final playlist =
        playlists.where((p) => p.id == widget.id).firstOrNull;
    if (playlist == null) {
      return WaveEmpty(
        icon: FluentIcons.list_mirrored,
        title: 'Playlist not found',
        subtitle: 'It may have been deleted.',
        actionLabel: 'Back to playlists',
        onAction: () => context.go('/playlists'),
      );
    }
    var tracks = playlist.tracks
        .where(
          (t) => '${t.name} ${t.artist}'
              .toLowerCase()
              .contains(_q.toLowerCase()),
        )
        .toList();
    applyPlaylistSort(
      tracks,
      _sort,
      titleOf: (t) => t.name,
      artistOf: (t) => t.artist,
    );
    // Note: Album/Duration sorts are intentionally omitted — local
    // playlist tracks carry no album or duration metadata.
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    List<GeneratedTrack> asGenerated() => tracks
        .map(
          (t) => GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
          ),
        )
        .toList();

    String cover = '';
    for (final t in playlist.tracks) {
      if (t.artworkUrl.isNotEmpty) {
        cover = t.artworkUrl;
        break;
      }
    }

    return WaveEntranceGroup(
      child: CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: WaveDensity.contentMax,
              ),
              child: WaveEntrance(
                rise: 10,
                child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  WaveCollectionHero(
                    overline:
                        'Playlist${playlist.isPinned ? ' · Pinned' : ''}',
                    title: playlist.title,
                    meta:
                        '${playlist.tracks.length} tracks${_q.isNotEmpty ? ' · ${tracks.length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon:
                        FluentIcons.list_mirrored,
                    primaryActions: [
                      if (tracks.isNotEmpty) ...[
                        WavePrimaryButton(
                          label: 'Play all',
                          icon: FluentIcons.play,
                          onPressed: () => playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel: playlist.title,
                            queueAll: asGenerated(),
                          ),
                        ),
                        WaveGhostButton(
                          label: 'Shuffle',
                          icon: WaveIcons.shuffle,
                          onPressed: () {
                            // Shuffle BEFORE picking first.
                            final shuffled =
                                asGenerated()..shuffle();
                            playGenerated(
                              ref,
                              context,
                              shuffled.first,
                              sourceLabel: playlist.title,
                              queueAll: shuffled,
                            );
                          },
                        ),
                        WaveGhostButton(
                          label: 'Download',
                          icon: FluentIcons.download,
                          onPressed: () {
                            final manager = ref.read(
                                downloadManagerProvider
                                    .notifier);
                            for (final t
                                in asGenerated()) {
                              manager.downloadTrack(
                                title: t.name,
                                artist: t.artist,
                                artworkUrl: t.artworkUrl,
                              );
                            }
                          },
                        ),
                      ],
                    ],
                    overflowItems: [
                      WaveMenuAction(
                        leading: const Icon(
                          FluentIcons.pin,
                          size: 13,
                        ),
                        label: playlist.isPinned
                            ? 'Unpin'
                            : 'Pin',
                        onPressed: () => ref
                            .read(
                              playlistRepositoryProvider
                                  .notifier,
                            )
                            .setPinned(
                              playlist.id,
                              !playlist.isPinned,
                            ),
                      ),
                      WaveMenuAction(
                        leading: const Icon(
                          FluentIcons.edit,
                          size: 13,
                        ),
                        label: 'Rename',
                        onPressed: () =>
                            showWaveRenamePlaylist(
                          context,
                          ref,
                          playlist,
                        ),
                      ),
                      if (!playlist.isLikedSongs)
                        WaveMenuAction(
                          leading: const Icon(
                            FluentIcons.delete,
                            size: 13,
                          ),
                          label: 'Delete',
                          onPressed: () =>
                              showWaveDeletePlaylist(
                            context,
                            ref,
                            playlist,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  WaveFilterBar(
                    controller: _filter,
                    onChanged: (v) =>
                        setState(() => _q = v),
                    hint: 'Filter in playlist…',
                    countLabel:
                        '${tracks.length} tracks',
                    sortSlot: LWTooltip(
                      message: 'Sort (also sortable via table headers)',
                      child: DropDownButton(
                        transitionBuilder: fastFlyoutTransition,
                        title: Text(playlistSortOptionLabel(_sort)),
                        items: [
                          for (final option in playlistSortOptions)
                            MenuFlyoutItem(
                              text: Text(playlistSortOptionLabel(option)),
                              trailing:
                                  option == _sort
                                      ? const Icon(
                                          FluentIcons.check_mark,
                                          size: 14,
                                        )
                                      : null,
                              onPressed: () => _changeSort(option),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                ),
              ),
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: FluentIcons.list_mirrored,
              title: 'Empty playlist',
              subtitle: 'Add tracks from any menu.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: WaveDesktopTable<GeneratedTrack>(
              items: asGenerated(),
              keyOf: (t) => t.key,
              titleOf: (t) => t.name,
              subtitleOf: (t) => t.artist,
              albumOf: (_) => '',
              artworkOf: (t) => t.artworkUrl,
              playableOf: playableFromGenerated,
              durationOf: (t) => t.durationSeconds > 0
                  ? formatDuration(
                      Duration(seconds: t.durationSeconds))
                  : '',
              durationSortOf: (t) => t.durationSeconds,
              titleSortOf: (t) => t.name.toLowerCase(),
              artistSortOf: (t) => t.artist.toLowerCase(),
              onHeaderSort: _changePlaylistSortFromHeader,
              controlledSortCol: _playlistSortCol(_sort),
              controlledSortDir: _sort.direction == PlaylistSortDirection.desc
                  ? WaveSortDir.desc
                  : WaveSortDir.asc,
              isCurrent: (t) => playingKey == t.key,
              isPlaying: (t) {
                final playing = ref.watch(
                  playbackServiceProvider.select((p) => p.isPlaying),
                );
                return playingKey == t.key && playing;
              },
              showArtistColumn: true,
              sliver: true,
              selectable: true,
              removeLabel: 'Remove from playlist',
              onRemove: (i) => ref
                  .read(playlistRepositoryProvider.notifier)
                  .removeTrack(
                      playlist.id, asGenerated()[i].key),
              onPlay: (i) => playGenerated(
                ref,
                context,
                asGenerated()[i],
                sourceLabel: playlist.title,
                queueAll: asGenerated(),
                startIndex: i,
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
        ],
      ),
    );
  }
}

/// The six persisted sort options shown in the playlist filter bar.
/// Default order covers both source order (asc) and its exact reversal.
const List<PlaylistSortPreference> playlistSortOptions = [
  PlaylistSortPreference(),
  PlaylistSortPreference(direction: PlaylistSortDirection.desc),
  PlaylistSortPreference(mode: PlaylistSortMode.title),
  PlaylistSortPreference(
    mode: PlaylistSortMode.title,
    direction: PlaylistSortDirection.desc,
  ),
  PlaylistSortPreference(mode: PlaylistSortMode.artist),
  PlaylistSortPreference(
    mode: PlaylistSortMode.artist,
    direction: PlaylistSortDirection.desc,
  ),
];

/// Dropdown / menu label for one sort selection.
String playlistSortOptionLabel(PlaylistSortPreference p) =>
    switch ((p.mode, p.direction)) {
      (PlaylistSortMode.defaultOrder, PlaylistSortDirection.asc) =>
        'Default order',
      (PlaylistSortMode.defaultOrder, PlaylistSortDirection.desc) =>
        'Reverse default order',
      (PlaylistSortMode.title, PlaylistSortDirection.asc) => 'Title A–Z',
      (PlaylistSortMode.title, PlaylistSortDirection.desc) => 'Title Z–A',
      (PlaylistSortMode.artist, PlaylistSortDirection.asc) => 'Artist A–Z',
      (PlaylistSortMode.artist, PlaylistSortDirection.desc) => 'Artist Z–A',
    };

/// Maps a sort preference onto the table header columns: only Title
/// (0) and Artist (1) exist; Default order shows no indicator (-1).
int _playlistSortCol(PlaylistSortPreference p) => switch (p.mode) {
      PlaylistSortMode.title => 0,
      PlaylistSortMode.artist => 1,
      PlaylistSortMode.defaultOrder => -1,
    };

/// Header tap → next selection: a different column starts ascending,
/// the active column flips its direction. Calls for non-sortable
/// columns keep the current selection.
PlaylistSortPreference nextPlaylistSortOnHeader(
  PlaylistSortPreference current,
  int col,
) {
  final mode = switch (col) {
    0 => PlaylistSortMode.title,
    1 => PlaylistSortMode.artist,
    _ => current.mode,
  };
  if (mode == current.mode && current.mode != PlaylistSortMode.defaultOrder) {
    return PlaylistSortPreference(
      mode: mode,
      direction: current.direction == PlaylistSortDirection.asc
          ? PlaylistSortDirection.desc
          : PlaylistSortDirection.asc,
    );
  }
  return PlaylistSortPreference(mode: mode);
}

/// Applies a persisted sort selection in place on the filtered track
/// list. Default order keeps source order (asc) or reverses it (desc);
/// title/artist compare case-insensitively with direction applied and
/// ties always falling back to source order in both directions (Dart's
/// sort is not stable, so the tie-break is explicit).
void applyPlaylistSort<T>(
  List<T> items,
  PlaylistSortPreference pref, {
  required String Function(T) titleOf,
  required String Function(T) artistOf,
}) {
  final n = items.length;
  if (n < 2) return;
  final src = List<T>.of(items);
  final descending = pref.direction == PlaylistSortDirection.desc;
  switch (pref.mode) {
    case PlaylistSortMode.defaultOrder:
      if (!descending) return;
      for (var i = 0; i < n; i++) {
        items[i] = src[n - 1 - i];
      }
    case PlaylistSortMode.title || PlaylistSortMode.artist:
      final keyOf =
          pref.mode == PlaylistSortMode.title ? titleOf : artistOf;
      final indices = List<int>.generate(n, (i) => i);
      indices.sort((a, b) {
        var c = keyOf(src[a])
            .toLowerCase()
            .compareTo(keyOf(src[b]).toLowerCase());
        if (c != 0) c = descending ? -c : c;
        if (c != 0) return c;
        return a.compareTo(b);
      });
      for (var i = 0; i < n; i++) {
        items[i] = src[indices[i]];
      }
  }
}



