import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/artwork/official_artwork_service.dart';
import 'package:aubade/core/network/lastfm_api.dart';
import 'package:aubade/core/network/rate_guard.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/secure_store.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/features/addons/addon_api.dart';
import 'package:aubade/features/downloads/download_manager.dart';
import 'package:aubade/features/innertube/innertube_api.dart';
import 'package:aubade/features/lastfm/scrobble_repository.dart';
import 'package:aubade/features/lyrics/karaoke_lyrics_view.dart';
import 'package:aubade/features/lyrics/lyrics_models.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/ui/components/buttons.dart' show LWTooltip;
import 'package:aubade/ui/lyrics/lyrics_panel.dart' show waveLyricsProvider;

/// The no-lyrics states must keep the header toolbar: the source
/// switcher inside it is the only way back to another provider after a
/// miss, while the offset / transliteration / follow controls are dead
/// without lyric content.
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

  /// A real PlaybackService over throwaway test doubles: the view
  /// subscribes to the playback clock in initState, so the provider
  /// must resolve to something constructible without platform
  /// channels. Nothing here plays audio.
  PlaybackService buildService() {
    final dio = Dio();
    final tube = InnerTubeMusicApi(dio, SecureStore());
    final lossless = AddonApi(const []);
    final scrobbler = ScrobbleRepository(
      LastFmApiService(dio, LastFmRateGuard()),
      prefs,
      db,
    );
    final downloads =
        DownloadManager(db, prefs, lossless, tube, LyricsRepository(dio));
    return PlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
      OfficialArtworkService(),
    );
  }

  Future<void> pumpNoLyrics(WidgetTester tester, LyricsResult result) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        playbackServiceProvider.overrideWith((ref) => buildService()),
        waveLyricsProvider.overrideWith(
          (ref, key) => Stream<LyricsResult>.value(result),
        ),
      ],
      child: FluentApp(
        home: WaveKaraokeLyricsView(
          track: const PlayableTrack(title: 'Overdue', artist: 'Metro Boomin'),
        ),
      ),
    ));
    // Loading resolves to the overridden stream value.
    await tester.pump();
    await tester.pump();
  }

  Finder tooltipFinder(String message) => find.byWidgetPredicate(
        (w) => w is LWTooltip && w.message == message,
      );

  testWidgets('empty state keeps the source switcher, hides offset and follow',
      (tester) async {
    await pumpNoLyrics(tester, const LyricsResult.empty());
    expect(find.text('No lyrics found'), findsOneWidget);

    // The switcher survives the miss (result.source is empty here).
    expect(tooltipFinder('Change lyrics source'), findsOneWidget);
    // Dead controls without lyric content.
    expect(tooltipFinder('Timing offset for this track'), findsNothing);
    expect(tooltipFinder('Enable transliteration'), findsNothing);
    expect(tooltipFinder('Return to the line being sung'), findsNothing);
  });

  testWidgets('instrumental state keeps the source switcher, hides offset and follow',
      (tester) async {
    await pumpNoLyrics(
        tester, const LyricsResult(isInstrumental: true, source: 'lrclib'));
    expect(find.text('Instrumental'), findsOneWidget);

    // The switcher survives, labelled with the reporting source.
    expect(tooltipFinder('Source: lrclib · Change'), findsOneWidget);
    expect(tooltipFinder('Timing offset for this track'), findsNothing);
    expect(tooltipFinder('Enable transliteration'), findsNothing);
    expect(tooltipFinder('Return to the line being sung'), findsNothing);
  });
}
