import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_factory.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart' show databaseProvider;
import '../updater/update_service.dart' show kFallbackAppVersion;

/// One listen to send: what played and when it started (UTC seconds).
@immutable
class Listen {
  final String artist;
  final String track;
  final String album;
  final int startedAtSec;

  const Listen({
    required this.artist,
    required this.track,
    this.album = '',
    this.startedAtSec = 0,
  });
}

/// Scrobble services besides Last.fm. Each is independent: its own
/// connection, its own durable offline queue, and a failure in one
/// never holds up another (or Last.fm).
abstract class ExtraScrobbler {
  /// Shown in Settings and Vault.
  String get name;

  /// Lowercase service key stored in the database ('listenbrainz', 'librefm').
  String get serviceKey;

  bool get connected;
  String get username;
  Future<bool> nowPlaying(Listen l);
  Future<bool> submit(Listen l);

  /// Lifetime listens on the service, or null when unavailable.
  Future<int?> listenCount();

  /// The user's profile page.
  Uri get profileUrl;
}

// -- ListenBrainz -------------------------------------------------------------

/// ListenBrainz (or any server speaking its API: Maloja, Koito, …).
/// Auth is the user token from listenbrainz.org/settings.
class ListenBrainzScrobbler implements ExtraScrobbler {
  ListenBrainzScrobbler(this._prefs, this._dio);
  final Prefs _prefs;
  final Dio _dio;

  static const defaultServer = 'https://api.listenbrainz.org';

  @override
  String get name => 'ListenBrainz';

  @override
  String get serviceKey => 'listenbrainz';

  @override
  bool get connected => _prefs.listenBrainzToken.isNotEmpty;

  @override
  String get username => _prefs.listenBrainzUser;

  String get _base => normalizeServer(_prefs.listenBrainzServer, defaultServer);

  Options _auth(String token) => Options(
        headers: {
          'Authorization': 'Token $token',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      );

  /// Checks [token] against [server] and stores it with the user name.
  /// Returns null on success, else the reason.
  Future<String?> connect(String token, {String server = ''}) async {
    final t = token.trim();
    if (t.isEmpty) return 'Paste your user token.';
    final base = normalizeServer(server, defaultServer);
    try {
      final res = await _dio.get<dynamic>(
        '$base/1/validate-token',
        options: _auth(t),
      );
      final body = res.data;
      final valid = body is Map && body['valid'] == true;
      if (!valid) {
        return (res.statusCode ?? 0) == 0
            ? 'Could not reach $base.'
            : 'The token was not accepted.';
      }
      await _prefs.setListenBrainz(
        token: t,
        user: body['user_name']?.toString() ?? '',
        server: server.trim(),
      );
      return null;
    } catch (_) {
      return 'Could not reach $base.';
    }
  }

  Future<void> disconnect() =>
      _prefs.setListenBrainz(token: '', user: '', server: '');

  Map<String, Object?> _metadata(Listen l) => {
        'artist_name': l.artist,
        'track_name': l.track,
        if (l.album.isNotEmpty) 'release_name': l.album,
        'additional_info': {
          'media_player': 'Aubade',
          'submission_client': 'Aubade Desktop',
          'submission_client_version': kFallbackAppVersion,
        },
      };

  Future<bool> _post(String type, Listen l) async {
    if (!connected) return false;
    try {
      final res = await _dio.post<dynamic>(
        '$_base/1/submit-listens',
        data: jsonEncode({
          'listen_type': type,
          'payload': [
            {
              if (type == 'single') 'listened_at': l.startedAtSec,
              'track_metadata': _metadata(l),
            },
          ],
        }),
        options: _auth(_prefs.listenBrainzToken),
      );
      return (res.statusCode ?? 0) ~/ 100 == 2;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> nowPlaying(Listen l) => _post('playing_now', l);

  @override
  Future<bool> submit(Listen l) => _post('single', l);

  @override
  Future<int?> listenCount() async {
    if (!connected || username.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(
        '$_base/1/user/${Uri.encodeComponent(username)}/listen-count',
        options: _auth(_prefs.listenBrainzToken),
      );
      final data = res.data;
      final payload = data is Map ? data['payload'] : null;
      final count = payload is Map ? payload['count'] : null;
      return count is num ? count.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Uri get profileUrl {
    final base = _base;
    final site = base == defaultServer ? 'https://listenbrainz.org' : base;
    return Uri.parse('$site/user/${Uri.encodeComponent(username)}/');
  }
}

// -- Libre.fm -------------------------------------------------------------------

/// Libre.fm (or any GNU FM server): the Last.fm 2.0 protocol at another
/// address, with a mobile session from username + password.
class LibreFmScrobbler implements ExtraScrobbler {
  LibreFmScrobbler(this._prefs, this._dio);
  final Prefs _prefs;
  final Dio _dio;

  static const defaultServer = 'https://libre.fm';

  // GNU FM does not issue API keys: any 32-character key/secret pair is
  // accepted, but requests must still be signed with it.
  static const _apiKey = 'aubadedesktop00000000000000000';
  static const _apiSecret = 'aubadedesktopsecret00000000000';

  @override
  String get name => 'Libre.fm';

  @override
  String get serviceKey => 'librefm';

  @override
  bool get connected => _prefs.libreFmSession.isNotEmpty;

  @override
  String get username => _prefs.libreFmUser;

  String get _endpoint =>
      '${normalizeServer(_prefs.libreFmServer, defaultServer)}/2.0/';

  @visibleForTesting
  static String sign(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format').toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf
        ..write(k)
        ..write(params[k]);
    }
    buf.write(secret);
    return md5.convert(utf8.encode(buf.toString())).toString();
  }

  Future<Map<String, dynamic>?> _call(
    String endpoint,
    Map<String, String> params,
  ) async {
    final signed = {
      ...params,
      'api_key': _apiKey,
    };
    signed['api_sig'] = sign(signed, _apiSecret);
    signed['format'] = 'json';
    try {
      final res = await _dio.post<dynamic>(
        endpoint,
        data: signed,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = jsonDecode('${res.data ?? '{}'}');
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (_) {
      return null;
    }
  }

  /// Signs in and stores the session. Null on success, else the reason.
  Future<String?> connect(
    String user,
    String password, {
    String server = '',
  }) async {
    final u = user.trim();
    if (u.isEmpty || password.isEmpty) return 'Enter your username and password.';
    final base = normalizeServer(server, defaultServer);
    // GNU FM's mobile session token: md5(username + md5(password)).
    final token = md5
        .convert(utf8.encode(u.toLowerCase() +
            md5.convert(utf8.encode(password)).toString()))
        .toString();
    final body = await _call('$base/2.0/', {
      'method': 'auth.getMobileSession',
      'username': u,
      'authToken': token,
    });
    if (body == null) return 'Could not reach $base.';
    final key = body['session'] is Map ? body['session']['key'] : null;
    if (key is! String || key.isEmpty) {
      return body['message']?.toString() ?? 'Sign-in was not accepted.';
    }
    final name =
        body['session'] is Map ? '${body['session']['name'] ?? u}' : u;
    await _prefs.setLibreFm(session: key, user: name, server: server.trim());
    return null;
  }

  Future<void> disconnect() =>
      _prefs.setLibreFm(session: '', user: '', server: '');

  Future<bool> _write(String method, Map<String, String> extra) async {
    if (!connected) return false;
    final body = await _call(_endpoint, {
      'method': method,
      'sk': _prefs.libreFmSession,
      for (final e in extra.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    });
    return body != null && !body.containsKey('error');
  }

  @override
  Future<bool> nowPlaying(Listen l) => _write('track.updateNowPlaying', {
        'artist': l.artist,
        'track': l.track,
        'album': l.album,
      });

  @override
  Future<bool> submit(Listen l) => _write('track.scrobble', {
        'artist[0]': l.artist,
        'track[0]': l.track,
        'album[0]': l.album,
        'timestamp[0]': '${l.startedAtSec}',
      });

  @override
  Future<int?> listenCount() async {
    if (!connected || username.isEmpty) return null;
    final body = await _call(_endpoint, {
      'method': 'user.getInfo',
      'user': username,
    });
    final raw = body?['user'] is Map ? body!['user']['playcount'] : null;
    return raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  }

  @override
  Uri get profileUrl => Uri.parse(
      '${normalizeServer(_prefs.libreFmServer, defaultServer)}/user/${Uri.encodeComponent(username)}');
}

/// `https://host[:port][/path]` without a trailing slash; [fallback] when
/// blank. A bare host gets https.
String normalizeServer(String raw, String fallback) {
  var s = raw.trim();
  if (s.isEmpty) return fallback;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

// -- fan-out & durable queue --------------------------------------------------

/// Sends every listen to each connected service. Failed submits are
/// stored durably in [AppDatabase] per service and drained oldest-first.
class ExtraScrobblers {
  ExtraScrobblers(this.services, this._db);
  final List<ExtraScrobbler> services;
  final AppDatabase _db;

  void nowPlaying(Listen l) {
    for (final s in services) {
      if (s.connected) unawaited(s.nowPlaying(l));
    }
  }

  void submit(Listen l) {
    for (final s in services) {
      if (!s.connected) continue;
      _db.insertOfflineScrobble(
        service: s.serviceKey,
        artist: l.artist,
        track: l.track,
        album: l.album,
        timestamp: l.startedAtSec,
      );
      unawaited(_drainQueue(s));
    }
  }

  Future<void> flushAll() async {
    for (final s in services) {
      if (s.connected) await _drainQueue(s);
    }
  }

  Future<void> _drainQueue(ExtraScrobbler s) async {
    if (!s.connected) return;
    while (true) {
      final batch =
          _db.getPendingOfflineScrobbles(service: s.serviceKey, limit: 10);
      if (batch.isEmpty) break;
      final idsToDelete = <int>[];
      var stopped = false;
      for (final row in batch) {
        final id = (row['id'] as num).toInt();
        final listen = Listen(
          artist: (row['artist'] as String?) ?? '',
          track: (row['track'] as String?) ?? '',
          album: (row['album'] as String?) ?? '',
          startedAtSec: (row['timestamp'] as num?)?.toInt() ?? 0,
        );
        final ok = await s.submit(listen);
        if (ok) {
          idsToDelete.add(id);
        } else {
          stopped = true;
          break;
        }
      }
      if (idsToDelete.isNotEmpty) {
        _db.deleteOfflineScrobbles(idsToDelete);
      }
      if (stopped) break;
    }
  }
}

final _scrobblerDioProvider = Provider<Dio>((_) => DioFactory.create());

final listenBrainzProvider = Provider<ListenBrainzScrobbler>((ref) =>
    ListenBrainzScrobbler(
        ref.watch(prefsProvider), ref.watch(_scrobblerDioProvider)));

final libreFmProvider = Provider<LibreFmScrobbler>((ref) =>
    LibreFmScrobbler(
        ref.watch(prefsProvider), ref.watch(_scrobblerDioProvider)));

final extraScrobblersProvider = Provider<ExtraScrobblers>((ref) =>
    ExtraScrobblers(
      [ref.watch(listenBrainzProvider), ref.watch(libreFmProvider)],
      ref.watch(databaseProvider),
    ));

/// Bumped after connecting / disconnecting so Settings and Vault refresh.
final extraScrobblersRevisionProvider = StateProvider<int>((_) => 0);

/// Lifetime listen count per connected service, for the Vault / Stats strips.
final extraScrobbleCountProvider =
    FutureProvider.autoDispose.family<int?, String>((ref, name) async {
  ref.watch(extraScrobblersRevisionProvider);
  final s = ref
      .watch(extraScrobblersProvider)
      .services
      .firstWhere((s) => s.name == name);
  return s.listenCount();
});
