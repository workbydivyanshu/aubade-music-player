import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../features/library/local_track.dart';
import '../../features/library/vault_analytics.dart';

/// Desktop persistent storage. Schema mirrors Kotlin LastWave
/// `AppDatabase` (Room, v12) tables plus desktop additions:
/// - `artwork_cache`, `recommendation_exclusions`, `saved_playlists`,
///   `downloaded_tracks` (same logical columns)
/// - `kv_store` (DataStore/ prefs equivalent for misc state)
/// - `playback_session` (single-row persisted queue snapshot)
/// - `search_history` (replaces SharedPreferences query list)
/// - `local_plays` (v5: on-device play log driving the keyless-guest
///   taste algorithm — no Last.fm account needed)
///
/// Migrations are additive and never drop user data (no destructive
/// fallback, unlike the temporary Android `fallbackToDestructiveMigration`).
class AppDatabase {
  static const int schemaVersion = 10;

  final Database _db;

  AppDatabase._(this._db);

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = p.join(dir.path, 'aubade.db');
    await _migrateLegacyFile(dir.path, file);
    final db = sqlite3.open(file);
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  /// One-time migration of the pre-rebrand database (`lastwave.db`)
  /// to `aubade.db` in the same support directory, including the WAL
  /// and SHM sidecars so no committed transaction is lost. Runs
  /// before the connection opens; any failure (e.g. cross-device
  /// rename) falls back to copy+delete, and if that also fails the
  /// app opens a fresh `aubade.db` instead of crashing.
  static Future<void> _migrateLegacyFile(
      String dirPath, String newPath) async {
    try {
      final legacy = File(p.join(dirPath, 'lastwave.db'));
      if (await File(newPath).exists() || !await legacy.exists()) return;
      if (!await _moveFile(legacy.path, newPath)) return;
      for (final suffix in const ['-wal', '-shm']) {
        try {
          final sidecar = File('${legacy.path}$suffix');
          if (await sidecar.exists()) {
            await _moveFile(sidecar.path, '$newPath$suffix');
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Rename [from] to [to]; falls back to copy+delete on failure.
  /// Returns true when [to] exists afterwards.
  static Future<bool> _moveFile(String from, String to) async {
    try {
      await File(from).rename(to);
      return await File(to).exists();
    } catch (_) {
      try {
        await File(from).copy(to);
        // A failed cleanup must not orphan the sidecars: the copied
        // destination is usable, so report success and keep going.
        try {
          await File(from).delete();
        } catch (_) {}
        return await File(to).exists();
      } catch (_) {
        return false;
      }
    }
  }

  /// In-memory instance for tests.
  factory AppDatabase.inMemory() {
    final db = sqlite3.openInMemory();
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  Database get raw => _db;

  void _migrate() {
    _db.execute('PRAGMA journal_mode=WAL;');
    final version =
        _db.select('PRAGMA user_version;').first['user_version'] as int;
    if (version < 1) {
      _createV1();
      _db.execute('PRAGMA user_version=1;');
    }
    if (version < 2) {
      _createV2();
      _db.execute('PRAGMA user_version=2;');
    }
    if (version < 3) {
      _createV3();
      _db.execute('PRAGMA user_version=3;');
    }
    if (version < 4) {
      _createV4();
      _db.execute('PRAGMA user_version=4;');
    }
    if (version < 5) {
      _createV5();
      _db.execute('PRAGMA user_version=5;');
    }
    if (version < 6) {
      _createV6();
      _db.execute('PRAGMA user_version=6;');
    }
    if (version < 7) {
      _createV7();
      _db.execute('PRAGMA user_version=7;');
    }
    if (version < 8) {
      _createV8();
      _db.execute('PRAGMA user_version=8;');
    }
    if (version < 9) {
      // Duration stored by the pre-0.01.07 scanner was true seconds
      // mislabeled as ms (audiotags returns seconds). Repair 1000x.
      _db.execute(
          'UPDATE local_tracks SET duration_ms = duration_ms * 1000 '
          'WHERE duration_ms > 0 AND duration_ms < 3600000;');
      _db.execute('PRAGMA user_version=9;');
    }
    if (version < 10) {
      // v10: stream properties mined from file headers (null until scanned).
      try {
        _db.execute(
            'ALTER TABLE local_tracks ADD COLUMN bit_depth INTEGER;');
      } catch (_) {}
      try {
        _db.execute(
            'ALTER TABLE local_tracks ADD COLUMN size_bytes INTEGER;');
      } catch (_) {}
      _db.execute('PRAGMA user_version=10;');
    }
  }

  void _createV1() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS artwork_cache (
        cache_key TEXT PRIMARY KEY,
        url TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT '',
        timestamp_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS recommendation_exclusions (
        track_key TEXT PRIMARY KEY,
        excluded_at_millis INTEGER NOT NULL DEFAULT 0,
        track_name TEXT NOT NULL DEFAULT '',
        artist_name TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS saved_playlists (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        subtitle TEXT NOT NULL DEFAULT '',
        mode TEXT NOT NULL DEFAULT 'custom',
        tracks_json TEXT NOT NULL DEFAULT '[]',
        created_at_millis INTEGER NOT NULL DEFAULT 0,
        discover_signature TEXT,
        custom_cover_uri TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS downloaded_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_key TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        artwork_url TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL DEFAULT '',
        file_size_bytes INTEGER NOT NULL DEFAULT 0,
        format_badge TEXT NOT NULL DEFAULT '',
        duration_ms INTEGER NOT NULL DEFAULT 0,
        bitrate_kbps INTEGER NOT NULL DEFAULT 0,
        is_lossless INTEGER NOT NULL DEFAULT 0,
        has_lyrics INTEGER NOT NULL DEFAULT 0,
        lrc_file_path TEXT NOT NULL DEFAULT '',
        downloaded_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_downloaded_track_key
      ON downloaded_tracks(track_key);
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS kv_store (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playback_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload_json TEXT NOT NULL DEFAULT '{}'
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS search_history (
        query TEXT PRIMARY KEY,
        updated_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  // -- kv helpers ------------------------------------------------------

  String? kvGet(String key) {
    final rows =
        _db.select('SELECT v FROM kv_store WHERE k = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['v'] as String;
  }

  void kvSet(String key, String value) {
    _db.execute(
      'INSERT INTO kv_store(k, v) VALUES(?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v;',
      [key, value],
    );
  }

  // -- search history --------------------------------------------------

  List<String> loadSearchHistory({int limit = 25}) {
    return _db
        .select(
          'SELECT query FROM search_history '
          'ORDER BY updated_at_millis DESC LIMIT ?;',
          [limit],
        )
        .map((r) => r['query'] as String)
        .toList();
  }

  void pushSearchHistory(String query) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO search_history(query, updated_at_millis) VALUES(?, ?) '
      'ON CONFLICT(query) DO UPDATE SET updated_at_millis = excluded.updated_at_millis;',
      [query, now],
    );
    _db.execute(
      'DELETE FROM search_history WHERE query NOT IN ('
      'SELECT query FROM search_history '
      'ORDER BY updated_at_millis DESC LIMIT 25);',
    );
  }

  void clearSearchHistory() {
    _db.execute('DELETE FROM search_history;');
  }

  void removeSearchHistory(String query) {
    _db.execute('DELETE FROM search_history WHERE query = ?;', [query]);
  }

  // -- recommendation exclusions ("don't recommend") --------------------
  //
  // Key format matches GeneratedTrack.key / HomeTrack.key exactly
  // ('name|artist', lowercased) so feed filtering is a set lookup.

  static String exclusionKey(String name, String artist) =>
      '${name.toLowerCase()}|${artist.toLowerCase()}';

  Set<String> loadExclusionKeys() {
    return {
      for (final r in _db.select(
          'SELECT track_key FROM recommendation_exclusions;'))
        (r['track_key'] as String?) ?? '',
    }..remove('');
  }

  void addExclusion({
    required String name,
    required String artist,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO recommendation_exclusions '
      '(track_key, excluded_at_millis, track_name, artist_name) '
      'VALUES (?, ?, ?, ?);',
      [
        exclusionKey(name, artist),
        DateTime.now().millisecondsSinceEpoch,
        name,
        artist,
      ],
    );
  }

  void removeExclusion(String key) {
    _db.execute(
        'DELETE FROM recommendation_exclusions WHERE track_key = ?;',
        [key]);
  }

  // -- playback session -------------------------------------------------

  Map<String, dynamic> loadPlaybackSession() {
    final rows = _db.select(
        'SELECT payload_json FROM playback_session WHERE id = 1;');
    if (rows.isEmpty) return const {};
    try {
      final decoded = jsonDecode(rows.first['payload_json'] as String);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return const {};
  }

  void savePlaybackSession(Map<String, dynamic> payload) {
    _db.execute(
      'INSERT INTO playback_session(id, payload_json) VALUES(1, ?) '
      'ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json;',
      [jsonEncode(payload)],
    );
  }

  void clearPlaybackSession() {
    _db.execute('DELETE FROM playback_session WHERE id = 1;');
  }

  // -- stream disk cache (Limusic fast-path) -------------------------------
  //
  // Persistent copy of resolved YouTube stream URLs + match metadata.
  // Memory cache stays authoritative for speed; disk is warm-start +
  // cross-restart reuse. Entries are keyed by
  // (video_id, client_profile, itag, auth_scope) and considered fresh
  // until `expires_at_ms - margin`. Only expiry or a real playback
  // failure (403) invalidates — no network probes on the hot path.

  void _createV2() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS stream_cache (
        video_id TEXT NOT NULL,
        client_profile TEXT NOT NULL DEFAULT '',
        itag INTEGER NOT NULL DEFAULT -1,
        url TEXT NOT NULL DEFAULT '',
        headers_json TEXT NOT NULL DEFAULT '{}',
        mime TEXT NOT NULL DEFAULT '',
        bitrate_kbps INTEGER NOT NULL DEFAULT 0,
        codec TEXT NOT NULL DEFAULT '',
        expires_at_ms INTEGER NOT NULL DEFAULT 0,
        cached_at_ms INTEGER NOT NULL DEFAULT 0,
        auth_scope TEXT NOT NULL DEFAULT 'anonymous',
        watchtime_url TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (video_id, client_profile, itag, auth_scope)
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_stream_cache_video
      ON stream_cache(video_id, cached_at_ms DESC);
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS match_cache (
        key TEXT PRIMARY KEY,
        video_id TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        artwork_url TEXT NOT NULL DEFAULT '',
        updated_at_ms INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  void _createV3() {
    try {
      _db.execute(
        'ALTER TABLE match_cache ADD COLUMN duration_seconds '
        'INTEGER NOT NULL DEFAULT 0;',
      );
    } catch (_) {}
  }

  void _createV4() {
    try {
      _db.execute('DELETE FROM match_cache;');
    } catch (_) {}
  }

  void _createV5() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS local_plays (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        played_at_millis INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_plays_recent
      ON local_plays(played_at_millis DESC);
    ''');
  }

  /// v6: pre-signed YT watchtime base on cached streams, so repeat
  /// plays (served from disk without a fresh player response) can
  /// still sync watch history with session-bound tokens.
  void _createV6() {
    try {
      _db.execute(
        'ALTER TABLE stream_cache ADD COLUMN watchtime_url '
        'TEXT NOT NULL DEFAULT \'\';',
      );
    } catch (_) {}
  }

  /// v7: tagging outcome per download (`full` / `text` / `raw:<reason>`)
  /// so untagged files are visible instead of silently bare, plus the
  /// `local_tracks` table for the on-device library scanner.
  void _createV7() {
    try {
      _db.execute(
        'ALTER TABLE downloaded_tracks ADD COLUMN tag_status '
        'TEXT NOT NULL DEFAULT \'\';',
      );
    } catch (_) {}
    _db.execute('''
      CREATE TABLE IF NOT EXISTS local_tracks (
        path TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        album_artist TEXT NOT NULL DEFAULT '',
        track_number INTEGER,
        disc_number INTEGER,
        year INTEGER,
        genre TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        bitrate INTEGER,
        sample_rate INTEGER,
        bit_depth INTEGER,
        size_bytes INTEGER,
        format TEXT NOT NULL DEFAULT '',
        artwork_path TEXT,
        has_embedded_art INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_tracks_album
      ON local_tracks(album_artist, album);
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_tracks_artist
      ON local_tracks(artist);
    ''');
  }

  /// v8: durable offline scrobble queue. Rows survive restarts (the old
  /// in-memory queue did not), so listens made offline are submitted once
  /// network and session recover. Timestamps are epoch seconds.
  void _createV8() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS offline_scrobbles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        artist TEXT NOT NULL,
        track TEXT NOT NULL,
        album TEXT NOT NULL DEFAULT '',
        album_artist TEXT NOT NULL DEFAULT '',
        timestamp INTEGER NOT NULL,
        duration INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_offline_scrobbles_created
      ON offline_scrobbles(created_at);
    ''');
  }

  // -- offline scrobble queue ----------------------------------------------

  /// Append one listened track to the offline queue ([timestamp] is the
  /// playback-start epoch second, UTC). Rows drain oldest-first.
  void insertOfflineScrobble({
    required String artist,
    required String track,
    String album = '',
    String albumArtist = '',
    required int timestamp,
    int duration = 0,
  }) {
    try {
      _db.execute(
        'INSERT INTO offline_scrobbles(artist, track, album, '
        'album_artist, timestamp, duration, created_at) '
        'VALUES(?, ?, ?, ?, ?, ?, ?);',
        [
          artist,
          track,
          album,
          albumArtist,
          timestamp,
          duration,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (_) {}
  }

  /// Oldest [limit] queued scrobbles in submission order (`created_at`,
  /// then `id` to break same-millisecond ties).
  List<Map<String, dynamic>> getPendingOfflineScrobbles({int limit = 50}) {
    try {
      return _db
          .select(
            'SELECT * FROM offline_scrobbles '
            'ORDER BY created_at ASC, id ASC LIMIT ?;',
            [limit],
          )
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Removes exactly the given rows; no-op on an empty list.
  void deleteOfflineScrobbles(List<int> ids) {
    if (ids.isEmpty) return;
    try {
      final placeholders = List.filled(ids.length, '?').join(', ');
      _db.execute(
        'DELETE FROM offline_scrobbles WHERE id IN ($placeholders);',
        ids,
      );
    } catch (_) {}
  }

  /// Rows waiting for submission.
  int countPendingOfflineScrobbles() {
    try {
      final rows =
          _db.select('SELECT COUNT(*) AS c FROM offline_scrobbles;');
      return (rows.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // -- local play log (keyless-guest taste) --------------------------------
  //
  // Every resolved track opening records one row (see PlaybackService),
  // capped at 500 newest. Same track replayed within 10 minutes is not
  // re-logged (repeat-one would spam). Powers affinities, discovery
  // seeds, jump-back-in and personal-mix seeds without any account.

  /// Max rows kept; oldest pruned on insert.
  static const int localPlaysCap = 500;

  void recordLocalPlay({required String title, required String artist}) {
    final t = title.trim();
    final a = artist.trim();
    if (t.isEmpty || a.isEmpty) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _db.select(
        'SELECT title, artist, played_at_millis FROM local_plays '
        'ORDER BY id DESC LIMIT 1;',
      );
      if (last.isNotEmpty) {
        final lt = (last.first['title'] as String?) ?? '';
        final la = (last.first['artist'] as String?) ?? '';
        final lat = (last.first['played_at_millis'] as int?) ?? 0;
        if (lt == t && la == a && now - lat < 10 * 60 * 1000) return;
      }
      _db.execute(
        'INSERT INTO local_plays (title, artist, played_at_millis) '
        'VALUES (?, ?, ?);',
        [t, a, now],
      );
      _db.execute(
        'DELETE FROM local_plays WHERE id NOT IN ('
        'SELECT id FROM local_plays ORDER BY id DESC LIMIT ?);',
        [localPlaysCap],
      );
    } catch (_) {}
  }

  List<({String title, String artist, int atMillis})> loadRecentPlays({
    int limit = 100,
  }) {
    try {
      return _db
          .select(
            'SELECT title, artist, played_at_millis FROM local_plays '
            'ORDER BY id DESC LIMIT ?;',
            [limit],
          )
          .map((r) => (
                title: (r['title'] as String?) ?? '',
                artist: (r['artist'] as String?) ?? '',
                atMillis:
                    (r['played_at_millis'] as int?) ?? 0,
              ))
          .where((p) => p.title.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // -- local tracks (library) ----------------------------------------------

  void insertOrUpdateLocalTracks(List<LocalTrack> tracks) {
    if (tracks.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (final track in tracks) {
        try {
          _db.execute(
            'INSERT INTO local_tracks(path, title, artist, album, album_artist, '
            'track_number, disc_number, year, genre, duration_ms, bitrate, '
            'sample_rate, bit_depth, size_bytes, format, artwork_path, '
            'has_embedded_art, modified_at) '
            'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(path) DO UPDATE SET '
            'title = excluded.title, artist = excluded.artist, '
            'album = excluded.album, album_artist = excluded.album_artist, '
            'track_number = excluded.track_number, '
            'disc_number = excluded.disc_number, year = excluded.year, '
            'genre = excluded.genre, duration_ms = excluded.duration_ms, '
            'bitrate = excluded.bitrate, sample_rate = excluded.sample_rate, '
            'bit_depth = excluded.bit_depth, size_bytes = excluded.size_bytes, '
            'format = excluded.format, artwork_path = excluded.artwork_path, '
            'has_embedded_art = excluded.has_embedded_art, '
            'modified_at = excluded.modified_at;',
            [
              track.path,
              track.title,
              track.artist,
              track.album,
              track.albumArtist,
              track.trackNumber,
              track.discNumber,
              track.year,
              track.genre,
              track.duration.inMilliseconds,
              track.bitrate,
              track.sampleRate,
              track.bitDepth,
              track.sizeBytes,
              track.format,
              track.artworkPath,
              track.hasEmbeddedArt ? 1 : 0,
              track.modifiedAt,
            ],
          );
        } catch (_) {}
      }
      _db.execute('COMMIT;');
    } catch (_) {
      try {
        _db.execute('ROLLBACK;');
      } catch (_) {}
    }
  }

  List<LocalTrack> getAllLocalTracks() {
    try {
      return _db
          .select(
            'SELECT * FROM local_tracks '
            'ORDER BY album_artist, album, COALESCE(track_number, 0), title;',
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Single track by its primary key ([path]); null when absent or on
  /// any read failure.
  LocalTrack? getLocalTrackByPath(String path) {
    try {
      final rows = _db.select(
        'SELECT * FROM local_tracks WHERE path = ? LIMIT 1;',
        [path],
      );
      if (rows.isEmpty) return null;
      return LocalTrack.fromMap(Map<String, dynamic>.from(rows.first));
    } catch (_) {
      return null;
    }
  }

  /// Fast path→modified_at lookup used by the scanner's delta-skip:
  /// only paths whose on-disk mtime still matches are eligible to be
  /// skipped without re-reading tags.
  Map<String, int> getLocalTrackTimestamps() {
    try {
      final rows = _db.select('SELECT path, modified_at FROM local_tracks;');
      return {
        for (final r in rows) r['path'] as String: (r['modified_at'] as int?) ?? 0,
      };
    } catch (_) {
      return const {};
    }
  }

  /// LIKE-pattern escape so user input containing `%`, `_` or `\`
  /// matches literally instead of acting as wildcards.
  static String _likeEscape(String s) => s
      .replaceAll('\\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Local-library search: case-insensitive LIKE match on title,
  /// artist or album. Exact title matches rank first, then
  /// title-prefix matches, then everything else; capped at [limit]
  /// rows (default 100).
  List<LocalTrack> searchLocalTracks(String query, {int limit = 100}) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final escaped = _likeEscape(q);
    final contains = '%$escaped%';
    final prefix = '$escaped%';
    try {
      return _db
          .select(
            r'''
            SELECT * FROM local_tracks
            WHERE title LIKE ? ESCAPE '\'
               OR artist LIKE ? ESCAPE '\'
               OR album LIKE ? ESCAPE '\'
            ORDER BY
              CASE
                WHEN title = ? COLLATE NOCASE THEN 0
                WHEN title LIKE ? ESCAPE '\' THEN 1
                ELSE 2
              END,
              artist, album, COALESCE(track_number, 0), title
            LIMIT ?;
          ''',
            [contains, contains, contains, q, prefix, limit],
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> getLocalAlbums() {
    try {
      return _db
          .select('''
        SELECT album, album_artist, year, artwork_path, COUNT(*) AS track_count
        FROM local_tracks
        GROUP BY album, album_artist, year, artwork_path
        ORDER BY album_artist, album;
      ''')
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// All tracks of one album, disc-order sorted ([disc_number] and
  /// [track_number] null-safed via COALESCE). Pass [albumArtist] to
  /// disambiguate same-named albums from different artists.
  List<LocalTrack> getLocalTracksForAlbum(
    String album, {
    String? albumArtist,
  }) {
    try {
      final query = (albumArtist != null && albumArtist.isNotEmpty)
          ? 'SELECT * FROM local_tracks WHERE album = ? AND album_artist = ? '
              'ORDER BY COALESCE(disc_number, 1), COALESCE(track_number, 0), title;'
          : 'SELECT * FROM local_tracks WHERE album = ? '
              'ORDER BY COALESCE(disc_number, 1), COALESCE(track_number, 0), title;';
      final args = (albumArtist != null && albumArtist.isNotEmpty)
          ? [album, albumArtist]
          : [album];
      return _db
          .select(query, args)
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// All tracks credited to [artist] (tag artist OR album artist),
  /// release-year desc, then album / disc-order / title.
  List<LocalTrack> getLocalTracksForArtist(String artist) {
    try {
      return _db
          .select(
            'SELECT * FROM local_tracks WHERE artist = ? OR album_artist = ? '
            'ORDER BY year DESC, album, COALESCE(track_number, 0), title;',
            [artist, artist],
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> getLocalArtists() {
    try {
      return _db
          .select('''
        SELECT artist, COUNT(*) AS track_count
        FROM local_tracks
        GROUP BY artist
        ORDER BY track_count DESC, artist;
      ''')
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void deleteLocalTracksNotIn(Set<String> validPaths) {
    try {
      if (validPaths.isEmpty) {
        _db.execute('DELETE FROM local_tracks;');
        return;
      }
      final placeholders = List.filled(validPaths.length, '?').join(', ');
      _db.execute(
        'DELETE FROM local_tracks WHERE path NOT IN ($placeholders);',
        validPaths.toList(),
      );
    } catch (_) {}
  }

  // -- local discovery queries ---------------------------------------------

  /// Collapses fragmented genre tags into unified display categories so
  /// collections aren't split across multiple cards (Rap/Hip Hop,
  /// Hip-Hop/Rap, Rap and Hip Hop all merge into 'Hip-Hop / Rap').
  static String canonicalizeGenre(String raw) {
    final g = raw.trim();
    final lower = g.toLowerCase();
    if (lower == 'rap/hip hop' ||
        lower == 'hip-hop/rap' ||
        lower == 'hip hop' ||
        lower == 'rap') {
      return 'Hip-Hop / Rap';
    }
    if (lower == 'r&b' ||
        lower == 'r&b/soul' ||
        lower == 'r&b / soul' ||
        lower == 'soul') {
      return 'R&B / Soul';
    }
    if (lower == 'alternative' ||
        lower == 'alternative & indie' ||
        lower == 'alternative rock') {
      return 'Alternative';
    }
    if (lower == 'dance-pop' || lower == 'dance pop') {
      return 'Dance-Pop';
    }
    return g;
  }

  /// Distinct non-blank genres, most tracks first (count DESC, then
  /// name ASC), with canonical families merged via [canonicalizeGenre].
  /// Rows: `genre`, `track_count`, `album_count` (distinct albums
  /// unioned across a family's aliases) and `artwork_path` (first
  /// non-empty MAX of the alias rows).
  List<Map<String, dynamic>> getLocalGenres() {
    try {
      // Per-alias tallies and a per-alias (genre, album) pair set; the
      // pair set makes the cross-alias album union a plain Dart set.
      final aliases = _db.select('''
        SELECT genre, COUNT(*) AS track_count, MAX(artwork_path) AS artwork_path
        FROM local_tracks WHERE genre IS NOT NULL AND TRIM(genre) != '' GROUP BY genre;
      ''');
      final pairs = _db.select('''
        SELECT DISTINCT genre, album
        FROM local_tracks WHERE genre IS NOT NULL AND TRIM(genre) != '';
      ''');

      final trackCounts = <String, int>{};
      final artwork = <String, String>{};
      final albums = <String, Set<String>>{};

      for (final row in aliases) {
        final canonical = canonicalizeGenre(row['genre'] as String);
        trackCounts[canonical] =
            (trackCounts[canonical] ?? 0) + (row['track_count'] as int);
        final path = row['artwork_path'] as String?;
        if (path != null && path.isNotEmpty) {
          artwork.putIfAbsent(canonical, () => path);
        }
      }
      for (final row in pairs) {
        final canonical = canonicalizeGenre(row['genre'] as String);
        final album = row['album'] as String?;
        if (album == null) continue;
        albums
            .putIfAbsent(canonical, () => <String>{})
            .add(album.toUpperCase());
      }

      final rows = [
        for (final canonical in trackCounts.keys)
          <String, dynamic>{
            'genre': canonical,
            'track_count': trackCounts[canonical],
            'album_count': albums[canonical]?.length ?? 0,
            'artwork_path': artwork[canonical],
          },
      ];
      rows.sort((a, b) {
        final byCount =
            (b['track_count'] as int).compareTo(a['track_count'] as int);
        if (byCount != 0) return byCount;
        return (a['genre'] as String).compareTo(b['genre'] as String);
      });
      return rows;
    } catch (_) {
      return const [];
    }
  }

  /// Decade buckets (year rounded down to the 10), newest first. Rows:
  /// `decade`, `track_count`. Years outside 1901-2099 and NULL are
  /// ignored.
  List<Map<String, dynamic>> getLocalDecades() {
    try {
      return _db
          .select('''
        SELECT (year / 10 * 10) AS decade, COUNT(*) AS track_count
        FROM local_tracks WHERE year IS NOT NULL AND year > 1900 AND year < 2100 GROUP BY decade ORDER BY decade DESC;
      ''')
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// File-format distribution, most tracks first. Rows: `format`,
  /// `track_count`.
  List<Map<String, dynamic>> getLocalFormatStats() {
    try {
      return _db
          .select('''
        SELECT format, COUNT(*) AS track_count FROM local_tracks GROUP BY format ORDER BY track_count DESC;
      ''')
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Album-name search: exact match ranks first, then prefix, then
  /// contains (case-insensitive LIKE). Rows: `album`, `album_artist`,
  /// `year`, `artwork_path` (MAX-aggregated) and `track_count`. Empty
  /// query → const [].
  List<Map<String, dynamic>> searchLocalAlbums(String query,
      {int limit = 10}) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final escaped = _likeEscape(q);
    final contains = '%$escaped%';
    final prefix = '$escaped%';
    try {
      return _db
          .select(
            r'''
            SELECT album, MAX(album_artist) AS album_artist, MAX(year) AS year, MAX(artwork_path) AS artwork_path, COUNT(*) AS track_count
            FROM local_tracks WHERE album LIKE ? ESCAPE '\' GROUP BY album
            ORDER BY CASE WHEN album = ? COLLATE NOCASE THEN 0 WHEN album LIKE ? ESCAPE '\' THEN 1 ELSE 2 END, track_count DESC, album
            LIMIT ?;
          ''',
            [contains, q, prefix, limit],
          )
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Artist-name search with the same exact/prefix/contains ranking as
  /// [searchLocalAlbums]. Rows: `artist`, `track_count` and
  /// `artwork_path` (MAX-aggregated). Empty query → const [].
  List<Map<String, dynamic>> searchLocalArtists(String query,
      {int limit = 10}) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final escaped = _likeEscape(q);
    final contains = '%$escaped%';
    final prefix = '$escaped%';
    try {
      return _db
          .select(
            r'''
            SELECT artist, COUNT(*) AS track_count, MAX(artwork_path) AS artwork_path
            FROM local_tracks WHERE artist LIKE ? ESCAPE '\' GROUP BY artist
            ORDER BY CASE WHEN artist = ? COLLATE NOCASE THEN 0 WHEN artist LIKE ? ESCAPE '\' THEN 1 ELSE 2 END, track_count DESC, artist
            LIMIT ?;
          ''',
            [contains, q, prefix, limit],
          )
          .map(Map<String, dynamic>.from)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Canonical genre families for [getLocalTracksForGenre]: the card
  /// drills carry the canonical name, so every stored alias of the
  /// family must match too (keys are lowercase canonical names).
  static const Map<String, List<String>> _genreAliases = {
    'hip-hop / rap': [
      'Hip-Hop / Rap',
      'Rap/Hip Hop',
      'Hip-Hop/Rap',
      'Rap',
      'Hip Hop',
    ],
    'r&b / soul': ['R&B / Soul', 'R&B', 'R&B/Soul', 'Soul'],
    'alternative': ['Alternative', 'Alternative & Indie', 'Alternative Rock'],
  };

  /// All tracks whose genre equals [genre] (trimmed, case-insensitive);
  /// blank and NULL genres never match. Canonical families match every
  /// alias in [_genreAliases]. Canonical album order.
  List<LocalTrack> getLocalTracksForGenre(String genre) {
    final g = genre.trim();
    final targets = _genreAliases[g.toLowerCase()] ?? [g];
    // One bound ? per target — a placeholder/arg count mismatch makes
    // the query silently return nothing.
    final placeholders = List.filled(targets.length, '?').join(', ');
    try {
      return _db
          .select(
            'SELECT * FROM local_tracks '
            "WHERE genre IS NOT NULL AND TRIM(genre) != '' "
            'AND TRIM(genre) COLLATE NOCASE IN ($placeholders) '
            'ORDER BY album_artist, album, COALESCE(track_number, 0), title;',
            targets,
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Tracks released in the inclusive [start]-[end] year range, newest
  /// year first, then canonical album order.
  List<LocalTrack> getLocalTracksForYearRange(int start, int end) {
    try {
      return _db
          .select(
            'SELECT * FROM local_tracks '
            'WHERE year IS NOT NULL AND year >= ? AND year <= ? '
            'ORDER BY year DESC, album_artist, album, '
            'COALESCE(track_number, 0), title;',
            [start, end],
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Tracks released in [decade] (e.g. 1980 covers 1980-1989).
  List<LocalTrack> getLocalTracksForDecade(int decade) {
    return getLocalTracksForYearRange(decade, decade + 9);
  }

  /// True hi-res: lossless formats above CD quality — sample rate over
  /// 48 kHz or more than 16 bits per sample. Rows whose stream props
  /// were never sniffed fall back to the legacy bitrate signal (over
  /// 1000 kbps) so pre-backfill libraries are not emptied; once the
  /// header backfill fills in rate/depth, that fallback no longer
  /// applies. Canonical album order.
  List<LocalTrack> getLocalHiResTracks() {
    try {
      return _db
          .select(
            r'''
            SELECT * FROM local_tracks
            WHERE format IN ('flac', 'alac', 'wav')
              AND (sample_rate > 48000 OR bit_depth > 16
                   OR (sample_rate IS NULL AND bit_depth IS NULL
                       AND bitrate > 1000))
            ORDER BY album_artist, album, COALESCE(track_number, 0), title;
          ''',
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // -- vault analytics ------------------------------------------------------

  /// Play totals (count + summed local durations) in the play log at or
  /// after [cutoffMs]. One bound `?` — keep the placeholder and arg
  /// counts in lockstep (a mismatch throws inside select()).
  ({int plays, int ms}) _playTotalsSince(int cutoffMs) {
    try {
      final rows = _db.select(
        'SELECT COUNT(*) AS plays, SUM(COALESCE(t.duration_ms, 0)) AS ms '
        'FROM local_plays p '
        'LEFT JOIN local_tracks t '
        'ON LOWER(TRIM(t.title)) = LOWER(TRIM(p.title)) '
        'AND LOWER(TRIM(t.artist)) = LOWER(TRIM(p.artist)) '
        'WHERE p.played_at_millis >= ?;',
        [cutoffMs],
      );
      if (rows.isEmpty) return (plays: 0, ms: 0);
      return (
        plays: (rows.first['plays'] as int?) ?? 0,
        ms: ((rows.first['ms'] as num?) ?? 0).toInt(),
      );
    } catch (_) {
      return (plays: 0, ms: 0);
    }
  }

  /// All local play rows (bounded by [localPlaysCap]).
  List<({String title, String artist, int atMillis})> _allPlayRows() {
    try {
      return _db
          .select('SELECT title, artist, played_at_millis FROM local_plays;')
          .map((r) => (
                title: (r['title'] as String?) ?? '',
                artist: (r['artist'] as String?) ?? '',
                atMillis: ((r['played_at_millis'] as num?) ?? 0).toInt(),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Case/trim-insensitive (artist, title) key for play-log matching.
  static String _playKey(String artist, String title) =>
      '${artist.trim().toLowerCase()}\u0000${title.trim().toLowerCase()}';

  /// Queued offline scrobbles that are NOT already represented in the
  /// play log (same artist + title within ±30 s). Timestamps are epoch
  /// seconds; durations seconds — both normalised to milliseconds.
  List<({String title, String artist, int atMillis, int durationMs})>
      _supplementScrobbles(
    List<({String title, String artist, int atMillis})> plays,
  ) {
    final result = <({String title, String artist, int atMillis, int durationMs})>[];
    try {
      final rows = _db.select(
        'SELECT artist, track, timestamp, duration FROM offline_scrobbles;',
      );
      final playTimes = <String, List<int>>{};
      for (final p in plays) {
        playTimes.putIfAbsent(_playKey(p.artist, p.title), () => []).add(
              p.atMillis,
            );
      }
      for (final r in rows) {
        final artist = (r['artist'] as String?) ?? '';
        final title = (r['track'] as String?) ?? '';
        final atMs = ((r['timestamp'] as num?)?.toInt() ?? 0) * 1000;
        final times = playTimes[_playKey(artist, title)];
        var duplicated = false;
        if (times != null) {
          for (final t in times) {
            if ((t - atMs).abs() <= 30000) {
              duplicated = true;
              break;
            }
          }
        }
        if (duplicated) continue;
        result.add((
          title: title,
          artist: artist,
          atMillis: atMs,
          durationMs: ((r['duration'] as num?)?.toInt() ?? 0) * 1000,
        ));
      }
    } catch (_) {}
    return result;
  }

  /// Top 10 played tracks with their local stream metadata (LEFT JOIN
  /// on the normalised title/artist; pure YouTube listens keep
  /// zeros/empty), folded with the deduped scrobble supplement. No
  /// bind parameters.
  List<VaultTopTrack> _topTracks(
    List<({String title, String artist, int atMillis, int durationMs})>
        scrobbles,
  ) {
    final merged = <String, VaultTopTrack>{};
    for (final t in _topTracksFromLog()) {
      merged[_playKey(t.artist, t.title)] = t;
    }
    for (final s in scrobbles) {
      final key = _playKey(s.artist, s.title);
      final existing = merged[key];
      merged[key] = existing == null
          ? VaultTopTrack(
              title: s.title,
              artist: s.artist,
              plays: 1,
              ms: s.durationMs,
            )
          : VaultTopTrack(
              title: existing.title,
              artist: existing.artist,
              plays: existing.plays + 1,
              ms: existing.ms + s.durationMs,
              artworkPath: existing.artworkPath,
              format: existing.format,
              sampleRate: existing.sampleRate,
              bitDepth: existing.bitDepth,
            );
    }
    final list = merged.values.toList()
      ..sort((a, b) {
        final byPlays = b.plays.compareTo(a.plays);
        return byPlays != 0 ? byPlays : a.title.compareTo(b.title);
      });
    return list.length > 10 ? list.sublist(0, 10) : list;
  }

  List<VaultTopTrack> _topTracksFromLog() {
    try {
      return _db
          .select(
            'SELECT p.title AS title, p.artist AS artist, '
            'COUNT(*) AS plays, '
            'MAX(t.artwork_path) AS artwork_path, '
            'MAX(t.format) AS format, '
            'MAX(t.sample_rate) AS sample_rate, '
            'MAX(t.bit_depth) AS bit_depth, '
            'SUM(COALESCE(t.duration_ms, 0)) AS ms '
            'FROM local_plays p '
            'LEFT JOIN local_tracks t '
            'ON LOWER(TRIM(t.title)) = LOWER(TRIM(p.title)) '
            'AND LOWER(TRIM(t.artist)) = LOWER(TRIM(p.artist)) '
            'GROUP BY p.title, p.artist '
            'ORDER BY plays DESC, p.title ASC;',
          )
          .map((r) => VaultTopTrack(
                title: (r['title'] as String?) ?? '',
                artist: (r['artist'] as String?) ?? '',
                plays: (r['plays'] as int?) ?? 0,
                ms: ((r['ms'] as num?) ?? 0).toInt(),
                artworkPath: r['artwork_path'] as String?,
                format: (r['format'] as String?) ?? '',
                sampleRate: (r['sample_rate'] as int?) ?? 0,
                bitDepth: (r['bit_depth'] as int?) ?? 0,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Top 5 played artists, folded with the deduped scrobble supplement.
  /// No bind parameters.
  List<VaultTopArtist> _topArtists(
    List<({String title, String artist, int atMillis, int durationMs})>
        scrobbles,
  ) {
    final merged = <String, VaultTopArtist>{};
    for (final a in _topArtistsFromLog()) {
      merged[a.artist] = a;
    }
    for (final s in scrobbles) {
      final existing = merged[s.artist];
      merged[s.artist] = existing == null
          ? VaultTopArtist(artist: s.artist, plays: 1)
          : VaultTopArtist(artist: s.artist, plays: existing.plays + 1);
    }
    final list = merged.values.toList()
      ..sort((a, b) {
        final byPlays = b.plays.compareTo(a.plays);
        return byPlays != 0 ? byPlays : a.artist.compareTo(b.artist);
      });
    return list.length > 5 ? list.sublist(0, 5) : list;
  }

  List<VaultTopArtist> _topArtistsFromLog() {
    try {
      return _db
          .select(
            'SELECT artist, COUNT(*) AS plays FROM local_plays '
            'GROUP BY artist ORDER BY plays DESC, artist ASC;',
          )
          .map((r) => VaultTopArtist(
                artist: (r['artist'] as String?) ?? '',
                plays: (r['plays'] as int?) ?? 0,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Play counts per local hour (length 24), from the play log.
  List<int> _hourlyPlays() {
    final hourly = List<int>.filled(24, 0);
    try {
      final rows = _db.select(
        "SELECT CAST(strftime('%H', played_at_millis / 1000, "
        "'unixepoch', 'localtime') AS INTEGER) AS h, COUNT(*) AS c "
        'FROM local_plays GROUP BY h;',
      );
      for (final r in rows) {
        final h = ((r['h'] as num?) ?? 0).toInt();
        if (h >= 0 && h < 24) hourly[h] += (r['c'] as int?) ?? 0;
      }
    } catch (_) {}
    return hourly;
  }

  /// Consecutive local play-days ending today (0 when today has no
  /// play). A "day" is a local-calendar date; gaps break the streak.
  int _streakDays(
    List<({String title, String artist, int atMillis, int durationMs})>
        scrobbles,
  ) {
    final days = <int>{};
    try {
      final rows =
          _db.select('SELECT DISTINCT played_at_millis FROM local_plays;');
      for (final r in rows) {
        final ms = ((r['played_at_millis'] as num?) ?? 0).toInt();
        if (ms > 0) days.add(_localDayKey(ms));
      }
    } catch (_) {}
    for (final s in scrobbles) {
      if (s.atMillis > 0) days.add(_localDayKey(s.atMillis));
    }
    final now = DateTime.now();
    var day = DateTime(now.year, now.month, now.day);
    var streak = 0;
    while (days.contains(day.millisecondsSinceEpoch) && streak < 3660) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return streak;
  }

  static int _localDayKey(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  static int _minutesFromMs(int ms) => ms <= 0 ? 0 : (ms / 60000).round();

  /// Aggregates the local play log plus not-yet-submitted offline
  /// scrobbles into the Vault page numbers. Every query is individually
  /// guarded — a failure degrades to zero/empty, never throws, and a
  /// missing optional column can never blank the whole result.
  VaultAnalytics loadVaultAnalytics() {
    final now = DateTime.now();
    final monthStartMs =
        DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
    final weekStartMs =
        now.millisecondsSinceEpoch - const Duration(days: 7).inMilliseconds;

    // Play totals per window (local log), then the scrobble supplement.
    final all = _playTotalsSince(0);
    final month = _playTotalsSince(monthStartMs);
    final week = _playTotalsSince(weekStartMs);
    var allPlays = all.plays;
    var allMs = all.ms;
    var monthMs = month.ms;
    var weekMs = week.ms;

    final plays = _allPlayRows();
    final scrobbles = _supplementScrobbles(plays);
    final hourly = _hourlyPlays();
    for (final s in scrobbles) {
      if (s.atMillis >= 0) {
        allPlays++;
        allMs += s.durationMs;
      }
      if (s.atMillis >= monthStartMs) {
        monthMs += s.durationMs;
      }
      if (s.atMillis >= weekStartMs) {
        weekMs += s.durationMs;
      }
      if (s.atMillis > 0) {
        hourly[DateTime.fromMillisecondsSinceEpoch(s.atMillis).hour] += 1;
      }
    }

    // Library fidelity. `hires` mirrors [getLocalHiResTracks]: lossless
    // formats above CD quality only.
    var lossless = 0;
    var lossy = 0;
    var total = 0;
    try {
      final rows = _db.select(
        'SELECT format, COUNT(*) AS c FROM local_tracks GROUP BY format;',
      );
      for (final r in rows) {
        final format = ((r['format'] as String?) ?? '').toLowerCase();
        final c = (r['c'] as int?) ?? 0;
        total += c;
        if (format == 'flac' || format == 'alac' || format == 'wav') {
          lossless += c;
        } else if (const {
          'mp3',
          'aac',
          'ogg',
          'opus',
          'm4a',
          'wma',
        }.contains(format)) {
          lossy += c;
        }
      }
    } catch (_) {}

    var hires = 0;
    try {
      final rows = _db.select(
        "SELECT COUNT(*) AS c FROM local_tracks "
        "WHERE format IN ('flac', 'alac', 'wav') "
        'AND (sample_rate > 48000 OR bit_depth > 16);',
      );
      hires = (rows.first['c'] as int?) ?? 0;
    } catch (_) {}

    final topSampleRates = <Map<String, int>>[];
    try {
      final rows = _db.select(
        'SELECT sample_rate, COUNT(*) AS c FROM local_tracks '
        'WHERE sample_rate > 0 GROUP BY sample_rate '
        'ORDER BY c DESC, sample_rate DESC LIMIT 4;',
      );
      for (final r in rows) {
        topSampleRates.add(<String, int>{
          'sample_rate': ((r['sample_rate'] as num?) ?? 0).toInt(),
          'count': (r['c'] as int?) ?? 0,
        });
      }
    } catch (_) {}

    return VaultAnalytics(
      allTimeMinutes: _minutesFromMs(allMs),
      monthMinutes: _minutesFromMs(monthMs),
      weekMinutes: _minutesFromMs(weekMs),
      allTimePlays: allPlays,
      topTracks: _topTracks(scrobbles),
      topArtists: _topArtists(scrobbles),
      losslessCount: lossless,
      lossyCount: lossy,
      hiresCount: hires,
      totalCount: total,
      hourlyPlays: hourly,
      streakDays: _streakDays(scrobbles),
      topSampleRates: topSampleRates,
    );
  }

  /// Most recently modified local tracks, newest first, capped at
  /// [limit] rows (default 200).
  List<LocalTrack> getLocalRecentTracks({int limit = 200}) {
    try {
      return _db
          .select(
            'SELECT * FROM local_tracks ORDER BY modified_at DESC LIMIT ?;',
            [limit],
          )
          .map((r) => LocalTrack.fromMap(Map<String, dynamic>.from(r)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, Object?>> loadStreamEntries({int limit = 256}) {
    try {
      // watchtime_url may be absent on pre-v6 rows if the migration
      // was skipped: fall back to the v5 column list.
      try {
        return _db
            .select(
              'SELECT video_id, client_profile, itag, url, headers_json, '
              'mime, bitrate_kbps, codec, expires_at_ms, cached_at_ms, '
              'auth_scope, watchtime_url FROM stream_cache '
              'ORDER BY cached_at_ms DESC LIMIT ?;',
              [limit],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      } catch (_) {
        return _db
            .select(
              'SELECT video_id, client_profile, itag, url, headers_json, '
              'mime, bitrate_kbps, codec, expires_at_ms, cached_at_ms, '
              'auth_scope FROM stream_cache '
              'ORDER BY cached_at_ms DESC LIMIT ?;',
              [limit],
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      }
    } catch (_) {
      return const [];
    }
  }

  void saveStreamEntry({
    required String videoId,
    required String clientProfile,
    required int itag,
    required String url,
    required String headersJson,
    required String mime,
    required int bitrateKbps,
    required String codec,
    required int expiresAtMs,
    required int cachedAtMs,
    required String authScope,
    String watchtimeUrl = '',
  }) {
    try {
      // v6 column when migrated; plain v5 insert otherwise.
      try {
        _db.execute(
          'INSERT INTO stream_cache(video_id, client_profile, itag, url, '
          'headers_json, mime, bitrate_kbps, codec, expires_at_ms, '
          'cached_at_ms, auth_scope, watchtime_url) '
          'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(video_id, client_profile, itag, auth_scope) '
          'DO UPDATE SET url = excluded.url, '
          'headers_json = excluded.headers_json, mime = excluded.mime, '
          'bitrate_kbps = excluded.bitrate_kbps, codec = excluded.codec, '
          'expires_at_ms = excluded.expires_at_ms, '
          'cached_at_ms = excluded.cached_at_ms, '
          'watchtime_url = excluded.watchtime_url;',
          [
            videoId,
            clientProfile,
            itag,
            url,
            headersJson,
            mime,
            bitrateKbps,
            codec,
            expiresAtMs,
            cachedAtMs,
            authScope,
            watchtimeUrl,
          ],
        );
      } catch (_) {
        _db.execute(
          'INSERT INTO stream_cache(video_id, client_profile, itag, url, '
          'headers_json, mime, bitrate_kbps, codec, expires_at_ms, '
          'cached_at_ms, auth_scope) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(video_id, client_profile, itag, auth_scope) '
          'DO UPDATE SET url = excluded.url, '
          'headers_json = excluded.headers_json, mime = excluded.mime, '
          'bitrate_kbps = excluded.bitrate_kbps, codec = excluded.codec, '
          'expires_at_ms = excluded.expires_at_ms, '
          'cached_at_ms = excluded.cached_at_ms;',
          [
            videoId,
            clientProfile,
            itag,
            url,
            headersJson,
            mime,
            bitrateKbps,
            codec,
            expiresAtMs,
            cachedAtMs,
            authScope,
          ],
        );
      }
      _db.execute(
        'DELETE FROM stream_cache WHERE rowid NOT IN ('
        'SELECT rowid FROM stream_cache '
        'ORDER BY cached_at_ms DESC LIMIT 256);',
      );
    } catch (_) {}
  }

  void deleteStreamEntries(String videoId) {
    try {
      _db.execute(
        'DELETE FROM stream_cache WHERE video_id = ?;',
        [videoId],
      );
    } catch (_) {}
  }

  void pruneExpiredStreams(int nowMs) {
    try {
      _db.execute(
        'DELETE FROM stream_cache WHERE expires_at_ms > 0 AND expires_at_ms < ?;',
        [nowMs],
      );
    } catch (_) {}
  }

  Map<String, Object?>? loadMatchEntry(String key) {
    try {
      final rows = _db.select(
        'SELECT key, video_id, title, artist, album, artwork_url, '
        'duration_seconds, updated_at_ms FROM match_cache WHERE key = ?;',
        [key],
      );
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  void saveMatchEntry({
    required String key,
    required String videoId,
    required String title,
    required String artist,
    String album = '',
    String artworkUrl = '',
    int durationSeconds = 0,
  }) {
    try {
      _db.execute(
        'INSERT INTO match_cache(key, video_id, title, artist, album, '
        'artwork_url, duration_seconds, updated_at_ms) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(key) DO UPDATE SET video_id = excluded.video_id, '
        'title = excluded.title, artist = excluded.artist, '
        'album = excluded.album, artwork_url = excluded.artwork_url, '
        'duration_seconds = excluded.duration_seconds, '
        'updated_at_ms = excluded.updated_at_ms;',
        [
          key,
          videoId,
          title,
          artist,
          album,
          artworkUrl,
          durationSeconds,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      _db.execute(
        'DELETE FROM match_cache WHERE key NOT IN ('
        'SELECT key FROM match_cache '
        'ORDER BY updated_at_ms DESC LIMIT 1024);',
      );
    } catch (_) {}
  }

  void deleteMatchesForVideo(String videoId) {
    try {
      _db.execute(
        'DELETE FROM match_cache WHERE video_id = ?;',
        [videoId],
      );
    } catch (_) {}
  }

  // -- artwork cache ---------------------------------------------------

  Map<String, String>? loadArtworkEntry(String cacheKey) {
    try {
      final rows = _db.select(
        'SELECT url, provider FROM artwork_cache WHERE cache_key = ?;',
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      return {
        'url': rows.first['url'] as String,
        'provider': rows.first['provider'] as String,
      };
    } catch (_) {
      return null;
    }
  }

  /// Same row as [loadArtworkEntry], plus [timestamp_millis] for TTL.
  Map<String, dynamic>? loadArtworkRecord(String cacheKey) {
    try {
      final rows = _db.select(
        'SELECT url, provider, timestamp_millis FROM artwork_cache '
        'WHERE cache_key = ?;',
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      return {
        'url': rows.first['url'] as String,
        'provider': rows.first['provider'] as String,
        'timestamp_millis':
            (rows.first['timestamp_millis'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  void saveArtworkEntry({
    required String cacheKey,
    required String url,
    String provider = 'official',
  }) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      _db.execute(
        'INSERT INTO artwork_cache(cache_key, url, provider, timestamp_millis) '
        'VALUES(?, ?, ?, ?) '
        'ON CONFLICT(cache_key) DO UPDATE SET '
        'url = excluded.url, '
        'provider = excluded.provider, '
        'timestamp_millis = excluded.timestamp_millis;',
        [cacheKey, url, provider, now],
      );
    } catch (_) {}
  }

  void close() => _db.close();
}
