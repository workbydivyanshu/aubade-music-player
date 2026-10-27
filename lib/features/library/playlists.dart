import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/app_database.dart';
import '../search/shared_providers.dart';

/// Stored playlist track (JSON-serialised inside `saved_playlists`).
class StoredTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final String videoId;

  /// Album and length from the source row. Persisted so a track queued
  /// from a saved playlist still reaches the lossless matcher with an
  /// album it can weigh and a real duration to gate on. Rows written
  /// before these existed simply read back empty/zero.
  final String album;
  final int durationSeconds;

  const StoredTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.videoId = '',
    this.album = '',
    this.durationSeconds = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'videoId': videoId,
        'album': album,
        'durationSeconds': durationSeconds,
      };

  factory StoredTrack.fromJson(Map<String, dynamic> json) =>
      StoredTrack(
        name: json['name']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        artworkUrl: json['artworkUrl']?.toString() ?? '',
        videoId: json['videoId']?.toString() ??
            json['youtubeVideoId']?.toString() ??
            '',
        album: json['album']?.toString() ?? '',
        durationSeconds: json['durationSeconds'] is num
            ? (json['durationSeconds'] as num).toInt()
            : 0,
      );

  PlayableTrack toPlayable() => PlayableTrack(
        title: name,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
        album: album,
        durationSeconds: durationSeconds,
      );
}

/// Saved playlist entity. Mirrors Android `SavedPlaylist`.
class SavedPlaylist {
  static const String likedMode = 'liked';
  static const String likedTitle = 'Liked Songs';

  final int id;
  final String title;
  final String subtitle;
  final String mode;
  final List<StoredTrack> tracks;
  final int createdAtMillis;
  final bool isPinned;

  const SavedPlaylist({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.mode = 'custom',
    this.tracks = const [],
    this.createdAtMillis = 0,
    this.isPinned = false,
  });

  bool get isLikedSongs => mode == likedMode;
}

/// Playlist + liked-songs repository backed by SQLite.
/// Mirrors Android `PlaylistRepository` + `LikedSongsManager`.
class PlaylistRepository extends StateNotifier<List<SavedPlaylist>> {
  final AppDatabase _db;

  PlaylistRepository(this._db) : super(const []) {
    refresh();
  }

  void refresh() {
    final rows = _db.raw.select(
      'SELECT * FROM saved_playlists ORDER BY is_pinned DESC, created_at_millis DESC;',
    );
    state = rows.map((r) {
      List<StoredTrack> tracks = const [];
      try {
        final decoded = jsonDecode(r['tracks_json'] as String);
        if (decoded is List) {
          tracks = decoded
              .whereType<Map<String, dynamic>>()
              .map(StoredTrack.fromJson)
              .toList();
        }
      } catch (_) {}
      return SavedPlaylist(
        id: r['id'] as int,
        title: r['title'] as String? ?? '',
        subtitle: r['subtitle'] as String? ?? '',
        mode: r['mode'] as String? ?? 'custom',
        tracks: tracks,
        createdAtMillis: r['created_at_millis'] as int? ?? 0,
        isPinned: (r['is_pinned'] as int? ?? 0) == 1,
      );
    }).toList();
  }

  /// Creation id for a playlist row. Millisecond timestamps collide when
  /// two rows are created inside the same millisecond (library seeding
  /// plus an immediate "New playlist"), which the primary key rejects;
  /// keep it monotonic against what the table already holds.
  int _newId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final row =
        _db.raw.select('SELECT MAX(id) AS m FROM saved_playlists;').first;
    final maxId = (row['m'] as int?) ?? 0;
    return now > maxId ? now : maxId + 1;
  }

  Future<SavedPlaylist> ensureLikedSongs() async {
    final existing = state.where((p) => p.isLikedSongs);
    if (existing.isNotEmpty) return existing.first;
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, subtitle, mode, tracks_json, created_at_millis, is_pinned) '
      'VALUES(?, ?, ?, ?, ?, ?, 1);',
      [id, SavedPlaylist.likedTitle, 'Your loved tracks', SavedPlaylist.likedMode, '[]', now],
    );
    refresh();
    return state.firstWhere((p) => p.isLikedSongs);
  }

  Set<String> likedKeys() => likedKeysFor(state);

  Future<SavedPlaylist> createCustom(String title) async {
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO saved_playlists(id, title, mode, tracks_json, created_at_millis) '
      'VALUES(?, ?, ?, ?, ?);',
      [id, title.trim(), 'custom', '[]', now],
    );
    refresh();
    return state.firstWhere((p) => p.id == id);
  }

  Future<void> rename(int id, String title) async {
    _db.raw.execute(
      'UPDATE saved_playlists SET title = ? WHERE id = ?;',
      [title.trim(), id],
    );
    refresh();
  }

  Future<void> setPinned(int id, bool pinned) async {
    _db.raw.execute(
      'UPDATE saved_playlists SET is_pinned = ? WHERE id = ?;',
      [pinned ? 1 : 0, id],
    );
    refresh();
  }

  Future<void> delete(int id) async {
    _db.raw.execute('DELETE FROM saved_playlists WHERE id = ?;', [id]);
    refresh();
  }

  Future<bool> addTrack(int id, StoredTrack track) async {
    final playlist = state.firstWhere((p) => p.id == id);
    final key =
        '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';
    final exists = playlist.tracks.any((t) =>
        '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' == key);
    if (exists) return false;
    final updated = [...playlist.tracks, track];
    _db.raw.execute(
      'UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;',
      [jsonEncode(updated.map((t) => t.toJson()).toList()), id],
    );
    refresh();
    return true;
  }

  Future<void> removeTrack(int id, String trackKey) async {
    final playlist = state.firstWhere((p) => p.id == id);
    final updated = playlist.tracks
        .where((t) =>
            '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' !=
            trackKey)
        .toList();
    _db.raw.execute(
      'UPDATE saved_playlists SET tracks_json = ? WHERE id = ?;',
      [jsonEncode(updated.map((t) => t.toJson()).toList()), id],
    );
    refresh();
  }

  /// Idempotent like toggle; returns new liked state.
  Future<bool> toggleLiked(StoredTrack track) async {
    final liked = await ensureLikedSongs();
    final key =
        '${track.name.toLowerCase()}|${track.artist.toLowerCase()}';
    final isLiked = liked.tracks.any((t) =>
        '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' == key);
    if (isLiked) {
      await removeTrack(liked.id, key);
      return false;
    } else {
      await addTrack(liked.id, track);
      return true;
    }
  }
}

final playlistRepositoryProvider =
    StateNotifierProvider<PlaylistRepository, List<SavedPlaylist>>(
        (ref) {
  return PlaylistRepository(ref.watch(databaseProvider));
});

/// Lowercase `name|artist` keys for the liked playlist. Pure so the O(1)
/// dock lookup and the repository share one definition.
Set<String> likedKeysFor(Iterable<SavedPlaylist> playlists) {
  final liked = playlists.where((p) => p.isLikedSongs);
  if (liked.isEmpty) return const <String>{};
  return liked.first.tracks
      .map((t) => '${t.name.toLowerCase()}|${t.artist.toLowerCase()}')
      .toSet();
}

/// One lowercase `name|artist` set for the liked playlist, shared by every
/// heart on screen.
///
/// [PlaylistRepository] is a [StateNotifier] whose state list is replaced on
/// each mutation, so `ref.watch(playlistRepositoryProvider)` alone rebuilds
/// the dock on renames/reorders too. This notifier keeps the derived set
/// stable via [setEquals] — listeners only rebuild when a like/unlike
/// actually flips a key, turning the dock's O(all liked tracks) scan into an
/// O(1) `contains`.
class LikedKeysNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => likedKeysFor(ref.watch(playlistRepositoryProvider));

  @override
  bool updateShouldNotify(Set<String> previous, Set<String> next) =>
      !setEquals(previous, next);
}

final likedKeysSetProvider =
    NotifierProvider<LikedKeysNotifier, Set<String>>(LikedKeysNotifier.new);
