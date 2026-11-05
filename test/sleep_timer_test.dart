import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/artwork/official_artwork_service.dart';
import 'package:aubade/core/network/lastfm_api.dart';
import 'package:aubade/core/network/rate_guard.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/secure_store.dart';
import 'package:aubade/features/addons/addon_api.dart';
import 'package:aubade/features/downloads/download_manager.dart';
import 'package:aubade/features/innertube/innertube_api.dart';
import 'package:aubade/features/lastfm/scrobble_repository.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/ui/components/menus.dart';
import 'package:aubade/ui/player_dock/player_dock.dart';

/// Sleep timer contracts, exercised against the real PlaybackService
/// over throwaway doubles (no audio plays). The service clock is
/// injected so countdown/expiry behavior is deterministic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);
  });

  /// Builds the real service with [clock] as its time source.
  PlaybackService buildService(DateTime Function() clock) {
    final dio = Dio();
    final tube = InnerTubeMusicApi(dio, SecureStore());
    final lossless = AddonApi(const []);
    final scrobbler = ScrobbleRepository(
      LastFmApiService(dio, LastFmRateGuard()),
      prefs,
      db,
    );
    final downloads = DownloadManager(
      db,
      prefs,
      lossless,
      tube,
      LyricsRepository(dio),
    );
    return PlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
      OfficialArtworkService(),
      null,
      clock,
    );
  }

  group('PlaybackService.setSleepTimer', () {
    test('a selection stores the chosen length and the initial remaining', () {
      final service = buildService(() => DateTime(2026, 1, 1, 12));
      addTearDown(service.disposePlayer);

      service.setSleepTimer(const Duration(minutes: 30));

      expect(service.state.sleepMinutes, 30);
      expect(service.state.sleepRemaining, const Duration(minutes: 30));
    });

    test('a second selection replaces the deadline and minutes', () {
      final service = buildService(() => DateTime(2026, 1, 1, 12));
      addTearDown(service.disposePlayer);

      service.setSleepTimer(const Duration(minutes: 15));
      service.setSleepTimer(const Duration(minutes: 60));

      expect(service.state.sleepMinutes, 60);
      expect(service.state.sleepRemaining, const Duration(minutes: 60));
    });

    test('Off clears minutes and remaining without touching playback', () {
      final service = buildService(() => DateTime(2026, 1, 1, 12));
      addTearDown(service.disposePlayer);

      service.setSleepTimer(const Duration(minutes: 30));
      service.setSleepTimer(null);

      expect(service.state.sleepRemaining, isNull);
      expect(service.state.sleepMinutes, isNull);
      expect(service.state.isPlaying, isFalse);
    });

    testWidgets('expiry pauses playback and clears both fields', (
      tester,
    ) async {
      var fake = DateTime(2026, 1, 1, 12);
      final service = buildService(() => fake);
      addTearDown(service.disposePlayer);

      // Deadline is 12:15; readiness for expiry needs the clock past it.
      service.setSleepTimer(const Duration(minutes: 15));
      expect(service.state.sleepMinutes, 15);

      fake = DateTime(2026, 1, 1, 12, 16);
      // The periodic tick lives in the test's fake-async zone: advancing
      // the binding clock past the deadline fires the tick, which reads
      // the injected clock, finds the deadline elapsed, pauses and
      // clears both fields.
      await tester.pump(const Duration(seconds: 3));

      expect(service.state.sleepRemaining, isNull);
      expect(service.state.sleepMinutes, isNull);
      expect(service.state.isPlaying, isFalse);
    });
  });

  group('dock sleep menu composition', () {
    final starts = <Duration>[];
    var cancelled = 0;

    List<WaveMenuEntry> entries(Duration? remaining) =>
        waveSleepTimerMenuEntries(
          sleepRemaining: remaining,
          onStart: starts.add,
          onCustom: () {},
          onCancel: () => cancelled++,
        );

    setUp(() {
      starts.clear();
      cancelled = 0;
    });

    test('presets are exactly 15/30/60 plus Custom and Cancel', () {
      final labels = [
        for (final e in entries(null))
          if (e is WaveMenuAction) e.label,
      ];
      expect(labels, [
        '15 min',
        '30 min',
        '60 min',
        'Custom…',
        'Cancel sleep timer',
      ]);
    });

    test('preset taps replace the timer through the same entry', () {
      for (final e in entries(null)) {
        if (e case WaveMenuAction(label: '30 min', onPressed: final op)) {
          op?.call();
          break;
        }
      }
      expect(starts, [const Duration(minutes: 30)]);
    });

    test('Cancel is enabled only while the timer is active', () {
      final inactive = entries(null);
      final active = entries(const Duration(minutes: 4));
      expect(
        (inactive.last as WaveMenuAction).onPressed,
        isNull,
        reason: 'an inactive timer must not offer cancel',
      );
      expect((active.last as WaveMenuAction).onPressed, isNotNull);
    });

    test('cancel routes through the clear action once', () {
      final active = entries(const Duration(minutes: 4));
      (active.last as WaveMenuAction).onPressed?.call();
      expect(cancelled, 1);
    });

    test('the trigger label tracks remaining minutes and sub-minute', () {
      expect(waveSleepTimerLabel(null), 'Sleep timer');
      expect(
        waveSleepTimerLabel(const Duration(minutes: 23)),
        'Sleep in 23 min',
      );
      expect(
        waveSleepTimerLabel(const Duration(seconds: 48)),
        'Sleep in less than 1 min',
      );
    });

    test('custom-minute parsing accepts only 1–1440 whole minutes', () {
      expect(parseCustomSleepMinutes('15'), 15);
      expect(parseCustomSleepMinutes(' 90 '), 90);
      expect(parseCustomSleepMinutes('1440'), 1440);
      // Invalid inputs return null so the active timer is untouched.
      expect(parseCustomSleepMinutes(''), isNull);
      expect(parseCustomSleepMinutes('x'), isNull);
      expect(parseCustomSleepMinutes('0'), isNull);
      expect(parseCustomSleepMinutes('-5'), isNull);
      expect(parseCustomSleepMinutes('1441'), isNull);
    });
  });
}
