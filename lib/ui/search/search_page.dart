/// Search — Apple-grade audiophile discovery & local-Spotlight hub.
///
/// The page is ONE [CustomScrollView] with two lives:
///
/// 1. Explore hub (no query): the 'Explore' hero (24px page title) over
///    exactly three shelves — the Audiophile Hi-Res Vault, Top Genres
///    in Library (frosted genre grid) and Recently Added. NO input
///    field lives on the hub: the shell title-bar pill (Ctrl+K) is the
///    only entry point.
/// 2. Typing/deep link (?q=…): a pinned one-row compact header — a 34px
///    Fluent [TextBox] with a live 150 ms debounce and a clear
///    affordance — over the live local spotlight: top-result hero, one
///    dense virtualized [WaveDesktopTable] (sliver mode), matching
///    album / artist shelves, and an online-catalog escape hatch that
///    renders the repository's playlist search ('Streaming
///    Playlists').
/// 3. Drills (genre / era / hi-res / recents / format) open an in-page
///    detail view with its own header + table. No router changes: deep
///    links still mirror `?q=…` through the shell.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show formatDuration, playGenerated;
import '../../core/audio/stream_models.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/library/local_library_providers.dart';
import '../../features/library/local_track.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../../features/search/shared_providers.dart';
import '../components/artwork.dart';
import '../components/ambient.dart' show artworkSeedProvider;
import '../components/buttons.dart'
    show LWTooltip, WaveGhostButton, WavePlayButton;
import '../components/desktop_table.dart';
import '../components/menus.dart' show WaveContextMenu, waveTrackMenuItems;
import '../components/shelf.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

// ── Live search providers (public API — shared with Ctrl+K palette) ────────

/// Live search providers, shared with the Ctrl+K palette.
///
/// Plain [FutureProvider.family.autoDispose]: repeat visits to the same
/// query resolve instantly and a new query never blanks the page.
/// The Ctl+K command palette watches the first three; the Search page
/// itself renders local spotlight results and keeps the playlists
/// family as its online-catalog escape hatch.
final waveSearchSongsProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, String>((ref, q) {
      if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
      return ref.watch(searchRepositoryProvider).search(SearchTab.tracks, q);
    });
// NOTE: ALL query-keyed families must be autoDispose — every distinct
// keystroke prefix otherwise lives in the container forever with its
// results (songs already was; albums/artists/playlists/suggestions
// were not — unbounded retention per search session).
final waveSearchAlbumsProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, String>((ref, q) {
      if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
      return ref.watch(searchRepositoryProvider).search(SearchTab.albums, q);
    });
final waveSearchArtistsProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, String>((ref, q) {
      if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
      return ref.watch(searchRepositoryProvider).search(SearchTab.artists, q);
    });
final waveSearchPlaylistsProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, String>((ref, q) {
      if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
      return ref.watch(searchRepositoryProvider).search(SearchTab.playlists, q);
    });
final waveSuggestionsProvider = FutureProvider.autoDispose
    .family<List<SearchSuggestion>, String>((ref, q) async {
      if (q.trim().length < 2) return const <SearchSuggestion>[];
      return ref.watch(searchRepositoryProvider).getSuggestions(q.trim());
    });

/// Search result → playable (queue key = title|artist, matching playback).
PlayableTrack playableFromSearch(SearchResultItem e) => PlayableTrack(
  title: e.name,
  artist: e.artist,
  album: e.subtitle,
  artworkUrl: e.artworkUrl,
  videoId: e.videoId,
  playbackUrl: e.videoId,
);

// ── In-page drill model (simple page-state navigation, no router) ─────────

enum _DrillKind { genre, era, hiRes, recent, format }

/// An open in-page detail view (genre / decade / hi-res / recents /
/// format). [_Drill.payload] keys the matching provider; [title] carries
/// the display header.
class _Drill {
  final _DrillKind kind;
  final String payload;
  final String title;
  const _Drill(this.kind, this.payload, this.title);
}

// ── Pure helpers (no state, no providers) ──────────────────────────────────

/// artworkPath → WaveArtwork URL contract (`file://<abs>`, '' → tonal
/// initials fallback). Never touch dart:io here.
String _fileArt(String? path) =>
    path == null || path.isEmpty ? '' : 'file://$path';

String _rowString(Object? v) => v?.toString() ?? '';
int _rowInt(Object? v) => (v as num?)?.toInt() ?? 0;

/// Pure client-side format filter — the honest per-format drill (NO new
/// provider; filters a passed track list by format).
List<LocalTrack> filterTracksByFormat(List<LocalTrack> tracks, String format) =>
    tracks.where((t) => t.format == format).toList();

/// Honest quality badge for the table Quality column and the Hi-Res
/// Vault chips: CODEC plus the tag sample rate in kHz
/// (`(r/1000).toStringAsFixed(r%1000==0?0:1)+'k'` → `96k` / `44.1k`).
///
/// Bit depth is not modelled on [LocalTrack] (no `bit_depth` column
/// today), so nothing is ever fabricated: tag properties absent → the
/// badge degrades to the bare format token; lossy rows surface their
/// stored bitrate when they carry no rate. Empty everywhere → empty
/// string (the table cell hides; never a faked `—`).
String _qualityBadge(LocalTrack t) {
  final parts = <String>[];
  final fmt = t.format.toUpperCase();
  if (fmt.isNotEmpty) parts.add(fmt);
  final sr = t.sampleRate;
  if (sr != null && sr > 0) {
    parts.add('${(sr / 1000).toStringAsFixed(sr % 1000 == 0 ? 0 : 1)}k');
  } else if (t.bitrate != null &&
      t.bitrate! > 0 &&
      fmt != 'FLAC' &&
      fmt != 'WAV' &&
      fmt != 'ALAC') {
    parts.add('${t.bitrate}kbps');
  }
  return parts.join(' ');
}

/// LocalTrack → queue item. playbackUrl MUST be the absolute file path
/// (PlaybackService's local fast path reads the file directly).
GeneratedTrack _toGenerated(LocalTrack t) => GeneratedTrack(
  name: t.title,
  artist: t.artist,
  album: t.album,
  artworkUrl: _fileArt(t.artworkPath),
  durationSeconds: t.duration.inSeconds,
  playbackUrl: t.path,
);

/// LocalTrack → playable row shape for [WaveDesktopTable].
PlayableTrack _toPlayable(LocalTrack t) => PlayableTrack(
  title: t.title,
  artist: t.artist,
  album: t.album,
  artworkUrl: _fileArt(t.artworkPath),
  playbackUrl: t.path,
);

/// Queue key parity with PlayableTrack/GeneratedTrack (title|artist).
String _trackQueueKey(LocalTrack t) =>
    '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';

/// Tabular-figure variant of any token style (counts, streak lengths).
TextStyle _tabular(TextStyle base) =>
    base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

/// Per-kind overline for detail headers.
String _drillOverline(_DrillKind kind) => switch (kind) {
  _DrillKind.genre => 'GENRE',
  _DrillKind.era => 'DECADE',
  _DrillKind.hiRes => 'QUALITY',
  _DrillKind.recent => 'ADDED',
  _DrillKind.format => 'FORMAT',
};

// ── Page ───────────────────────────────────────────────────────────────────

/// Pinned query bar extent: one 34px field + 12px breathing top and
/// bottom. The hub mode shows no bar at all.
const double _kQueryBarExtent = 58.0;

/// Search — the Explore Hub when idle; the live local spotlight while
/// typing. The hub is header-less — no input lives there (the shell
/// title-bar pill + Ctrl+K own entry) — while query/deep-link mode pins
/// one compact refine bar so results cascade underneath it without ever
/// re-centering the page.
class WaveSearchPage extends ConsumerStatefulWidget {
  final String initialQuery;
  const WaveSearchPage({super.key, this.initialQuery = ''});
  @override
  ConsumerState<WaveSearchPage> createState() => _WaveSearchPageState();
}

class _WaveSearchPageState extends ConsumerState<WaveSearchPage> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  Timer? _typeDebounce;
  String _query = '';
  _Drill? _drill;
  bool _onlineView = false;
  bool _scrolled = false;
  bool _showAllGenres = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _query = widget.initialQuery;
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(WaveSearchPage old) {
    super.didUpdateWidget(old);
    if (old.initialQuery != widget.initialQuery) {
      _controller.text = widget.initialQuery;
      _query = widget.initialQuery;
      _drill = null;
      _onlineView = false;
      _typeDebounce?.cancel();
    }
  }

  @override
  void dispose() {
    _typeDebounce?.cancel();
    _controller.dispose();
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    // The Ctrl+K hint moved to the shell title bar; focus transitions
    // still repaint the sticky header.
    setState(() {});
  }

  /// Spotlight typing: results stream in on a 150 ms debounce so the
  /// provider hammer stays bounded, and any submit ALSO unfocuses +
  /// mirrors ?q= through the router + pushes history.
  void _onChanged(String v) {
    _typeDebounce?.cancel();
    _typeDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      if (v == _query && _drill == null && !_onlineView) return;
      setState(() {
        _query = v;
        _drill = null;
        _onlineView = false;
      });
    });
  }

  /// Enter in the field = history + unfocus + ?q= mirror (the live
  /// spotlight already shows the same results while typing).
  void _submit(String v) {
    final q = v.trim();
    if (q.isEmpty) return;
    ref.read(searchRepositoryProvider).pushHistory(q);
    _focus.unfocus();
    _typeDebounce?.cancel();
    setState(() => _query = q);
    context.go('/search?q=${Uri.encodeComponent(q)}');
  }

  void _clearField() {
    _typeDebounce?.cancel();
    _controller.clear();
    if (_query.isEmpty && _drill == null && !_onlineView) return;
    setState(() {
      _query = '';
      _drill = null;
      _onlineView = false;
    });
  }

  KeyEventResult _onPageKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape && _focus.hasFocus) {
      _focus.unfocus();
    }
    return KeyEventResult.ignored;
  }

  // ── Handlers: playback (proven conversion contract) ────────────────────

  /// Play one tapped track with the rest of the visible list queued.
  Future<void> _playList(List<LocalTrack> tracks, int index) async {
    if (tracks.isEmpty) return;
    final i = index.clamp(0, tracks.length - 1);
    await playGenerated(
      ref,
      context,
      _toGenerated(tracks[i]),
      sourceLabel: 'Search',
      queueAll: tracks.map(_toGenerated).toList(),
      startIndex: i,
    );
  }

  /// Single-play a hero track (queueAll keeps the call shape proven).
  Future<void> _playSingle(LocalTrack track) async {
    await playGenerated(
      ref,
      context,
      _toGenerated(track),
      sourceLabel: 'Search',
      queueAll: [_toGenerated(track)],
    );
  }

  Future<void> _playArtistQueue(String artist) async {
    final tracks = ref.read(databaseProvider).getLocalTracksForArtist(artist);
    await _playList(tracks, 0);
  }

  Future<void> _playAlbumQueue(String album, String? albumArtist) async {
    final tracks = ref
        .read(databaseProvider)
        .getLocalTracksForAlbum(album, albumArtist: albumArtist);
    await _playList(tracks, 0);
  }

  // ── Handlers: route pushes (rewritten _primary semantics) ──────────────

  /// Local album pages key on the album title (entityId semantics of
  /// the existing /album/:id grid pushes).
  void _openAlbum(String album) =>
      context.go('/album/${Uri.encodeComponent(album)}');

  void _openArtist(String artist) =>
      context.go('/artist/${Uri.encodeComponent(artist)}');

  /// Local playlists live at /playlists/:id (int). YouTube Music
  /// playlists open the read-only YT detail page — never auto-play on
  /// tap; playback starts from inside the detail page.
  void _openPlaylist(SearchResultItem item) {
    final id = int.tryParse(item.entityId);
    if (id != null) {
      context.go('/playlists/$id');
      return;
    }
    context.go(
      '/ytplaylist/${item.entityId}'
      '?title=${Uri.encodeComponent(item.name)}'
      '&art=${Uri.encodeComponent(item.artworkUrl)}',
    );
  }

  // ── Handlers: drills ────────────────────────────────────────────────────

  void _openGenre(Map<String, dynamic> row) {
    final genre = _rowString(row['genre']);
    if (genre.isEmpty) return;
    setState(() => _drill = _Drill(_DrillKind.genre, genre, genre));
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).width;
    final pad = viewport < 900
        ? 16.0
        : viewport < 1300
        ? 24.0
        : 28.0;
    final side =
        ((viewport - WaveDensity.contentMax) / 2).clamp(0, double.infinity) +
        pad;

    List<Widget> body;
    final showBar = _drill != null || _query.isNotEmpty;
    if (_drill != null) {
      body = _buildDetail(_drill!);
    } else if (_query.isNotEmpty) {
      body = _onlineView
          ? _buildOnlineResults(_query)
          : _buildActiveResults(_query);
    } else {
      body = _buildExploreHub();
    }

    return Focus(
      onKeyEvent: (_, e) => _onPageKey(e),
      child: WaveEntranceGroup(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final scrolled = n.metrics.pixels > 4;
            if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
            return false;
          },
          child: CustomScrollView(
            physics: const ClampingScrollPhysics(),
            slivers: [
              // Hub mode is header-less — the Explore hero scrolls with
              // the content and the only search entry is the shell
              // title-bar pill (Ctrl+K). Query/drill mode pins the one
              // compact refine row.
              if (showBar) ...[
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StickyHeaderDelegate(
                    child: _buildQueryBar(side),
                    extent: _kQueryBarExtent,
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.only(top: WaveSpacing.x4),
                ),
              ],
              SliverPadding(
                padding: showBar
                    ? EdgeInsets.fromLTRB(side, 0, side, 48)
                    : EdgeInsets.fromLTRB(side, WaveSpacing.x28, side, 48),
                sliver: SliverMainAxisGroup(slivers: body),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Pinned query bar (query / drill mode): ONE compact refine field,
  //    nothing else. The hub mode has no input anywhere — the shell
  //    title-bar pill (Ctrl+K) owns entry from the Explore surface.

  Widget _buildQueryBar(double side) {
    final dark = waveIsDark(context);
    final viewport = MediaQuery.sizeOf(context).width;
    // 28+ px: wraps responsively between 320 and 420 and shrinks before
    // it can ever overflow a narrow desktop window.
    final available = math.max(0.0, viewport - side * 2);
    final fieldWidth = math.min(420.0, math.max(120.0, available));

    final Widget? trailing;
    if (_controller.text.isNotEmpty) {
      trailing = LWTooltip(
        message: 'Clear search',
        child: IconButton(
          icon: Icon(
            WaveIcons.close,
            size: 11,
            color: waveTextTertiary(context),
          ),
          onPressed: _clearField,
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
          ),
        ),
      );
    } else {
      trailing = null;
    }

    return Container(
      height: _kQueryBarExtent,
      decoration: BoxDecoration(
        color: _scrolled
            ? (dark ? WaveColors.background : WaveColors.lightBackground)
            : Colors.transparent,
        border: _scrolled
            ? Border(bottom: BorderSide(color: waveDivider(context)))
            : null,
      ),
      padding: EdgeInsets.fromLTRB(side, WaveSpacing.x8, side, WaveSpacing.x8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: fieldWidth,
          height: 34,
          child: TextBox(
            controller: _controller,
            focusNode: _focus,
            style: WaveType.body,
            // Never autofocus: hub landings have no field, and a deep
            // link from SpotLight must not steal shell focus.
            placeholder: 'Search your library…',
            prefix: Padding(
              padding: const EdgeInsets.only(left: WaveSpacing.x8),
              child: Icon(
                WaveIcons.search,
                size: 13,
                color: waveTextTertiary(context),
              ),
            ),
            suffix: trailing,
            onChanged: _onChanged,
            onSubmitted: _submit,
          ),
        ),
      ),
    );
  }

  // ── Explore hub (query empty): the 'Explore' hero over exactly
  //    THREE shelves — Audiophile Hi-Res Vault, Top Genres in Library,
  //    Recently Added. Nothing else lives on the default surface.

  List<Widget> _buildExploreHub() {
    final tracks =
        ref.watch(localLibraryNotifierProvider).value ?? const <LocalTrack>[];
    final scanning = ref.watch(isScanningProvider);

    // Empty library: the exact Songs-page guidance — skip every other
    // idle section rather than showing hollow grids.
    if (tracks.isEmpty) {
      return [
        ..._buildHubHero(tracks: tracks, genres: const [], hiRes: const []),
        SliverToBoxAdapter(
          child: scanning
              ? _SkeletonRows(count: 6)
              : WaveEmpty(
                  icon: WaveIcons.music,
                  title: 'No music found',
                  subtitle: 'Add your music folders in Settings, then scan the library so your songs appear here.',
                  actionLabel: 'Open Settings',
                  onAction: () => context.go('/settings?section=library'),
                ),
        ),
      ];
    }

    final hiRes = ref.watch(localHiResProvider);
    final genres = ref.watch(localGenresProvider);
    final recent = ref.watch(localRecentTracksProvider);

    return [
      ..._buildHubHero(tracks: tracks, genres: genres, hiRes: hiRes),
      // Honest display: the Vault renders ONLY when the hi-res
      // projection carries rows — while the tag backfill is mid-flight
      // it either has rows or skips silently (no placeholder marketing,
      // no 'no hi-res yet' empty tiles).
      if (hiRes.isNotEmpty) ..._buildVaultShelf(hiRes),
      if (genres.isNotEmpty) ..._buildGenresSection(genres),
      if (recent.isNotEmpty) ..._buildRecentsShelf(recent),
    ];
  }

  /// Page hero: overline + 24px page title + a quiet tabular meta line
  /// (tracks • genres • hi-res). It sits above the shelves and scrolls
  /// away with them — no pinned bar competes on the hub.
  List<Widget> _buildHubHero({
    required List<LocalTrack> tracks,
    required List<Map<String, dynamic>> genres,
    required List<LocalTrack> hiRes,
  }) {
    final meta = [
      '${tracks.length} tracks',
      if (genres.isNotEmpty) '${genres.length} genres',
      if (hiRes.isNotEmpty) '${hiRes.length} hi-res',
    ].join(' • ');
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 0,
          rise: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YOUR LIBRARY',
                style: WaveType.overline.copyWith(
                  color: waveTextTertiary(context),
                ),
              ),
              const SizedBox(height: WaveSpacing.x2),
              Text('Explore', style: WaveType.pageTitle.copyWith(fontSize: 24)),
              const SizedBox(height: WaveSpacing.x2),
              Text(
                meta,
                style: _tabular(WaveType.meta)
                    .copyWith(color: waveTextSecondary(context)),
              ),
            ],
          ),
        ),
      ),
      const SliverPadding(padding: EdgeInsets.only(top: WaveSpacing.x28)),
    ];
  }

  /// Audiophile Hi-Res Vault — artwork-card carousel over the sharpened
  /// hi-res projection; every card wears an honest format/rate chip.
  List<Widget> _buildVaultShelf(List<LocalTrack> hiRes) {
    return _section(
      overline: 'FIDELITY',
      title: 'Audiophile Hi-Res Vault',
      count: null,
      countLabel: '${hiRes.length} tracks',
      headIndex: 1,
      child: _cardShelf([
        for (var i = 0; i < hiRes.length; i++)
          _TrackCard(
            track: hiRes[i],
            showChip: true,
            onPlay: () => _playList(hiRes, i),
          ),
      ]),
    );
  }

  /// Top Genres in Library — the frosted genre grid, top 12 with a
  /// 'See all' expander on the shelf head.
  List<Widget> _buildGenresSection(List<Map<String, dynamic>> genres) {
    final expanded = _showAllGenres;
    final visible = expanded ? genres : genres.take(12).toList();
    return _section(
      overline: 'COLLECTION',
      title: 'Top Genres in Library',
      count: null,
      countLabel: '${genres.length} genres',
      actionLabel: genres.length > 12
          ? (expanded ? 'Show Less' : 'See all (${genres.length})')
          : null,
      onAction: genres.length > 12
          ? () => setState(() => _showAllGenres = !_showAllGenres)
          : null,
      headIndex: 2,
      child: LayoutBuilder(
        builder: (context, box) {
          final cols = _responsiveCols(
            compact: 2,
            normal: 3,
            expanded: 4,
            ultrawide: 5,
          );
          const gap = WaveSpacing.x8;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < visible.length; i++)
                WaveEntrance(
                  index: i,
                  rise: 8,
                  child: SizedBox(
                    width: w,
                    height: 92,
                    child: _GenreCard(
                      name: _rowString(visible[i]['genre']),
                      tracks: _rowInt(visible[i]['track_count']),
                      albums: _rowInt(visible[i]['album_count']),
                      artworkPath: visible[i]['artwork_path'] as String?,
                      onTap: () => _openGenre(visible[i]),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Recently Added — a 24-card window over the newest-modified rows.
  /// The shelf is a glance; the full list stays in the overline-titled
  /// detail table via the genre/era/recents drills where routed.
  List<Widget> _buildRecentsShelf(List<LocalTrack> recent) {
    final items = recent.take(24).toList();
    return _section(
      overline: 'RECENT',
      title: 'Recently Added',
      count: null,
      countLabel: '${items.length} tracks',
      headIndex: 3,
      child: _cardShelf([
        for (var i = 0; i < items.length; i++)
          _TrackCard(
            track: items[i],
            showChip: false,
            onPlay: () => _playList(items, i),
          ),
      ]),
    );
  }

  /// One artwork-card carousel — the same skeleton as [WaveShelf] in
  /// components: fixed height, horizontal ListView, staggered entrance
  /// per card, 12px gutters.
  Widget _cardShelf(List<Widget> cards) {
    return SizedBox(
      height: 216,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: WaveSpacing.x8),
        itemBuilder: (context, i) => WaveEntrance(
          index: i,
          rise: 10,
          child: SizedBox(width: 160, child: cards[i]),
        ),
      ),
    );
  }

  /// The one track table — sliver mode for the parent CustomScrollView.
  /// `onPlay` receives the ORIGINAL list index (the table sorts a copy
  /// for display only), so queueAll indexes line up with the rows.
  Widget _buildTrackTable(List<LocalTrack> tracks) {
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    return WaveDesktopTable<LocalTrack>(
      sliver: true,
      items: tracks,
      keyOf: (t) => t.path,
      titleOf: (t) => t.title,
      // subtitleOf drives the ARTIST column — never pass the album here.
      subtitleOf: (t) => t.artist,
      albumOf: (t) => t.album,
      artworkOf: (t) => _fileArt(t.artworkPath),
      artworkKind: ArtworkKind.track,
      playableOf: _toPlayable,
      qualityOf: _qualityBadge,
      durationOf: (t) =>
          t.duration.inMilliseconds != 0 ? formatDuration(t.duration) : '',
      titleSortOf: (t) => t.title.toLowerCase(),
      artistSortOf: (t) => t.artist.toLowerCase(),
      albumSortOf: (t) => t.album.toLowerCase(),
      durationSortOf: (t) => t.duration.inMilliseconds,
      isCurrent: (t) => playingKey == _trackQueueKey(t),
      isPlaying: (t) =>
          playingKey == _trackQueueKey(t) &&
          ref.watch(playbackServiceProvider.select((p) => p.isPlaying)),
      playOnSingleTap: true,
      onPlay: (i) => _playList(tracks, i),
    );
  }

  /// Section wrapper: shelf head (optional overline + title + tabular
  /// count + optional ghost action) + child + a generous tail so
  /// sections breathe 24px apart.
  List<Widget> _section({
    required String title,
    required int? count,
    String? overline,
    String? countLabel,
    String? actionLabel,
    VoidCallback? onAction,
    int headIndex = 0,
    required Widget child,
  }) {
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: headIndex,
          rise: 8,
          child: _SectionTitleRow(
            overline: overline,
            title: title,
            count: count,
            countLabel: countLabel,
            actionLabel: actionLabel,
            onAction: onAction,
          ),
        ),
      ),
      const SliverPadding(padding: EdgeInsets.only(top: WaveSpacing.x8)),
      SliverToBoxAdapter(child: child),
      const SliverPadding(padding: EdgeInsets.only(top: WaveSpacing.x20)),
    ];
  }

  /// Responsive column mapping via the window breakpoint (content width
  /// itself drives the Wrap math).
  int _responsiveCols({
    required int compact,
    required int normal,
    required int expanded,
    required int ultrawide,
  }) => switch (waveBreakpointFor(MediaQuery.sizeOf(context).width)) {
    WaveBreakpoint.compact => compact,
    WaveBreakpoint.normal => normal,
    WaveBreakpoint.expanded => expanded,
    WaveBreakpoint.ultrawide => ultrawide,
  };

  // ── In-page drill detail (genre / era / hi-res / recents / format) ─────

  List<Widget> _buildDetail(_Drill d) {
    List<LocalTrack> tracks;
    switch (d.kind) {
      case _DrillKind.genre:
        tracks = ref.watch(localGenreTracksProvider(d.payload));
      case _DrillKind.era:
        tracks = ref.watch(localEraTracksProvider(d.payload));
      case _DrillKind.hiRes:
        tracks = ref.watch(localHiResProvider);
      case _DrillKind.recent:
        tracks = ref.watch(localRecentTracksProvider);
      case _DrillKind.format:
        final all =
            ref.watch(localLibraryNotifierProvider).value ??
            const <LocalTrack>[];
        tracks = filterTracksByFormat(all, d.payload);
    }

    final String meta;
    switch (d.kind) {
      case _DrillKind.genre:
        final albums = tracks.map((t) => '${t.album}|${t.albumArtist}').toSet();
        meta = '${tracks.length} tracks • ${albums.length} albums';
      case _DrillKind.era:
        meta = d.payload == 'classics'
            ? '${tracks.length} tracks • 1989 and earlier'
            : '${tracks.length} tracks • ${d.payload}s';
      case _DrillKind.hiRes:
        meta = '${tracks.length} tracks • above CD quality';
      case _DrillKind.recent:
        meta = '${tracks.length} tracks';
      case _DrillKind.format:
        meta = '${tracks.length} tracks • ${_qualityBadgeSummary(d.payload)}';
    }

    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 0,
          rise: 8,
          child: Align(
            alignment: Alignment.centerLeft,
            child: WaveGhostButton(
              label: 'All Results & Discovery',
              icon: WaveIcons.back,
              onPressed: () => setState(() => _drill = null),
            ),
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x12)),
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 1,
          rise: 8,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              WavePlayButton(
                playing: false,
                large: true,
                tooltip: 'Play all',
                onPressed: tracks.isEmpty ? null : () => _playList(tracks, 0),
              ),
              const SizedBox(width: WaveSpacing.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _drillOverline(d.kind),
                      style: WaveType.overline.copyWith(
                        color: waveTextTertiary(context),
                      ),
                    ),
                    const SizedBox(height: WaveSpacing.x2),
                    Text(
                      d.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.pageTitle,
                    ),
                    const SizedBox(height: WaveSpacing.x2),
                    Text(
                      meta,
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x12)),
      if (tracks.isEmpty)
        SliverToBoxAdapter(
          child: WaveEmpty(
            icon: WaveIcons.music,
            title: 'No tracks here yet',
            subtitle: 'This shelf fills in as the library grows.',
          ),
        )
      else
        _buildTrackTable(tracks),
    ];
  }

  /// Short fidelity descriptor for a format drill header.
  String _qualityBadgeSummary(String format) {
    final lossless = format == 'flac' || format == 'wav' || format == 'alac';
    if (format == 'mp3' || format == 'aac' || format == 'm4a') {
      return 'lossy, compressed';
    }
    return lossless ? 'lossless' : 'fast decode';
  }

  // ── Active spotlight results (query non-empty) ─────────────────────────

  List<Widget> _buildActiveResults(String q) {
    final trackRows = ref.watch(localSearchTracksProvider(q));
    final albumRows = ref.watch(localSearchAlbumsProvider(q));
    final artistRows = ref.watch(localSearchArtistsProvider(q));

    return [
      ..._buildHero(q, trackRows, albumRows, artistRows),
      ..._buildTrackResultsSection(q, trackRows),
      if (albumRows.isNotEmpty) ..._buildAlbumShelf(albumRows),
      if (artistRows.isNotEmpty) ..._buildArtistShelf(artistRows),
      ..._buildOnlineCatalogPill(q),
    ];
  }

  /// Top-result hero: exact artist → artist prefix → exact album →
  /// album prefix → first visible local track (provider rows already
  /// arrive rank-ordered exact → prefix → contains).
  List<Widget> _buildHero(
    String q,
    List<LocalTrack> visible,
    List<Map<String, dynamic>> albumRows,
    List<Map<String, dynamic>> artistRows,
  ) {
    final lq = q.toLowerCase();

    Map<String, dynamic>? artistHit;
    for (final row in artistRows) {
      if (_rowString(row['artist']).toLowerCase() == lq) {
        artistHit = row;
        break;
      }
    }
    artistHit ??= () {
      for (final row in artistRows) {
        if (_rowString(row['artist']).toLowerCase().startsWith(lq)) {
          return row;
        }
      }
      return null;
    }();

    Map<String, dynamic>? albumHit;
    for (final row in albumRows) {
      if (_rowString(row['album']).toLowerCase() == lq) {
        albumHit = row;
        break;
      }
    }
    albumHit ??= () {
      for (final row in albumRows) {
        if (_rowString(row['album']).toLowerCase().startsWith(lq)) {
          return row;
        }
      }
      return null;
    }();

    final hero = artistHit != null
        ? (
            isArtist: true,
            name: _rowString(artistHit['artist']),
            art: _fileArt(artistHit['artwork_path'] as String?),
            meta: _trackCountMeta(_rowInt(artistHit['track_count'])),
          )
        : albumHit != null
        ? (
            isArtist: false,
            name: _rowString(albumHit['album']),
            art: _fileArt(albumHit['artwork_path'] as String?),
            meta: _albumRowMeta(albumHit),
          )
        : visible.isNotEmpty
        ? (
            isArtist: false,
            name: visible.first.title,
            art: _fileArt(visible.first.artworkPath),
            meta: _trackRowMeta(visible.first),
          )
        : null;
    if (hero == null) return [];

    Future<void> play() async {
      if (artistHit != null) {
        await _playArtistQueue(_rowString(artistHit['artist']));
      } else if (albumHit != null) {
        await _playAlbumQueue(
          _rowString(albumHit['album']),
          albumHit['album_artist'] as String?,
        );
      } else {
        await _playSingle(visible.first);
      }
    }

    void primary() {
      if (artistHit != null) {
        _openArtist(_rowString(artistHit['artist']));
      } else if (albumHit != null) {
        _openAlbum(_rowString(albumHit['album']));
      } else {
        // Song hero: tapping plays it (proven search-pagination rule).
        play();
      }
    }

    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 0,
          rise: 8,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: primary,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 132,
                padding: const EdgeInsets.all(WaveSpacing.x12),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(255, 255, 255, 0.05),
                  borderRadius: BorderRadius.circular(WaveRadius.floating),
                  border: Border.all(
                    color: const Color.fromRGBO(255, 255, 255, 0.08),
                  ),
                ),
                child: Row(
                  children: [
                    hero.isArtist
                        ? WaveArtwork.circle(
                            url: hero.art,
                            size: 104,
                            label: hero.name,
                          )
                        : WaveArtwork(
                            url: hero.art,
                            size: 104,
                            radius: WaveRadius.artwork,
                            label: hero.name,
                          ),
                    const SizedBox(width: WaveSpacing.x12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'TOP RESULT',
                            style: WaveType.overline.copyWith(
                              color: waveTextTertiary(context),
                            ),
                          ),
                          const SizedBox(height: WaveSpacing.x2),
                          Text(
                            hero.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.pageTitle.copyWith(height: 1.1),
                          ),
                          const SizedBox(height: WaveSpacing.x2),
                          Text(
                            hero.meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: WaveSpacing.x8),
                    WavePlayButton(
                      playing: false,
                      large: true,
                      onPressed: () => play(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x20)),
    ];
  }

  String _trackCountMeta(int count) => '$count track${count == 1 ? '' : 's'}';

  String _albumRowMeta(Map<String, dynamic> row) {
    final parts = <String>[];
    final artist = _rowString(row['album_artist']);
    if (artist.isNotEmpty) parts.add(artist);
    final year = _rowInt(row['year']);
    if (year > 0) parts.add('$year');
    parts.add(_trackCountMeta(_rowInt(row['track_count'])));
    return parts.join(' • ');
  }

  String _trackRowMeta(LocalTrack t) {
    final parts = <String>[
      if (t.artist.isNotEmpty) t.artist,
      if (t.album.isNotEmpty) t.album,
    ];
    return parts.join(' • ');
  }

  /// One dense, virtualized table of local tracks (sliver mode).
  List<Widget> _buildTrackResultsSection(String q, List<LocalTrack> visible) {
    if (visible.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: WaveEntrance(
            index: 0,
            child: WaveEmpty(
              icon: WaveIcons.search,
              title: 'No local matches',
              subtitle:
                  '“$q” isn’t in your library. Search the online catalog below.',
            ),
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 0,
          rise: 8,
          child: _SectionTitleRow(title: 'Local Songs', count: visible.length),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(top: WaveSpacing.x4)),
      _buildTrackTable(visible),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x20)),
    ];
  }

  /// Matching albums — shelf with artwork-led cards; cover taps open
  /// the album page, hover play queues the album's real tracks.
  List<Widget> _buildAlbumShelf(
    List<Map<String, dynamic>> albumRows, {
    int entranceIndex = 2,
  }) {
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: entranceIndex,
          rise: 8,
          child: WaveShelf(
            title: 'Albums',
            count: albumRows.length,
            children: [
              for (var i = 0; i < albumRows.length; i++)
                WaveMediaCard(
                  title: _rowString(albumRows[i]['album']),
                  subtitle: _albumRowMeta(albumRows[i]),
                  artworkUrl: _fileArt(albumRows[i]['artwork_path'] as String?),
                  // artist stays empty → WaveMediaCard skips the
                  // track-shaped context menu for an album row.
                  artist: '',
                  onTap: () => _openAlbum(_rowString(albumRows[i]['album'])),
                  onPlay: () => _playAlbumQueue(
                    _rowString(albumRows[i]['album']),
                    albumRows[i]['album_artist'] as String?,
                  ),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x20)),
    ];
  }

  /// Matching artists — circle cards routed to the artist page.
  List<Widget> _buildArtistShelf(
    List<Map<String, dynamic>> artistRows, {
    int entranceIndex = 3,
  }) {
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: entranceIndex,
          rise: 8,
          child: WaveShelf(
            title: 'Artists',
            count: artistRows.length,
            cardWidth: 140,
            height: 168,
            children: [
              for (var i = 0; i < artistRows.length; i++)
                WaveArtistCard(
                  name: _rowString(artistRows[i]['artist']),
                  artworkUrl: _fileArt(
                    artistRows[i]['artwork_path'] as String?,
                  ),
                  rank: i + 1,
                  onTap: () => _openArtist(_rowString(artistRows[i]['artist'])),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x20)),
    ];
  }

  /// Online streaming fallback pill — pocket-sized, honest labeling.
  List<Widget> _buildOnlineCatalogPill(String q) {
    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 5,
          rise: 8,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _PillChip(
              label: 'Search online catalog for “$q”',
              trailingIcon: WaveIcons.chevronRight,
              onTap: () => setState(() => _onlineView = true),
            ),
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x8)),
    ];
  }

  // ── Online catalog results (Streaming Playlists — the only online
  //    path the repository exposes for a raw query) ────────────────────────

  List<Widget> _buildOnlineResults(String q) {
    final playlists = ref.watch(waveSearchPlaylistsProvider(q));

    return [
      SliverToBoxAdapter(
        child: WaveEntrance(
          index: 0,
          rise: 8,
          child: Align(
            alignment: Alignment.centerLeft,
            child: WaveGhostButton(
              label: 'Local Results',
              icon: WaveIcons.back,
              onPressed: () => setState(() => _onlineView = false),
            ),
          ),
        ),
      ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x12)),
      if (playlists.isLoading)
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Streaming Playlists', style: WaveType.sectionTitle),
              const SizedBox(height: WaveSpacing.x8),
              _SkeletonCards(count: 6, size: 124),
            ],
          ),
        )
      else if (playlists.hasError)
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Streaming Playlists', style: WaveType.sectionTitle),
              const SizedBox(height: WaveSpacing.x8),
              WaveEmpty(
                icon: WaveIcons.discover,
                title: 'Online search failed',
                subtitle: 'Check your connection and try again.',
                actionLabel: 'Retry',
                onAction: () => ref.refresh(waveSearchPlaylistsProvider(q)),
              ),
            ],
          ),
        )
      else if (playlists.valueOrNull?.isEmpty != false)
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Streaming Playlists', style: WaveType.sectionTitle),
              const SizedBox(height: WaveSpacing.x8),
              WaveEmpty(
                icon: WaveIcons.discover,
                title: 'No online playlists found',
                subtitle: 'Try a broader term for “$q”.',
              ),
            ],
          ),
        )
      else
        SliverToBoxAdapter(
          child: WaveEntrance(
            index: 1,
            rise: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Streaming Playlists', style: WaveType.sectionTitle),
                const SizedBox(height: WaveSpacing.x8),
                // Reuse the repository FutureProvider as-is: the ONLY
                // online path in the repo for a raw query is the
                // playlist search, so the fallback labels itself
                // honestly.
                SizedBox(
                  height: 216,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: playlists.valueOrNull!.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: WaveSpacing.x8),
                    itemBuilder: (context, i) {
                      final p = playlists.valueOrNull![i];
                      return WaveEntrance(
                        index: i,
                        rise: 10,
                        child: SizedBox(
                          width: 160,
                          child: WaveMediaCard(
                            title: p.name,
                            subtitle: p.subtitle.isNotEmpty
                                ? p.subtitle
                                : p.artist,
                            artworkUrl: p.artworkUrl,
                            titleFallback: p.name,
                            artist: '',
                            // Playlist detail pages start playback
                            // themselves; never auto-play on tap.
                            onTap: () => _openPlaylist(p),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      SliverPadding(padding: const EdgeInsets.only(bottom: WaveSpacing.x12)),
    ];
  }
}

// ── Building blocks ────────────────────────────────────────────────────────

/// Pinned header delegate — the child is rebuilt by the page state on
/// every data change; extents stay constant (one compact field row).
class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;
  const _StickyHeaderDelegate({required this.child, required this.extent});
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      child;
  @override
  bool shouldRebuild(covariant _StickyHeaderDelegate old) =>
      old.child != child || old.extent != extent;
}

/// Canonical section head: optional overline + title + tabular count +
/// optional ghost link (Clear All / See all). Hierarchy stays
/// typographic — no boxes. Overline-labeled shelves (the Explore Hub)
/// step the title down to 14pt; bare heads keep the 15pt idiom.
class _SectionTitleRow extends StatelessWidget {
  final String title;
  final int? count;

  /// Text override for the count slot (e.g. '12 genres'); wins over
  /// [count] when set.
  final String? countLabel;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? overline;
  const _SectionTitleRow({
    required this.title,
    this.count,
    this.countLabel,
    this.actionLabel,
    this.onAction,
    this.overline,
  });
  @override
  Widget build(BuildContext context) {
    final heading = overline == null
        ? WaveType.sectionTitle
        : WaveType.sectionTitle.copyWith(fontSize: 14);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (overline != null && overline!.isNotEmpty) ...[
          Text(
            overline!.toUpperCase(),
            style: WaveType.overline.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
          const SizedBox(height: WaveSpacing.x2),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: heading,
              ),
            ),
            if (countLabel != null || count != null) ...[
              const SizedBox(width: WaveSpacing.x2),
              Text(
                countLabel ?? count.toString(),
                style: _tabular(WaveType.meta)
                    .copyWith(color: waveTextTertiary(context)),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(width: WaveSpacing.x8),
              WaveGhostButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ],
    );
  }
}

/// Chip-shaped pill (999 radius, WaveChip visual language) used for the
/// online-catalog escape hatch. Hover = waveIsDark-consistent wash.
class _PillChip extends StatefulWidget {
  final String label;
  final IconData? trailingIcon;
  final VoidCallback? onTap;
  const _PillChip({
    required this.label,
    this.trailingIcon,
    this.onTap,
  });
  @override
  State<_PillChip> createState() => _PillChipState();
}

class _PillChipState extends State<_PillChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final hover = _hover && widget.onTap != null;
    final fill = hover
        ? (dark ? Colors.white : Colors.black).withValues(
            alpha: WaveState.hoverAlpha,
          )
        : (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    final border = dark
        ? WaveColors.outlineSoft
        : WaveColors.lightOutline;
    final labelColor = dark
        ? WaveColors.textSecondary
        : WaveColors.lightTextSecondary;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: widget.onTap == null
            ? HitTestBehavior.opaque
            : HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          curve: WaveMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: WaveSpacing.x12,
            vertical: WaveSpacing.x4,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.label.copyWith(fontSize: 11, color: labelColor),
              ),
              if (widget.trailingIcon != null) ...[
                const SizedBox(width: WaveSpacing.x2),
                Icon(
                  widget.trailingIcon,
                  size: 11,
                  color: waveTextTertiary(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted dark-glass genre card (user-specified glass values in dark,
/// token equivalents in light) with real artwork when the DB carries a
/// representative cover and a tonal initials tile when it does not.
class _GenreCard extends StatefulWidget {
  final String name;
  final int tracks;
  final int albums;
  final String? artworkPath;
  final VoidCallback onTap;
  const _GenreCard({
    required this.name,
    required this.tracks,
    required this.albums,
    required this.artworkPath,
    required this.onTap,
  });
  @override
  State<_GenreCard> createState() => _GenreCardState();
}

class _GenreCardState extends State<_GenreCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          curve: WaveMotion.standard,
          padding: const EdgeInsets.all(WaveSpacing.x8),
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black).withValues(
                    alpha: WaveState.hoverAlpha,
                  )
                : dark
                ? const Color.fromRGBO(255, 255, 255, 0.05)
                : WaveColors.lightSurface,
            borderRadius: BorderRadius.circular(WaveRadius.floating),
            border: Border.all(
              color: dark
                  ? const Color.fromRGBO(255, 255, 255, 0.08)
                  : WaveColors.lightOutline,
            ),
          ),
          child: Row(
            children: [
              WaveArtwork(
                url: _fileArt(widget.artworkPath),
                size: 56,
                radius: WaveRadius.artwork,
                label: widget.name,
              ),
              const SizedBox(width: WaveSpacing.x8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.sectionTitle,
                    ),
                    const SizedBox(height: WaveSpacing.x2),
                    Text(
                      '${widget.tracks} tracks • ${widget.albums} albums',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: waveTextSecondary(context),
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

/// Artwork-led track card for the Explore Hub shelves (Hi-Res Vault +
/// Recently Added). Same visual skeleton as WaveMediaCard — hover play
/// circle, pressed scale, seed-tinted shadow — with an honest
/// format/rate chip row for the Vault and a context menu built for the
/// REAL track (file ops included).
class _TrackCard extends ConsumerStatefulWidget {
  final LocalTrack track;
  final bool showChip;
  final VoidCallback onPlay;
  const _TrackCard({
    required this.track,
    required this.showChip,
    required this.onPlay,
  });
  @override
  ConsumerState<_TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends ConsumerState<_TrackCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final art = _fileArt(widget.track.artworkPath);
    final seedColor =
        ref.watch(artworkSeedProvider(art)).valueOrNull ??
        const Color(0xFF232838);
    final chip = _qualityBadge(widget.track);
    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        ref: ref,
        title: widget.track.title,
        artist: widget.track.artist,
        artworkUrl: art,
        playable: _toPlayable(widget.track),
      ),
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
          onTap: widget.onPlay,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
                duration: WaveMotion.fast,
                curve: Curves.easeOutCubic,
                child: AnimatedContainer(
                  duration: WaveMotion.normal,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: WaveRadius.artworkRadius,
                    boxShadow: [
                      if (_hover) ...[
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: dark ? 0.45 : 0.18,
                          ),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                        BoxShadow(
                          color: seedColor.withValues(alpha: 0.20),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ],
                  ),
                  child: Stack(
                    children: [
                      WaveArtwork(
                        url: art,
                        size: 160,
                        radius: WaveRadius.artwork,
                        title: widget.track.title,
                        artist: widget.track.artist,
                      ),
                      Positioned.fill(
                        child: AnimatedOpacity(
                          duration: WaveMotion.fast,
                          opacity: _hover ? 1 : 0,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: WaveRadius.artworkRadius,
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.55),
                                ],
                              ),
                            ),
                            child: Center(
                              child: AnimatedScale(
                                scale: _hover ? 1.0 : 0.70,
                                duration: WaveMotion.fast,
                                curve: Curves.easeOutBack,
                                child: GestureDetector(
                                  onTap: widget.onPlay,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: accent,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 12,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      WaveIcons.play,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(
                  color: dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary,
                ),
              ),
              const SizedBox(height: WaveSpacing.x2),
              Row(
                children: [
                  if (widget.showChip && chip.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: WaveSpacing.x4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(
                          WaveRadius.controls,
                        ),
                      ),
                      child: Text(
                        chip,
                        style: _tabular(WaveType.label).copyWith(
                          fontSize: 10,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: WaveSpacing.x2),
                  ],
                  Expanded(
                    child: Text(
                      widget.track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        fontSize: 11.5,
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pending-section skeleton — static blocks, alpha 0.06, never a
/// full-page blank, never a shimmer.
class _SkeletonRows extends StatelessWidget {
  final int count;
  const _SkeletonRows({required this.count});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final wash = (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            height: 54,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const SizedBox(width: 30),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: wash,
                      borderRadius: BorderRadius.circular(WaveRadius.artwork),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 11,
                          width: 180,
                          decoration: BoxDecoration(
                            color: wash,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 9,
                          width: 120,
                          decoration: BoxDecoration(
                            color: wash,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Horizontal skeleton for pending shelves (online playlists).
class _SkeletonCards extends StatelessWidget {
  final int count;
  final double size;
  const _SkeletonCards({required this.count, required this.size});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final wash = (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    return SizedBox(
      height: size + 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: wash,
                borderRadius: BorderRadius.circular(WaveRadius.artwork),
              ),
            ),
            const SizedBox(height: 5),
            Container(
              height: 10,
              width: size * 0.8,
              decoration: BoxDecoration(
                color: wash,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
