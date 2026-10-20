import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import 'shared_providers.dart';

enum SearchTab { tracks, artists, albums, playlists, users }

class SearchResultItem {
  final String name;
  final String artist;
  final String artworkUrl;
  final String subtitle;
  final String videoId;
  final String entityId;
  final SearchTab tab;
  final int durationSeconds;

  const SearchResultItem({
    required this.name,
    this.artist = '',
    this.artworkUrl = '',
    this.subtitle = '',
    this.videoId = '',
    this.entityId = '',
    required this.tab,
    this.durationSeconds = 0,
  });
}

class SearchSuggestion {
  final String text;
  final SearchTab tab;
  final String subtitle;
  final String artworkUrl;
  final String artist;

  const SearchSuggestion({
    required this.text,
    required this.tab,
    this.subtitle = '',
    this.artworkUrl = '',
    this.artist = '',
  });
}

final _suggestionJunk = RegExp(
  r'\b(edit|slowed|reverb|nightcore|tiktok|gameplay|walkthrough|trailer|metroid|minecraft|fortnite|tv live)\b',
  caseSensitive: false,
);

/// True when [name] is an artist/song/album title for the typed [query]
/// ("metro" → Metro Boomin) rather than a loose YouTube complete hit.
bool suggestionNameMatchesQuery(String name, String query) {
  final n = name.toLowerCase().trim();
  final q = query.toLowerCase().trim();
  if (q.length < 2 || n.isEmpty) return false;
  if (n == q || n.startsWith(q)) return true;
  for (final word in n.split(RegExp(r'[\s\-_/&,+.]+'))) {
    if (word.startsWith(q)) return true;
  }
  return false;
}

bool suggestionLooksLikeJunk(String title) =>
    _suggestionJunk.hasMatch(title);

/// Unified search: YouTube Music for content tabs, Last.fm for users.
/// Mirrors Kotlin LastWave `SearchRepository` + `SearchHistoryRepository`.
class SearchRepository {
  final LastFmApiService _api;
  final InnerTubeMusicApi _tube;
  final AppDatabase _db;
  final String Function() _apiKey;

  SearchRepository(this._api, this._tube, this._db, this._apiKey);

  Future<List<SearchSuggestion>> getSuggestions(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    // Local-first suggestions — titles, artists and albums come from
    // the on-device library instead of an InnerTube round-trip.
    final local = _db.searchLocalTracks(q);
    final out = <SearchSuggestion>[];
    final seen = <String>{};

    void add({
      required String text,
      required SearchTab tab,
      String subtitle = '',
      String artworkUrl = '',
      String artist = '',
    }) {
      final key = '${tab.name}:${text.toLowerCase()}';
      if (!seen.add(key)) return;
      out.add(SearchSuggestion(
        text: text,
        tab: tab,
        subtitle: subtitle,
        artworkUrl: artworkUrl,
        artist: artist,
      ));
    }

    // Distinct artists / albums in result order. The full artist list
    // feeds the known-artist gate for single-word queries below.
    final artists = <String>[];
    final artistSet = <String>{};
    final albums = <String>[];
    final albumSet = <String>{};
    for (final t in local) {
      if (t.artist.isNotEmpty && artistSet.add(t.artist.toLowerCase())) {
        artists.add(t.artist);
      }
      if (t.album.isNotEmpty && albumSet.add(t.album.toLowerCase())) {
        albums.add(t.album);
      }
    }

    var artistCount = 0;
    for (final a in artists) {
      if (!suggestionNameMatchesQuery(a, q)) continue;
      if (suggestionLooksLikeJunk(a)) continue;
      add(
        text: a,
        tab: SearchTab.artists,
        subtitle: 'Artist',
        artist: a,
      );
      artistCount++;
      if (artistCount >= 3) break;
    }

    final artistKeys = out
        .where((s) => s.tab == SearchTab.artists)
        .map((s) => s.text.toLowerCase())
        .toList();
    final requireKnownArtist =
        !q.contains(' ') && artistKeys.isNotEmpty;

    var albumCount = 0;
    for (final al in albums) {
      if (!suggestionNameMatchesQuery(al, q)) continue;
      if (suggestionLooksLikeJunk(al)) continue;
      add(
        text: al,
        tab: SearchTab.albums,
        subtitle: 'Album',
      );
      albumCount++;
      if (albumCount >= 3) break;
    }

    var songCount = 0;
    for (final t in local) {
      if (!suggestionNameMatchesQuery(t.title, q)) continue;
      if (suggestionLooksLikeJunk(t.title)) continue;
      if (requireKnownArtist) {
        final a = t.artist.toLowerCase();
        final known = artistKeys.any((n) =>
            a == n || a.startsWith(n) || n.startsWith(a) || a.contains(n));
        if (!known) continue;
      }
      add(
        text: t.title,
        tab: SearchTab.tracks,
        subtitle: t.artist.isEmpty ? 'Song' : t.artist,
        artworkUrl:
            t.artworkPath != null ? 'file://${t.artworkPath}' : '',
        artist: t.artist,
      );
      songCount++;
      if (songCount >= 4) break;
    }
    return out;
  }

  Future<List<SearchResultItem>> search(
      SearchTab tab, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    switch (tab) {
      case SearchTab.tracks:
        // Local library: files on device, ranked exact/prefix title
        // first (see AppDatabase.searchLocalTracks).
        return _db.searchLocalTracks(q).map((t) => SearchResultItem(
              name: t.title,
              artist: t.artist,
              artworkUrl:
                  t.artworkPath != null ? 'file://${t.artworkPath}' : '',
              subtitle: t.album,
              videoId: t.path,
              entityId: t.path,
              tab: tab,
              durationSeconds: t.duration.inSeconds,
            )).toList();
      case SearchTab.albums:
        // Local albums: title or artist matching the query. entityId
        // carries the album title, which local album pages key on.
        final lq = q.toLowerCase();
        return _db.getLocalAlbums()
            .where((a) =>
                ((a['album'] as String?) ?? '').toLowerCase().contains(lq) ||
                ((a['album_artist'] as String?) ?? '')
                    .toLowerCase()
                    .contains(lq))
            .map((a) {
              final title = (a['album'] as String?) ?? '';
              final artist = (a['album_artist'] as String?) ?? '';
              final artwork = a['artwork_path'] as String?;
              final count = (a['track_count'] as int?) ?? 0;
              return SearchResultItem(
                name: title,
                artist: artist,
                subtitle: count > 0 ? '$count tracks' : '',
                artworkUrl: artwork != null ? 'file://$artwork' : '',
                entityId: title,
                tab: tab,
              );
            }).toList();
      case SearchTab.artists:
        // Local artists: name matching the query. entityId carries the
        // artist name, which local artist pages key on.
        final lq = q.toLowerCase();
        return _db.getLocalArtists()
            .where((a) =>
                ((a['artist'] as String?) ?? '').toLowerCase().contains(lq))
            .map((a) {
              final name = (a['artist'] as String?) ?? '';
              final count = (a['track_count'] as int?) ?? 0;
              return SearchResultItem(
                name: name,
                subtitle: count > 0 ? '$count tracks' : 'Artist',
                entityId: name,
                tab: tab,
              );
            }).toList();
      case SearchTab.playlists:
        final playlists =
            await _tube.searchPlaylists(q, limit: 30);
        return playlists
            .map((e) => SearchResultItem(
                  name: e.title,
                  artist: e.author,
                  subtitle: [
                    if (e.author.isNotEmpty) e.author,
                    if (e.trackCountText.isNotEmpty)
                      e.trackCountText,
                  ].join(' • '),
                  artworkUrl: e.artworkUrl,
                  entityId: e.id,
                  tab: tab,
                ))
            .toList();
      case SearchTab.users:
        return [?await _lookupUser(q)];
    }
  }

  Future<SearchResultItem?> _lookupUser(String username) async {
    try {
      final json = await _api.get({
        'method': 'user.getinfo',
        'user': username,
        'api_key': _apiKey(),
      });
      final user = json['user'];
      if (user is! Map<String, dynamic>) return null;
      return SearchResultItem(
        name: user['name']?.toString() ?? username,
        subtitle:
            '${user['playcount']?.toString() ?? '0'} scrobbles',
        tab: SearchTab.users,
        entityId: user['name']?.toString() ?? username,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<YouTubeMusicTrack>> songsFor(
      SearchResultItem item) async {
    if (item.entityId.isEmpty) return const [];
    if (item.tab == SearchTab.tracks && item.videoId.isNotEmpty) {
      final details = await _tube.fetchSongDetails(item.videoId);
      return [?details];
    }
    return _tube.browseSongs(item.entityId, limit: 50);
  }

  /// Best hit for a recent query — the top-ranked local-library match
  /// (exact/prefix title first, see [AppDatabase.searchLocalTracks]).
  /// Used by the empty Search page cards.
  Future<SearchResultItem?> previewForQuery(String query) async {
    final q = query.trim();
    if (q.isEmpty) return null;
    final local = _db.searchLocalTracks(q, limit: 1);
    if (local.isEmpty) return null;
    final t = local.first;
    return SearchResultItem(
      name: t.title,
      artist: t.artist,
      artworkUrl: t.artworkPath != null ? 'file://${t.artworkPath}' : '',
      subtitle: t.album,
      videoId: t.path,
      entityId: t.path,
      tab: SearchTab.tracks,
      durationSeconds: t.duration.inSeconds,
    );
  }

  List<String> history() => _db.loadSearchHistory();
  void pushHistory(String q) {
    if (q.trim().isNotEmpty) _db.pushSearchHistory(q.trim());
  }

  void clearHistory() => _db.clearSearchHistory();
  void removeHistory(String q) => _db.removeSearchHistory(q);
}

/// Canonical artist key for taste math (mirrors feed's
/// `normalizeArtistKey` without pulling the feed import chain):
/// lowercase, collapsed space, feat-credit suffixes stripped.
String _searchArtistKey(String artist) {
  var k = artist.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  if (k.isEmpty ||
      k == 'unknown artist' ||
      k == 'various artists' ||
      k == 'unknown') {
    return '';
  }
  k = k
      .replaceAll(
          RegExp(r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]'),
          '')
      .trim();
  k = k
      .replaceAll(
          RegExp(r'\s+(feat\.?|ft\.?|featuring|with)\s+.+$'), '')
      .trim();
  return k;
}

/// Rank album search hits by taste: known artists (normalized
/// affinity) first, everything else in original shelf order (explicit
/// index tiebreak — Dart sort is unstable). Pure. Never drops.
List<SearchResultItem> rankSearchAlbumsByTaste(
  List<SearchResultItem> albums,
  Map<String, double> affinities,
) {
  if (albums.isEmpty || affinities.isEmpty) return albums;
  String artistOf(SearchResultItem a) =>
      a.artist.isNotEmpty ? a.artist : a.subtitle;
  final indexed = albums.asMap().entries.toList();
  indexed.sort((x, y) {
    final fa = affinities[_searchArtistKey(artistOf(x.value))] ?? -1.0;
    final fb = affinities[_searchArtistKey(artistOf(y.value))] ?? -1.0;
    final c = fb.compareTo(fa);
    if (c != 0) return c;
    return x.key.compareTo(y.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Rank playlist search hits by taste: author affinity (×2) plus
/// title-token overlap with taste artists (×0.5 per hit). Playlists
/// rarely carry a clean artist field (`author` is often the curator),
/// so title overlap is the main signal. Pure. Never drops.
List<SearchResultItem> rankSearchPlaylistsByTaste(
  List<SearchResultItem> playlists,
  Map<String, double> affinities,
) {
  if (playlists.isEmpty || affinities.isEmpty) return playlists;
  double scoreOf(SearchResultItem p) {
    var score = (affinities[_searchArtistKey(p.artist)] ?? 0.0) * 2.0;
    final title = p.name.toLowerCase();
    if (title.isNotEmpty) {
      for (final entry in affinities.entries) {
        final key = entry.key;
        if (key.length < 3) continue;
        if (title.contains(key)) score += entry.value * 0.5;
      }
    }
    return score;
  }

  final scored = playlists.asMap().entries.map((e) {
    final hasSignal = scoreOf(e.value) > 0;
    return (item: e.value, index: e.key, score: scoreOf(e.value),
        known: hasSignal);
  }).toList();
  scored.sort((a, b) {
    // Items with any taste signal always outrank items with none;
    // within each group, higher score first, shelf order tiebreak.
    if (a.known != b.known) return a.known ? -1 : 1;
    final c = b.score.compareTo(a.score);
    if (c != 0) return c;
    return a.index.compareTo(b.index);
  });
  return scored.map((e) => e.item).toList();
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(databaseProvider),
    () => ref.watch(prefsApiKeyProvider),
  );
});
