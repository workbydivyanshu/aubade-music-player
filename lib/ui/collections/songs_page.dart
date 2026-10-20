import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/library/local_library_providers.dart';
import '../../features/library/local_track.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart' show ArtworkKind;
import '../components/buttons.dart'
    show WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Songs — every track of the local library in one dense table.
///
/// Reads [localLibraryNotifierProvider] (StateNotifier over the local
/// library) and maps each [LocalTrack] row into a playable
/// [GeneratedTrack] whose `playbackUrl` is the file path, so
/// PlaybackService's local fast path opens it directly.
class WaveSongsPage extends ConsumerStatefulWidget {
  const WaveSongsPage({super.key});

  @override
  ConsumerState<WaveSongsPage> createState() => _WaveSongsPageState();
}

class _WaveSongsPageState extends ConsumerState<WaveSongsPage> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<LocalTrack> _filtered(List<LocalTrack> tracks) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return tracks;
    return tracks
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.album.toLowerCase().contains(q))
        .toList();
  }

  /// Default (behind) order: title A→Z, matching the old pill default.
  /// Sorting is driven by the table's own header taps now — they re-sort a
  /// local index permutation ON TOP of the list passed in ([WaveDesktopTable]
  /// never mutates `items`), so this order stays what Play All / Shuffle and
  /// the playing-row highlight use.
  List<LocalTrack> _sorted(List<LocalTrack> tracks) {
    final list = List<LocalTrack>.of(tracks);
    list.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = ref
            .watch(localLibraryNotifierProvider)
            .value ??
        const <LocalTrack>[];
    final isScanning = ref.watch(isScanningProvider);

    if (tracks.isEmpty) {
      if (isScanning) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ProgressRing(),
              const SizedBox(height: 16),
              Text(
                'Scanning music library...',
                style: WaveType.sectionTitle.copyWith(color: waveTextPrimary(context)),
              ),
              const SizedBox(height: 6),
              Text(
                'Discovering tracks and artwork...',
                style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
            ],
          ),
        );
      }
      return _buildEmptyLibrary(context);
    }

    final visible = _sorted(_filtered(tracks));
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Songs · ${tracks.length} tracks',
                  style: WaveType.pageTitle.copyWith(fontSize: 24)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  WavePrimaryButton(
                    label: 'Play All',
                    icon: WaveIcons.play,
                    onPressed: visible.isEmpty
                        ? null
                        : () => playGenerated(
                            ref, context, _songToTrack(visible.first),
                            sourceLabel: 'Songs',
                            queueAll: _songList(visible)),
                  ),
                  WaveGhostButton(
                    label: 'Shuffle',
                    icon: WaveIcons.shuffle,
                    onPressed: visible.isEmpty
                        ? null
                        : () {
                            final shuffled =
                                List<LocalTrack>.of(visible)..shuffle();
                            playGenerated(ref, context,
                                _songToTrack(shuffled.first),
                                sourceLabel: 'Songs',
                                queueAll: _songList(shuffled));
                          },
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 250,
                    child: TextBox(
                      controller: _queryController,
                      placeholder: 'Filter title, artist, album',
                      onChanged: (v) => setState(() => _query = v),
                      prefix: const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(WaveIcons.search, size: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: WaveDesktopTable<LocalTrack>(
            items: visible,
            keyOf: (t) =>
                '${t.path.toLowerCase()}|${t.modifiedAt}',
            titleOf: (t) => t.title,
            subtitleOf: (t) => t.artist,
            albumOf: (t) => t.album,
            artworkOf: (t) => t.artworkPath != null
                ? 'file://${t.artworkPath}'
                : '',
            artworkKind: ArtworkKind.album,
            artworkTitleOf: (t) => t.album.isNotEmpty ? t.album : t.title,
            artworkArtistOf: (t) => t.artist,
            playableOf: (t) => t.toPlayableTrack(),
            durationOf: (t) =>
                t.duration > Duration.zero
                    ? formatDuration(t.duration)
                    : '',
            titleSortOf: (t) => t.title.toLowerCase(),
            artistSortOf: (t) => t.artist.toLowerCase(),
            albumSortOf: (t) => t.album.toLowerCase(),
            durationSortOf: (t) => t.duration.inMilliseconds,
            isCurrent: (t) => playingKey == _songToTrack(t).key,
            isPlaying: (t) {
              final playing = ref.watch(
                playbackServiceProvider.select((p) => p.isPlaying),
              );
              return playingKey == _songToTrack(t).key && playing;
            },
            playOnSingleTap: true,
            empty: _query.isEmpty
                ? const SizedBox.shrink()
                : WaveEmpty(
                    icon: WaveIcons.search,
                    title: 'No songs match',
                    subtitle: 'Nothing matches “$_query”.'),
            onPlay: (i) => playGenerated(
              ref,
              context,
              _songToTrack(visible[i]),
              sourceLabel: 'Songs',
              queueAll: _songList(visible),
              startIndex: i,
            ),
          ),
        ),
      ],
    );
  }

  /// First-run / empty-library hero: one calm card — glowing tile,
  /// title, promise line, two entry points (folder picker + default
  /// `~/Music`), and a quiet pointer at Settings for scrobbling/lyrics.
  Widget _buildEmptyLibrary(BuildContext context) {
    final accent = waveAccent(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(WaveSpacing.x28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.circular(WaveRadius.floating),
                gradient: RadialGradient(
                  colors: [
                    accent.withValues(alpha: WaveState.hoverAlpha),
                    Colors.transparent,
                  ],
                ),
                border: Border.all(color: waveDivider(context)),
              ),
              child: Center(
                child:
                    Icon(WaveIcons.library, size: 96, color: accent),
              ),
            ),
            const SizedBox(height: WaveSpacing.x16),
            Text(
              'Your Music Library is Empty',
              style: WaveType.pageTitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WaveSpacing.x4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                'Aubade plays your local FLAC, ALAC, WAV, and MP3 '
                'files with bit-perfect fidelity and ReplayGain.',
                style: WaveType.body.copyWith(
                  color: waveTextSecondary(context),
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: WaveSpacing.x12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                WavePrimaryButton(
                  label: 'Add Music Folder',
                  icon: WaveIcons.add,
                  onPressed: _addMusicFolder,
                ),
                const SizedBox(width: WaveSpacing.x4),
                WaveGhostButton(
                  label: 'Quick Scan ~/Music',
                  onPressed: _quickScanMusic,
                ),
              ],
            ),
            const SizedBox(height: WaveSpacing.x12),
            Text(
              'Scrobbling and synced lyrics can be configured in '
              'Settings → Last.fm.',
              style: WaveType.label.copyWith(
                color: waveTextTertiary(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the folder picker and adds the selection to the watched
  /// library folders, then nudges a scan when one isn't already running.
  Future<void> _addMusicFolder() async {
    try {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose music folder',
      );
      if (picked == null || picked.trim().isEmpty) return;
      if (!mounted) return;
      await ref.read(musicFoldersProvider.notifier).addFolder(picked);
      if (mounted) _nudgeScan();
    } catch (_) {}
  }

  /// Adds the platform default `~/Music` folder (when it exists) and
  /// scans; otherwise surfaces an inline hint via Fluent's InfoBar popup
  /// — a missing convention folder is never an error.
  Future<void> _quickScanMusic() async {
    final home = Platform.environment['HOME'];
    final music =
        home == null || home.trim().isEmpty ? null : '$home/Music';
    if (music == null || !Directory(music).existsSync()) {
      if (!mounted) return;
      unawaited(displayInfoBar(
        context,
        builder: (context, close) => InfoBar(
          title: const Text('No ~/Music folder found'),
          content: const Text(
              'Add a music folder to scan your local library.'),
          severity: InfoBarSeverity.info,
          onClose: close,
        ),
      ));
      return;
    }
    try {
      await ref.read(musicFoldersProvider.notifier).addFolder(music);
      if (mounted) _nudgeScan();
    } catch (_) {}
  }

  /// Kicks a library scan only while none is already running.
  void _nudgeScan() {
    if (ref.read(isScanningProvider)) return;
    ref.read(localLibraryNotifierProvider.notifier).scan();
  }
}

List<GeneratedTrack> _songList(List<LocalTrack> list) =>
    [for (final t in list) _songToTrack(t)];

/// Maps a local file row into the queue-item shape [playGenerated]
/// needs; `playbackUrl` stays the file path so PlaybackService's
/// local fast path opens it directly.
GeneratedTrack _songToTrack(LocalTrack t) => GeneratedTrack(
      name: t.title,
      artist: t.artist,
      album: t.album,
      artworkUrl: t.artworkPath != null ? 'file://${t.artworkPath}' : '',
      durationSeconds: t.duration.inSeconds,
      playbackUrl: t.path,
    );
