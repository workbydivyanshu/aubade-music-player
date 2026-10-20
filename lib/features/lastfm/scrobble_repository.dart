import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart';
import 'auth_repository.dart';

/// Scrobble result classification.
enum ScrobbleOutcome { success, queued, noSession, failed }

/// Last.fm scrobbling repository.
///
/// Ported from Kotlin LastWave `data/repository/ScrobbleRepository.kt`:
/// - `track.updateNowPlaying` (deduped) + `track.scrobble`
/// - `track.love` / `track.unlove`
/// - write cooldown + durable offline queue (SQLite `offline_scrobbles`,
///   drained oldest-first on reconnect or the next scrobble)
class ScrobbleRepository {
  final LastFmApiService _api;
  final Prefs _prefs;
  final AppDatabase _db;

  String _lastNowPlayingKey = '';
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);

  /// Rows drained per POST during a flush.
  static const int _flushBatchSize = 50;

  /// Whole-flush row cap: one reconnect must not fire an unbounded
  /// burst of scrobble batches. Leftovers wait for the next flush.
  static const int _flushRowCap = 500;

  ScrobbleRepository(this._api, this._prefs, this._db);

  String get _apiKey => _prefs.lastFmApiKey;
  String get _apiSecret => _prefs.lastFmApiSecret;
  String get _sessionKey => _prefs.sessionKey;

  bool get _canWrite =>
      _prefs.isLastFmConfigured && _sessionKey.isNotEmpty;

  /// Last.fm error 9 = invalid session key. The stored session is dead,
  /// so drop it locally through the same persister the auth flow uses;
  /// callers then return [ScrobbleOutcome.noSession] without queueing.
  Future<void> _signOutLocally() async {
    try {
      await _prefs.signOut();
    } catch (_) {}
  }

  static bool _isInvalidSession(Map<String, dynamic> json) =>
      (json['error'] as num?)?.toInt() == 9;

  Future<Map<String, String>> _signed(
    String method,
    Map<String, String> extra,
  ) async {
    // Drop empty values so the POST body and the signed string agree
    // (server includes only sent params; sending `album=` while signing
    // without it yields error 13).
    final filteredExtra = {
      for (final e in extra.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    final params = {
      'method': method,
      'api_key': _apiKey,
      'sk': _sessionKey,
      ...filteredExtra,
    };
    return {
      ...params,
      'api_sig': LastFmSigner.sign(params, _apiSecret),
      'format': 'json',
    };
  }

  Future<void> _paceWrites() async {
    final elapsed = DateTime.now().difference(_lastWrite);
    if (elapsed < const Duration(milliseconds: 700)) {
      await Future<void>.delayed(
          const Duration(milliseconds: 700) - elapsed);
    }
    _lastWrite = DateTime.now();
  }

  Future<ScrobbleOutcome> updateNowPlaying({
    required String artist,
    required String track,
    String album = '',
    String albumArtist = '',
    int durationSec = 0,
  }) async {
    if (!_prefs.scrobblerEnabled ||
        !_prefs.scrobbleNowPlaying ||
        !_canWrite) {
      return ScrobbleOutcome.noSession;
    }
    final key = '${artist.toLowerCase()}|${track.toLowerCase()}';
    if (key == _lastNowPlayingKey) return ScrobbleOutcome.success;
    _lastNowPlayingKey = key;
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        'track.updateNowPlaying',
        {
          'artist': artist,
          'track': track,
          if (album.isNotEmpty) 'album': album,
          if (albumArtist.isNotEmpty) 'albumArtist': albumArtist,
          if (durationSec > 0) 'duration': durationSec.toString(),
        },
      ));
      if (json.containsKey('error')) {
        if (_isInvalidSession(json)) {
          await _signOutLocally();
          return ScrobbleOutcome.noSession;
        }
        return ScrobbleOutcome.failed;
      }
      return ScrobbleOutcome.success;
    } catch (_) {
      return ScrobbleOutcome.failed;
    }
  }

  /// Scrobble a fully-played track. `timestampSec` = playback start (UTC).
  Future<ScrobbleOutcome> scrobble({
    required String artist,
    required String track,
    String album = '',
    String albumArtist = '',
    required int timestampSec,
    int durationSec = 0,
  }) async {
    if (!_prefs.scrobblerEnabled) return ScrobbleOutcome.noSession;
    if (!_canWrite) {
      _db.insertOfflineScrobble(
        artist: artist,
        track: track,
        album: album,
        albumArtist: albumArtist,
        timestamp: timestampSec,
        duration: durationSec,
      );
      return ScrobbleOutcome.queued;
    }
    // Draining first may discover a dead session (error 9): the flush
    // signs out and reports it, and this call must not queue more work.
    if (await flushQueue() == ScrobbleOutcome.noSession) {
      return ScrobbleOutcome.noSession;
    }
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        'track.scrobble',
        {
          'artist[0]': artist,
          'track[0]': track,
          'timestamp[0]': timestampSec.toString(),
          if (album.isNotEmpty) 'album[0]': album,
          if (albumArtist.isNotEmpty) 'albumArtist[0]': albumArtist,
          if (durationSec > 0) 'duration[0]': durationSec.toString(),
        },
      ));
      if (json.containsKey('error')) {
        final code = (json['error'] as num?)?.toInt();
        if (code == 9) {
          await _signOutLocally();
          return ScrobbleOutcome.noSession;
        }
        if (code == 29 || code == 11 || code == 16) {
          _db.insertOfflineScrobble(
            artist: artist,
            track: track,
            album: album,
            albumArtist: albumArtist,
            timestamp: timestampSec,
            duration: durationSec,
          );
          return ScrobbleOutcome.queued;
        }
        return ScrobbleOutcome.failed;
      }
      return ScrobbleOutcome.success;
    } catch (_) {
      _db.insertOfflineScrobble(
        artist: artist,
        track: track,
        album: album,
        albumArtist: albumArtist,
        timestamp: timestampSec,
        duration: durationSec,
      );
      return ScrobbleOutcome.queued;
    }
  }

  Future<bool> setLoved({
    required String artist,
    required String track,
    required bool loved,
  }) async {
    if (!_canWrite) return false;
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        loved ? 'track.love' : 'track.unlove',
        {'artist': artist, 'track': track},
      ));
      return !json.containsKey('error');
    } catch (_) {
      return false;
    }
  }

  /// Drain persisted offline scrobbles oldest-first, one signed batch
  /// POST per [_flushBatchSize] rows (indexed `artist[i]` fields), capped
  /// at [_flushRowCap] rows per call. Rows are deleted only after Last.fm
  /// accepts the batch; a refused batch or a dead session (error 9)
  /// leaves the rest queued for the next attempt.
  Future<ScrobbleOutcome> flushQueue() async {
    if (!_canWrite) return ScrobbleOutcome.noSession;
    var attempted = 0;
    while (attempted < _flushRowCap) {
      final pending = _db.getPendingOfflineScrobbles(limit: _flushBatchSize);
      if (pending.isEmpty) return ScrobbleOutcome.success;
      final ids = <int>[];
      final fields = <String, String>{};
      for (var i = 0; i < pending.length; i++) {
        final row = pending[i];
        ids.add((row['id'] as num).toInt());
        fields['artist[$i]'] = (row['artist'] as String?) ?? '';
        fields['track[$i]'] = (row['track'] as String?) ?? '';
        fields['timestamp[$i]'] =
            ((row['timestamp'] as num?)?.toInt() ?? 0).toString();
        // Optional fields go out (and get signed) only when non-empty —
        // `_signed` drops empties so body and signature always agree.
        final album = (row['album'] as String?) ?? '';
        if (album.isNotEmpty) fields['album[$i]'] = album;
        final albumArtist = (row['album_artist'] as String?) ?? '';
        if (albumArtist.isNotEmpty) fields['albumArtist[$i]'] = albumArtist;
        final duration = (row['duration'] as num?)?.toInt() ?? 0;
        if (duration > 0) fields['duration[$i]'] = duration.toString();
      }
      try {
        await _paceWrites();
        final json = await _api.post(await _signed('track.scrobble', fields));
        if (json.containsKey('error')) {
          if (_isInvalidSession(json)) {
            await _signOutLocally();
            return ScrobbleOutcome.noSession;
          }
          // Server refused the batch: keep the rows for a later retry.
          return ScrobbleOutcome.queued;
        }
      } catch (_) {
        return ScrobbleOutcome.queued;
      }
      _db.deleteOfflineScrobbles(ids);
      attempted += ids.length;
    }
    return ScrobbleOutcome.success;
  }

  int get queuedCount => _db.countPendingOfflineScrobbles();
}

final scrobbleRepositoryProvider = Provider<ScrobbleRepository>((ref) {
  return ScrobbleRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(prefsProvider),
    ref.watch(databaseProvider),
  );
});
