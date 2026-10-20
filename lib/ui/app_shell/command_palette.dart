import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show formatDuration, playGenerated;
import '../../core/storage/prefs.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/library/local_library_providers.dart';
import '../../features/library/local_track.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../search/search_page.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Apple-Spotlight-style unified search surface (Ctrl+K).
///
/// Canonical entry point: [showWaveSpotlight]. One frosted-acrylic sheet
/// replaces the old WinUI command palette: local-library results resolve
/// instantly (synchronous SQLite projections), the online catalog fills
/// in behind them (shared debounced providers), navigation commands stay
/// keyboard-first, and the empty query shows recent-search chips + the
/// command launcher.
///
/// Shell placement + hotkeys (Ctrl+K open, Esc close) are owned by
/// app_shell.dart via wave_hotkeys; this file owns the Spotlight itself.
/// Recent-search persistence lives in `prefsProvider.recentSearches`
/// (newest-first, max 8, caller dedupes — see `_touchRecentSearch`).
Future<void> showWaveSpotlight(
  BuildContext context, {
  required List<String> recentSearches,
  required ValueChanged<String> onSearch,
  required ValueChanged<String> onGo,
}) {
  final routes = <(String path, String label, IconData icon)>[
    (('/home'), 'Go to Home', FluentIcons.home),
    (('/search'), 'Go to Search', FluentIcons.search),
    (('/liked'), 'Go to Liked Songs', FluentIcons.heart),
    (('/albums'), 'Go to Albums', FluentIcons.music_note),
    (('/artists'), 'Go to Artists', FluentIcons.contact),
    (('/playlists'), 'Go to Playlists', FluentIcons.list_mirrored),
    (('/mixes'), 'Open Mix Lab', FluentIcons.lightbulb),
    (('/downloads'), 'Go to Downloads', FluentIcons.download),
    (('/history'), 'Go to History', FluentIcons.history),
    (('/now'), 'Open Now Playing', FluentIcons.circle_fill),
    (('/lyrics'), 'Open Lyrics', FluentIcons.microphone),
    (('/settings'), 'Open Settings', FluentIcons.settings),
  ];
  return showDialog(
    context: context,
    barrierDismissible: true,
    // macOS-Ventura-style dim: the scrim darkens the app while the
    // sheet's BackdropFilter samples the blurred content behind it.
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (context) => _SpotlightDialog(
      routes: routes,
      passedRecents: recentSearches,
      onSearch: onSearch,
      onGo: onGo,
    ),
  );
}

/// Superseded alias — kept so existing callers (app_shell.dart:463 and
/// any keyboard hotkeys) keep compiling unchanged; it simply forwards to
/// [showWaveSpotlight], which owns the Spotlight modal now.
Future<void> showWaveCommandPalette(
  BuildContext context, {
  required List<String> recentSearches,
  required ValueChanged<String> onSearch,
  required ValueChanged<String> onGo,
}) =>
    showWaveSpotlight(
      context,
      recentSearches: recentSearches,
      onSearch: onSearch,
      onGo: onGo,
    );

/// Spotlight result filter tabs.
enum _SpotTab {
  all('All'),
  tracks('Tracks'),
  artists('Artists'),
  albums('Albums'),
  commands('Commands');

  final String label;
  const _SpotTab(this.label);
}

/// One unified Spotlight row: a local-library hit, an online catalog
/// hit, or a command/navigation entry. [group] drives the section
/// headers; [meta] is the honest trailing info (format + duration for
/// tracks; artists/albums stay name-only).
class _SpotItem {
  final String group;
  final String label;
  final String sub;
  final String meta;
  final IconData icon;
  final String art;

  /// Artwork fallback initials source (the entity's own label).
  final String artLabel;
  final bool circleArt;
  final VoidCallback action;
  final bool isHero;
  const _SpotItem({
    required this.group,
    required this.label,
    required this.sub,
    required this.icon,
    required this.action,
    this.meta = '',
    this.art = '',
    this.artLabel = '',
    this.circleArt = false,
    this.isHero = false,
  });
}

// Canonical sheet constants: liquid obsidian acrylic over a black scrim.
const _sheetColor = Color(0xF2121216);
const _rimTopColor = Color(0x33FFFFFF);
const _rimSideColor = Color(0x14FFFFFF);

/// Per-side 1px rim: bright top chamfer, whisper sides/bottom.
Border _spotlightRim() => const Border(
      top: BorderSide(color: _rimTopColor),
      left: BorderSide(color: _rimSideColor),
      right: BorderSide(color: _rimSideColor),
      bottom: BorderSide(color: _rimSideColor),
    );

class _SpotlightDialog extends ConsumerStatefulWidget {
  final List<(String, String, IconData)> routes;
  final List<String> passedRecents;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onGo;
  const _SpotlightDialog({
    required this.routes,
    required this.passedRecents,
    required this.onSearch,
    required this.onGo,
  });

  @override
  ConsumerState<_SpotlightDialog> createState() => _SpotlightDialogState();
}

class _SpotlightDialogState extends ConsumerState<_SpotlightDialog> {
  final ScrollController _list = ScrollController();
  final GlobalKey _selKey = GlobalKey();
  late final TextEditingController controller;

  _SpotTab _tab = _SpotTab.all;
  String _q = '';
  String _liveQ = '';
  Timer? _debounce;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController();
  }

  @override
  void dispose() {
    controller.dispose();
    _debounce?.cancel();
    _list.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {
      _q = v;
      // Selection persists across query edits; clamped when the list
      // shrinks (never resets to 0 while typing).
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _liveQ = v.trim());
    });
  }

  void _activate(List<_SpotItem> rows) {
    if (rows.isEmpty) {
      final q = _q.trim();
      if (q.isEmpty) return;
      // Enter with nothing selected: the only meaningful action is the
      // full-catalog search.
      _runOnlineSearch(q);
      return;
    }
    final i = _selected.clamp(0, rows.length - 1);
    _run(rows[i]);
  }

  void _run(_SpotItem item) {
    Navigator.of(context).pop();
    if (_q.trim().isNotEmpty) _touchRecentSearch(_q.trim());
    item.action();
  }

  void _runOnlineSearch(String q) {
    Navigator.of(context).pop();
    _touchRecentSearch(q);
    widget.onSearch(q);
  }

  /// Records a Spotlight query: dedupe case-insensitively, keep the
  /// query newest-first, and let prefs cap the list at 8.
  void _touchRecentSearch(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    final prefs = ref.read(prefsProvider);
    final next = <String>[
      q,
      ...prefs.recentSearches
          .where((s) => s.toLowerCase() != q.toLowerCase()),
    ].take(8).toList();
    prefs.saveRecentSearches(next);
  }

  void _moveSelection(List<_SpotItem> rows, int delta) {
    if (rows.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, rows.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.hasClients) return;
      final c = _selKey.currentContext;
      if (c != null) {
        Scrollable.ensureVisible(c, duration: WaveMotion.fast);
      }
    });
  }

  KeyEventResult _onKey(KeyEvent event, List<_SpotItem> rows) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Ctrl/Cmd+K inside the modal is swallowed: no re-open loop, no
    // pass-through to the shell hotkey.
    if (event.logicalKey == LogicalKeyboardKey.keyK &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      final tabs = _SpotTab.values;
      final curIdx = tabs.indexOf(_tab);
      final nextIdx = isShift
          ? (curIdx - 1 + tabs.length) % tabs.length
          : (curIdx + 1) % tabs.length;
      setState(() {
        _tab = tabs[nextIdx];
        _selected = 0;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSelection(rows, 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSelection(rows, -1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -- actions ------------------------------------------------------------

  void _playSong(SearchResultItem s) {
    // Single track through the shared helper: autoplay-similar pref
    // applies, so radio follows (a raw single-track playQueue would
    // just stop).
    playGenerated(
      ref,
      context,
      GeneratedTrack(
        name: s.name,
        artist: s.artist,
        album: s.subtitle,
        artworkUrl: s.artworkUrl,
        videoId: s.videoId,
        playbackUrl: s.videoId,
      ),
      sourceLabel: 'Spotlight',
    );
  }

  /// Local file track: playbackUrl is the absolute path, which keeps
  /// PlaybackService on the local fast path (no YouTube resolution).
  void _playLocal(LocalTrack t) {
    playGenerated(
      ref,
      context,
      GeneratedTrack(
        name: t.title,
        artist: t.artist,
        album: t.album,
        artworkUrl:
            t.artworkPath != null ? 'file://${t.artworkPath}' : '',
        videoId: '',
        playbackUrl: t.path,
        durationSeconds: t.duration.inSeconds,
      ),
      sourceLabel: 'Spotlight',
    );
  }

  void _openResult(SearchResultItem top) {
    switch (top.tab) {
      case SearchTab.tracks:
        _playSong(top);
      case SearchTab.artists:
        widget.onGo('/artist/${Uri.encodeComponent(top.name)}');
      case SearchTab.albums:
        if (top.entityId.isNotEmpty) {
          widget
              .onGo('/album/${Uri.encodeComponent(top.entityId)}');
        }
      case SearchTab.playlists:
        widget.onSearch(top.name);
      case SearchTab.users:
        widget.onSearch(top.name);
    }
  }

  /// Honest trailing meta: `FLAC 24/96 · 4:07`, `MP3 · 2:07`. kHz keeps
  /// one decimal only when the value is fractional (44100 → 44.1, 96000
  /// → 96). Depth+rate collapse to `24/96`; rate-only drops the depth;
  /// neither collapses to format-only.
  String _trackMeta(LocalTrack t) {
    final fmt = t.format.trim().toUpperCase();
    final rate = t.sampleRate ?? 0;
    final depth = t.bitDepth ?? 0;
    final khz = rate > 0 ? _khzString(rate) : '';
    final quality = depth > 0 && khz.isNotEmpty
        ? '$depth/$khz'
        : khz;
    final format =
        [if (fmt.isNotEmpty) fmt, if (quality.isNotEmpty) quality].join(' ');
    final dur = formatDuration(t.duration);
    return format.isEmpty ? dur : '$format · $dur';
  }

  /// sampleRate → kHz label keeping one decimal only when fractional.
  String _khzString(int rate) {
    final v = rate / 1000.0;
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim();
    final ql = q.toLowerCase();

    // Local library — synchronous SQLite projections (typing-instant).
    final localTracks = q.isEmpty
        ? const <LocalTrack>[]
        : ref
            .watch(localSearchTracksProvider(q))
            .take(6)
            .toList();
    final localAlbums = q.isEmpty
        ? <Map<String, dynamic>>[]
        : ref.watch(localSearchAlbumsProvider(q)).take(3).toList();
    final localArtists = q.isEmpty
        ? <Map<String, dynamic>>[]
        : ref.watch(localSearchArtistsProvider(q)).take(3).toList();

    // Online catalog — debounced shared providers (unchanged capability).
    final gSongs = _liveQ.isEmpty
        ? const <SearchResultItem>[]
        : ref.watch(waveSearchSongsProvider(_liveQ)).valueOrNull ??
            const <SearchResultItem>[];
    final gAlbums = _liveQ.isEmpty
        ? const <SearchResultItem>[]
        : ref.watch(waveSearchAlbumsProvider(_liveQ)).valueOrNull ??
            const <SearchResultItem>[];
    final gArtists = _liveQ.isEmpty
        ? const <SearchResultItem>[]
        : ref.watch(waveSearchArtistsProvider(_liveQ)).valueOrNull ??
            const <SearchResultItem>[];
    final onlineLoading = _liveQ.isNotEmpty &&
        (ref.watch(waveSearchSongsProvider(_liveQ)).isLoading ||
            ref.watch(waveSearchAlbumsProvider(_liveQ)).isLoading ||
            ref.watch(waveSearchArtistsProvider(_liveQ)).isLoading);

    // -- Top Result (Local first if matching, else online) ------------------
    _SpotItem? topItem;
    if (q.isNotEmpty) {
      if (localTracks.isNotEmpty) {
        final top = localTracks.first;
        topItem = _SpotItem(
          group: 'Top Result',
          label: top.title,
          sub: top.artist.isNotEmpty
              ? (top.album.isNotEmpty ? '${top.artist} · ${top.album}' : top.artist)
              : 'Local file',
          meta: _trackMeta(top),
          icon: WaveIcons.music,
          art: top.artworkPath != null ? 'file://${top.artworkPath}' : '',
          artLabel: top.title,
          action: () => _playLocal(top),
          isHero: true,
        );
      } else if (_liveQ.isNotEmpty &&
          (gSongs.isNotEmpty || gArtists.isNotEmpty || gAlbums.isNotEmpty)) {
        final top = gSongs.isNotEmpty
            ? gSongs.first
            : (gArtists.isNotEmpty ? gArtists.first : gAlbums.first);
        topItem = _SpotItem(
          group: 'Top Result',
          label: top.name,
          sub: top.artist.isNotEmpty
              ? (top.subtitle.isNotEmpty ? '${top.artist} · ${top.subtitle}' : top.artist)
              : searchTabLabel(top.tab),
          meta: searchTabLabel(top.tab),
          icon: FluentIcons.trophy,
          art: top.artworkUrl,
          circleArt: top.tab == SearchTab.artists,
          artLabel: top.name,
          action: () => _openResult(top),
          isHero: true,
        );
      }
    }

    // -- Songs (local first, then online) ----------------------------------
    final remainingLocal = (topItem != null && localTracks.isNotEmpty)
        ? localTracks.skip(1)
        : localTracks;
    final songItems = <_SpotItem>[
      for (final t in remainingLocal)
        _SpotItem(
          group: 'Songs',
          label: t.title,
          sub: t.artist.isNotEmpty ? t.artist : 'Local file',
          meta: _trackMeta(t),
          icon: WaveIcons.music,
          art: t.artworkPath != null ? 'file://${t.artworkPath}' : '',
          artLabel: t.title,
          action: () => _playLocal(t),
        ),
      for (final s in gSongs.take(3))
        _SpotItem(
          group: 'Songs',
          label: s.name,
          sub: s.artist.isNotEmpty ? s.artist : 'Song',
          icon: WaveIcons.music,
          art: s.artworkUrl,
          artLabel: s.name,
          action: () => _playSong(s),
        ),
    ];

    // -- Albums -------------------------------------------------------------
    final albumItems = <_SpotItem>[
      // browseId carries the local album name; the detail page resolves
      // it against the local library (same idiom as the Albums page).
      for (final a in localAlbums)
        _SpotItem(
          group: 'Albums',
          label: (a['album'] as String?) ?? '',
          sub: _albumSub(a),
          icon: WaveIcons.albums,
          art: (a['artwork_path'] as String?) != null &&
                  (a['artwork_path'] as String).isNotEmpty
              ? 'file://${a['artwork_path']}'
              : '',
          artLabel: (a['album'] as String?) ?? '',
          action: () => widget.onGo(
              '/album/${Uri.encodeComponent((a['album'] as String?) ?? '')}'),
        ),
      for (final a in gAlbums.take(2))
        _SpotItem(
          group: 'Albums',
          label: a.name,
          sub: a.artist.isNotEmpty ? a.artist : 'Album',
          icon: WaveIcons.albums,
          art: a.artworkUrl,
          artLabel: a.name,
          action: () {
            if (a.entityId.isNotEmpty) {
              widget.onGo(
                  '/album/${Uri.encodeComponent(a.entityId)}');
            }
          },
        ),
    ];

    // -- Artists ------------------------------------------------------------
    final artistItems = <_SpotItem>[
      // /artist/:name has a local fast path (artist_detail_page).
      for (final a in localArtists)
        _SpotItem(
          group: 'Artists',
          label: (a['artist'] as String?) ?? '',
          sub: '${a['track_count']} tracks',
          icon: WaveIcons.artists,
          art: (a['artwork_path'] as String?) != null &&
                  (a['artwork_path'] as String).isNotEmpty
              ? 'file://${a['artwork_path']}'
              : '',
          artLabel: (a['artist'] as String?) ?? '',
          circleArt: true,
          action: () => widget.onGo(
              '/artist/${Uri.encodeComponent((a['artist'] as String?) ?? '')}'),
        ),
      for (final a in gArtists.take(2))
        _SpotItem(
          group: 'Artists',
          label: a.name,
          sub: 'Artist',
          icon: WaveIcons.artists,
          art: a.artworkUrl,
          artLabel: a.name,
          circleArt: true,
          action: () => widget
              .onGo('/artist/${Uri.encodeComponent(a.name)}'),
        ),
    ];

    // -- Commands / navigation ------------------------------------------------
    final navItems = <_SpotItem>[
      for (final r in widget.routes)
        if (ql.isEmpty || r.$2.toLowerCase().contains(ql))
          _SpotItem(
            group: 'Commands',
            label: r.$2,
            sub: 'Navigate',
            meta: '↵',
            icon: r.$3,
            action: () => widget.onGo(r.$1),
          ),
    ];

    // -- Full-catalog search entry -------------------------------------------
    // In-list row when local rows exist (keeps the old palette's
    // dedicated row); when there are none, the pinned ghost footer is
    // the single online escape hatch — never both at once.
    final hasLocalRows = localTracks.isNotEmpty ||
        localAlbums.isNotEmpty ||
        localArtists.isNotEmpty;
    _SpotItem? searchItem;
    if (q.isNotEmpty && hasLocalRows) {
      searchItem = _SpotItem(
        group: 'Search',
        label: 'Search for “$q”',
        sub: 'Full catalog search',
        icon: WaveIcons.search,
        action: () => widget.onSearch(q),
      );
    }
    final onlineRowsEmpty =
        songItems.isEmpty && albumItems.isEmpty && artistItems.isEmpty;
    final showOnlineFooter =
        q.isNotEmpty && !hasLocalRows && onlineRowsEmpty && !onlineLoading;

    // -- Tab filtering --------------------------------------------------------
    final rows = switch (_tab) {
      _SpotTab.all => <_SpotItem>[
          ?topItem,
          ...songItems,
          ...albumItems,
          ...artistItems,
          ?searchItem,
          ...navItems,
        ],
      _SpotTab.tracks => <_SpotItem>[
          if (topItem != null && (localTracks.isNotEmpty || gSongs.isNotEmpty))
            topItem,
          ...songItems,
        ],
      _SpotTab.artists => artistItems,
      _SpotTab.albums => albumItems,
      _SpotTab.commands => navItems,
    };
    final sel = rows.isEmpty
        ? -1
        : _selected.clamp(0, rows.length - 1);

    // Group consecutive entries under mini-section headers. Rows are
    // built lazily (ListView.builder below) so open only pays for
    // visible items; rows carry NO tooltips (a tooltip spins up an
    // overlay portal per row — pure open-frame cost for labels that are
    // already visible).
    final items = <Widget>[];
    if (_tab == _SpotTab.all && q.isEmpty) {
      // Empty query: recent-search chips (newest first) + the command
      // launcher below, so Ctrl+K opens as a launcher.
      final chips = _recents();
      if (chips.isNotEmpty) {
        items.add(_RecentsChips(
          chips: chips,
          controller: controller,
          onChanged: _onChanged,
          onRun: _runOnlineSearch,
        ));
      }
    }
    String? lastGroup;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.group != lastGroup) {
        lastGroup = r.group;
        if (!r.isHero) {
          items.add(_SpotHeader(title: r.group));
        }
      }
      Widget row = r.isHero
          ? _SpotHeroCard(
              item: r,
              selected: i == sel,
              onTap: () => _run(r),
            )
          : _SpotRow(
              item: r,
              selected: i == sel,
              onTap: () => _run(r),
            );
      if (i == sel) row = KeyedSubtree(key: _selKey, child: row);
      items.add(row);
    }
    if (rows.isEmpty && onlineLoading) {
      items.add(const _SearchingRow());
    } else if (rows.isEmpty && !showOnlineFooter) {
      final hint = switch (_tab) {
        _SpotTab.tracks => 'Type to search tracks in your library…',
        _SpotTab.artists => 'Type to search artists in your library…',
        _SpotTab.albums => 'Type to search albums in your library…',
        _ => 'No commands match.',
      };
      items.add(_SpotHint(
        message: q.isEmpty ? 'Type to search your library and the catalog…' : hint,
      ));
    }

    // -- Sheet ----------------------------------------------------------------
    final vw = MediaQuery.sizeOf(context).width;
    final vh = MediaQuery.sizeOf(context).height;

    return Focus(
      onKeyEvent: (_, e) => _onKey(e, rows),
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: vh * 0.12),
          child: SizedBox(
            width: math.min(680.0, vw - 48.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius:
                    const BorderRadius.all(Radius.circular(18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.60),
                    blurRadius: 42,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.all(Radius.circular(18)),
                // Acrylic: blur the dimmed app behind the obsidian sheet.
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _sheetColor,
                      border: _spotlightRim(),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildQueryRow(rows),
                        _buildTabs(),
                        Container(
                          height: 1,
                          color: _rimTopColor,
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight:
                                math.max(120.0, vh * 0.70 - 150),
                          ),
                          child: items.isEmpty
                              ? const SizedBox(width: 4)
                              : ListView.builder(
                                  controller: _list,
                                  shrinkWrap: true,
                                  physics:
                                      const ClampingScrollPhysics(),
                                  padding: const EdgeInsets.only(
                                      top: 4, bottom: 6),
                                  itemCount: items.length,
                                  itemBuilder: (context, i) =>
                                      items[i],
                                ),
                        ),
                        if (showOnlineFooter) _buildFooter(q),
                        _buildActionFooter(rows, sel, q),
                      ],
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

  String _albumSub(Map<String, dynamic> a) {
    final artist = (a['album_artist'] as String?) ?? '';
    final count = (a['track_count'] as int?) ?? 0;
    final n = count == 1 ? '1 track' : '$count tracks';
    return artist.isNotEmpty ? '$artist · $n' : n;
  }

  /// Empty-query chips: prefs-owned recents (newest first), merged with
  /// the caller-supplied history for callers that seed it.
  List<String> _recents() {
    final stored = ref.watch(prefsProvider).recentSearches;
    final passed = widget.passedRecents;
    return <String>[
      ...stored.take(5),
      ...passed.where((p) =>
          p.trim().isNotEmpty &&
          !stored
              .any((s) => s.toLowerCase() == p.trim().toLowerCase())),
    ].take(5).toList();
  }

  Widget _buildQueryRow(List<_SpotItem> rows) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 18),
          Icon(
            WaveIcons.search,
            size: 16,
            color: WaveColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextBox(
              controller: controller,
              autofocus: true,
              padding: const EdgeInsets.symmetric(vertical: 14),
              // Borderless: the acrylic sheet is the chrome. The
              // decoration override kills the default stroke+fill AND
              // the foregroundDecoration kills the WinUI focus
              // underline, so the sheet stays the only chrome.
              decoration: const WidgetStatePropertyAll(
                BoxDecoration(
                  color: Colors.transparent,
                  border: Border.fromBorderSide(BorderSide.none),
                ),
              ),
              foregroundDecoration:
                  const WidgetStatePropertyAll(BoxDecoration()),
              placeholder: 'Search or run a command…',
              placeholderStyle: WaveType.body.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: WaveColors.textTertiary,
              ),
              style: WaveType.body.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: WaveColors.textPrimary,
              ),
              cursorColor: WaveColors.defaultAccent,
              onChanged: _onChanged,
              onSubmitted: (_) => _activate(rows),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Row(
        children: [
          for (final t in _SpotTab.values) ...[
            if (t != _SpotTab.all) const SizedBox(width: 6),
            _TabChip(
              tab: t,
              selected: _tab == t,
              onTap: () => setState(() => _tab = t),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooter(String q) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: _rimSideColor),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _runOnlineSearch(q),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(
                  WaveIcons.search,
                  size: 14,
                  color:
                      WaveColors.defaultAccent.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Search online catalog for “$q”',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      fontSize: 12.5,
                      color: WaveColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionFooter(List<_SpotItem> rows, int sel, String q) {
    _SpotItem? selectedItem;
    if (sel >= 0 && sel < rows.length) {
      selectedItem = rows[sel];
    }

    String actionLabel = 'Select';
    if (selectedItem != null) {
      if (selectedItem.isHero || selectedItem.group == 'Songs') {
        actionLabel = 'Play track';
      } else if (selectedItem.group == 'Artists') {
        actionLabel = 'View artist';
      } else if (selectedItem.group == 'Albums') {
        actionLabel = 'View album';
      } else if (selectedItem.group == 'Commands') {
        actionLabel = 'Run command';
      } else if (selectedItem.group == 'Search') {
        actionLabel = 'Search catalog';
      }
    } else if (q.isNotEmpty) {
      actionLabel = 'Search online';
    }

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0x660E0E12),
        border: Border(
          top: BorderSide(color: Color(0x18FFFFFF)),
        ),
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _ShortcutBadge(label: '↵'),
              const SizedBox(width: 6),
              Text(
                actionLabel,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: WaveColors.textSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              _ShortcutBadge(label: 'Tab'),
              SizedBox(width: 4),
              Text(
                'Scope',
                style: TextStyle(
                  fontSize: 11,
                  color: WaveColors.textTertiary,
                ),
              ),
              SizedBox(width: 10),
              _ShortcutBadge(label: '↑↓'),
              SizedBox(width: 4),
              Text(
                'Navigate',
                style: TextStyle(
                  fontSize: 11,
                  color: WaveColors.textTertiary,
                ),
              ),
              SizedBox(width: 10),
              _ShortcutBadge(label: 'Esc'),
              SizedBox(width: 4),
              Text(
                'Close',
                style: TextStyle(
                  fontSize: 11,
                  color: WaveColors.textTertiary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Recent-search chip row for the empty-query state (max 1–2 lines):
/// tapping a chip sets the query and immediately lands in /search.
class _RecentsChips extends StatefulWidget {
  final List<String> chips;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onRun;
  const _RecentsChips({
    required this.chips,
    required this.controller,
    required this.onChanged,
    required this.onRun,
  });

  @override
  State<_RecentsChips> createState() => _RecentsChipsState();
}

class _RecentsChipsState extends State<_RecentsChips> {
  int _hovered = -1;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < widget.chips.length; i++)
            _buildChip(i),
        ],
      ),
    );
  }

  Widget _buildChip(int i) {
    final chip = widget.chips[i];
    return GestureDetector(
      onTap: () {
        // Set the query and immediately search: text lands in the
        // field, then pop + recents write + route — the same path as an
        // Enter landing.
        widget.controller.text = chip;
        widget.onChanged(chip);
        widget.onRun(chip);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = i),
        onExit: (_) => setState(() => _hovered = -1),
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white
                .withValues(alpha: _hovered == i ? 0.11 : 0.07),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                WaveIcons.history,
                size: 12,
                color: WaveColors.textTertiary,
              ),
              const SizedBox(width: 5),
              Text(
                chip,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: WaveColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Searching state row (kept from the old palette).
class _SearchingRow extends StatelessWidget {
  const _SearchingRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: ProgressRing(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            'Searching…',
            style: TextStyle(
              fontSize: 12,
              color: WaveColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hint row when a filtered tab has nothing to show yet.
class _SpotHint extends StatelessWidget {
  final String message;
  const _SpotHint({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12.5,
          color: WaveColors.textTertiary,
        ),
      ),
    );
  }
}

/// Raycast-style keyboard shortcut pill badge.
class _ShortcutBadge extends StatelessWidget {
  final String label;
  const _ShortcutBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: WaveColors.textSecondary,
        ),
      ),
    );
  }
}

/// Elevated Hero Card for the Top Result (Raycast / Apple Music caliber).
class _SpotHeroCard extends StatefulWidget {
  final _SpotItem item;
  final bool selected;
  final VoidCallback onTap;
  const _SpotHeroCard({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SpotHeroCard> createState() => _SpotHeroCardState();
}

class _SpotHeroCardState extends State<_SpotHeroCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.item;
    final isSelected = widget.selected;
    final isHovered = _hover;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.12)
                : isHovered
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? WaveColors.defaultAccent.withValues(alpha: 0.40)
                  : Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: r.art.isNotEmpty
                      ? (r.circleArt
                          ? WaveArtwork.circle(
                              url: r.art, size: 56, label: r.artLabel)
                          : WaveArtwork(
                              url: r.art,
                              size: 56,
                              radius: 10,
                              label: r.artLabel,
                            ))
                      : Container(
                          color: Colors.white.withValues(alpha: 0.08),
                          child: Icon(r.icon,
                              size: 24, color: WaveColors.textSecondary),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: WaveColors.defaultAccent
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'TOP RESULT',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: WaveColors.defaultAccent,
                            ),
                          ),
                        ),
                        if (r.meta.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            r.meta,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: WaveColors.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      r.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: WaveColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      r.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        fontSize: 12,
                        color: WaveColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? WaveColors.defaultAccent
                      : Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.play,
                      size: 11,
                      color: isSelected
                          ? Colors.black
                          : WaveColors.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Play',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? Colors.black
                            : WaveColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single Spotlight row: 44px, 30px squircle leading (per-type glyph or
/// artwork), title + secondary label, left-edge accent pill on selection,
/// trailing format badge and honest meta.
class _SpotRow extends StatefulWidget {
  final _SpotItem item;
  final bool selected;
  final VoidCallback onTap;
  const _SpotRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SpotRow> createState() => _SpotRowState();
}

class _SpotRowState extends State<_SpotRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.item;
    final isSelected = widget.selected;
    final isHovered = _hover;

    Widget leading;
    if (r.art.isNotEmpty) {
      leading = r.circleArt
          ? WaveArtwork.circle(
              url: r.art, size: 30, label: r.artLabel)
          : WaveArtwork(
              url: r.art,
              size: 30,
              radius: WaveRadius.artwork,
              label: r.artLabel,
            );
    } else {
      leading = Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(WaveRadius.artwork),
        ),
        child: Icon(
          r.icon,
          size: 15,
          color: WaveColors.textSecondary,
        ),
      );
    }

    Widget? metaWidget;
    if (r.meta.isNotEmpty) {
      final parts = r.meta.split(' · ');
      if (parts.length == 2) {
        metaWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                parts[0],
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: WaveColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              parts[1],
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: WaveColors.textTertiary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      } else {
        metaWidget = Text(
          r.meta,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
            color: WaveColors.textTertiary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        );
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          height: 44,
          padding: const EdgeInsets.only(right: 14),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.10)
                : isHovered
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.transparent,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 22,
                decoration: BoxDecoration(
                  color: isSelected
                      ? WaveColors.defaultAccent
                      : Colors.transparent,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
              const SizedBox(width: 11),
              SizedBox(width: 30, height: 30, child: leading),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle.copyWith(
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: WaveColors.textPrimary,
                      ),
                    ),
                    if (r.sub.isNotEmpty)
                      Text(
                        r.sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isSelected
                              ? WaveColors.textSecondary
                              : WaveColors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              if (metaWidget != null) ...[
                const SizedBox(width: 8),
                metaWidget,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Section header marker inside the lazy results list.
class _SpotHeader extends StatelessWidget {
  final String title;
  const _SpotHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Text(
        title.toUpperCase(),
        style: WaveType.overline.copyWith(
          fontSize: 9,
          color: WaveColors.textTertiary,
        ),
      ),
    );
  }
}

/// Filter-tab chip: tinted when active, [WaveSpacing.x2]-ish gaps.
class _TabChip extends StatefulWidget {
  final _SpotTab tab;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(
              alpha: widget.selected ? 0.14 : _hover ? 0.06 : 0,
            ),
            borderRadius: BorderRadius.circular(WaveRadius.controls),
          ),
          child: Text(
            widget.tab.label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: widget.selected
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: widget.selected
                  ? WaveColors.textPrimary
                  : WaveColors.textSecondary.withValues(alpha: 0.8),
            ),
          ),
        ),
      ),
    );
  }
}

/// Search tab labels shared by the palette and the search page.
String searchTabLabel(SearchTab tab) => switch (tab) {
      SearchTab.tracks => 'Songs',
      SearchTab.artists => 'Artists',
      SearchTab.albums => 'Albums',
      SearchTab.playlists => 'Playlists',
      SearchTab.users => 'People',
    };

/// Navigate helper that preserves title/artist resolution context.
void goSearch(BuildContext context, String query) {
  context.go('/search?q=${Uri.encodeComponent(query)}');
}
