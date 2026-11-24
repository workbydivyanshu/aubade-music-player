import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/features/scrobblers/extra_scrobblers.dart';

class _FakeScrobbler implements ExtraScrobbler {
  _FakeScrobbler(this.name, this.serviceKey);

  @override
  final String name;

  @override
  final String serviceKey;

  @override
  bool connected = true;

  @override
  String username = 'testuser';

  final List<Listen> submitted = [];
  final List<Listen> nowPlayingList = [];
  bool returnSuccess = true;

  @override
  Future<bool> nowPlaying(Listen l) async {
    nowPlayingList.add(l);
    return true;
  }

  @override
  Future<bool> submit(Listen l) async {
    submitted.add(l);
    return returnSuccess;
  }

  @override
  Future<int?> listenCount() async => 42;

  @override
  Uri get profileUrl => Uri.parse('https://example.com/user/$username');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('normalizeServer', () {
    test('uses fallback when blank', () {
      expect(normalizeServer('', 'https://default.com'), 'https://default.com');
      expect(
          normalizeServer('   ', 'https://default.com'), 'https://default.com');
    });

    test('prepends https if scheme is missing and trims trailing slashes', () {
      expect(normalizeServer('maloja.local:42010/', 'https://fallback.com'),
          'https://maloja.local:42010');
      expect(normalizeServer('http://custom.fm///', 'https://fallback.com'),
          'http://custom.fm');
    });
  });

  group('LibreFmScrobbler sign', () {
    test('produces stable MD5 signature sorted by key without format', () {
      final sig = LibreFmScrobbler.sign({
        'method': 'track.scrobble',
        'artist[0]': 'Radiohead',
        'track[0]': 'Karma Police',
        'format': 'json',
      }, 'secret123');
      expect(sig, isNotEmpty);
      expect(sig.length, 32);
    });
  });

  group('Prefs scrobbler keys', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('stores and clears ListenBrainz and Libre.fm credentials', () async {
      final prefs = await Prefs.load();
      expect(prefs.listenBrainzToken, isEmpty);
      expect(prefs.libreFmSession, isEmpty);

      await prefs.setListenBrainz(
        token: 'lb_tok_123',
        user: 'lb_user',
        server: 'https://lb.selfhosted',
      );
      expect(prefs.listenBrainzToken, 'lb_tok_123');
      expect(prefs.listenBrainzUser, 'lb_user');
      expect(prefs.listenBrainzServer, 'https://lb.selfhosted');

      await prefs.setLibreFm(
        session: 'lfm_sess_456',
        user: 'lfm_user',
        server: 'https://gnu.fm',
      );
      expect(prefs.libreFmSession, 'lfm_sess_456');
      expect(prefs.libreFmUser, 'lfm_user');
      expect(prefs.libreFmServer, 'https://gnu.fm');
    });
  });

  group('ExtraScrobblers durable queue', () {
    test('successful submit drains SQLite queue immediately', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      final fakeLb = _FakeScrobbler('ListenBrainz', 'listenbrainz');
      final fakeLf = _FakeScrobbler('Libre.fm', 'librefm');
      final extras = ExtraScrobblers([fakeLb, fakeLf], db);

      const listen = Listen(
        artist: 'The Smile',
        track: 'Wall of Eyes',
        album: 'Wall of Eyes',
        startedAtSec: 1700000000,
      );

      extras.submit(listen);
      // Wait for the unawaited drain tasks
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeLb.submitted, hasLength(1));
      expect(fakeLb.submitted.first.track, 'Wall of Eyes');
      expect(fakeLf.submitted, hasLength(1));
      expect(fakeLf.submitted.first.track, 'Wall of Eyes');

      expect(db.countPendingOfflineScrobbles(service: 'listenbrainz'), 0);
      expect(db.countPendingOfflineScrobbles(service: 'librefm'), 0);
    });

    test('failed submit retains rows in SQLite and drains on retry', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      final fakeLb = _FakeScrobbler('ListenBrainz', 'listenbrainz');
      fakeLb.returnSuccess = false; // Simulate network or server error

      final extras = ExtraScrobblers([fakeLb], db);

      const listen = Listen(
        artist: 'Portishead',
        track: 'Glory Box',
        startedAtSec: 1700000500,
      );

      extras.submit(listen);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeLb.submitted, hasLength(1));
      // Submit failed, so row must be persisted in SQLite
      expect(db.countPendingOfflineScrobbles(service: 'listenbrainz'), 1);

      // Now server recovers:
      fakeLb.returnSuccess = true;
      await extras.flushAll();

      expect(db.countPendingOfflineScrobbles(service: 'listenbrainz'), 0);
      expect(fakeLb.submitted, hasLength(2));
    });
  });
}
