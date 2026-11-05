import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/artwork/official_artwork_service.dart';
import 'package:aubade/core/audio/stream_models.dart';
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
import 'package:aubade/features/player/player_state.dart';
import 'package:aubade/features/search/shared_providers.dart'
    show databaseProvider;
import 'package:aubade/ui/components/buttons.dart';
import 'package:aubade/ui/components/menus.dart';
import 'package:aubade/ui/queue/queue_panel.dart';

class _TestPlaybackService extends PlaybackService {
  int moveCalls = 0;
  int clearCalls = 0;
  int removeCalls = 0;
  int seekCalls = 0;

  _TestPlaybackService(
    super.tube,
    super.lossless,
    super.scrobbler,
    super.downloads,
    super.prefs,
    super.sessionStore,
    super.artwork,
  );

  void setTestState(PlayerSnapshot s) => state = s;

  @override
  Future<void> moveInQueue(int oldIndex, int newIndex) async {
    moveCalls++;
    await super.moveInQueue(oldIndex, newIndex);
  }

  @override
  Future<void> clearUpcoming() async {
    clearCalls++;
    await super.clearUpcoming();
  }

  @override
  Future<void> removeAt(int index) async {
    removeCalls++;
    await super.removeAt(index);
  }

  @override
  Future<void> seekToQueueItem(int index) async {
    seekCalls++;
    await super.seekToQueueItem(index);
  }
}

void main() {
  late Prefs prefs;
  late AppDatabase db;
  late _TestPlaybackService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);

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
    service = _TestPlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
      OfficialArtworkService(),
    );
  });

  const track1 = PlayableTrack(
    title: 'Song One',
    artist: 'Artist One',
    artworkUrl: 'https://e-cdns-images.dzcdn.net/images/cover/1.jpg',
  );
  const track2 = PlayableTrack(
    title: 'Song Two',
    artist: 'Artist Two',
    artworkUrl: 'https://e-cdns-images.dzcdn.net/images/cover/2.jpg',
  );
  const track3 = PlayableTrack(
    title: 'Song Three',
    artist: 'Artist Three',
    artworkUrl: 'https://e-cdns-images.dzcdn.net/images/cover/3.jpg',
  );

  Widget buildPanel({List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        playbackServiceProvider.overrideWith((ref) => service),
        ...overrides,
      ],
      child: FluentApp(
        home: ScaffoldPage(
          content: WaveQueuePanel(onClose: () {}),
        ),
      ),
    );
  }

  test('queueLockedProvider defaults to false', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(queueLockedProvider), isFalse);
  });

  testWidgets('lock glyph button toggles queue locked state and tooltip',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2, track3],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(buildPanel());
    await tester.pump(const Duration(milliseconds: 200));

    // Initially unlocked: tooltip is "Lock queue"
    expect(find.byTooltip('Lock queue'), findsOneWidget);
    expect(find.byTooltip('Clear up next'), findsOneWidget);

    // Tap lock glyph
    await tester.tap(find.byTooltip('Lock queue'));
    await tester.pump(const Duration(milliseconds: 200));

    // Now locked: tooltip updates to "Unlock queue"
    expect(find.byTooltip('Unlock queue'), findsOneWidget);
    expect(find.byTooltip('Queue is locked'), findsOneWidget);

    // Tap lock glyph again to unlock
    await tester.tap(find.byTooltip('Unlock queue'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byTooltip('Lock queue'), findsOneWidget);
    expect(find.byTooltip('Clear up next'), findsOneWidget);
  });

  testWidgets('when queue is locked: clear is disabled and blocked',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2, track3],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => true)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Clear link should be disabled
    final clearLink = tester.widget<WaveLink>(
      find.widgetWithText(WaveLink, 'Clear'),
    );
    expect(clearLink.onPressed, isNull);

    // Tapping clear does nothing
    await tester.tap(find.widgetWithText(WaveLink, 'Clear'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.clearCalls, 0);
  });

  testWidgets('when queue is unlocked: clear is active', (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2, track3],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => false)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final clearLink = tester.widget<WaveLink>(
      find.widgetWithText(WaveLink, 'Clear'),
    );
    expect(clearLink.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(WaveLink, 'Clear'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.clearCalls, 1);
  });

  testWidgets('when locked: drag handles lack ReorderableDragStartListener',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2, track3],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => true)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Drag start listener should not be present in upcoming rows
    expect(find.byType(ReorderableDragStartListener), findsNothing);
  });

  testWidgets('when unlocked: drag handles have ReorderableDragStartListener',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2, track3],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => false)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Upcoming has 2 rows (track2 and track3)
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(2));
  });

  testWidgets('when locked: context menu Remove is disabled',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => true)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Find the WaveContextMenu on the upcoming row
    final contextMenu = tester.widget<WaveContextMenu>(
      find.byType(WaveContextMenu).first,
    );
    final items = contextMenu.items();
    final removeAction = items
        .whereType<WaveMenuAction>()
        .firstWhere((a) => a.label == 'Remove');

    expect(removeAction.onPressed, isNull);
  });

  testWidgets('when unlocked: context menu Remove is active',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => false)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final contextMenu = tester.widget<WaveContextMenu>(
      find.byType(WaveContextMenu).first,
    );
    final items = contextMenu.items();
    final removeAction = items
        .whereType<WaveMenuAction>()
        .firstWhere((a) => a.label == 'Remove');

    expect(removeAction.onPressed, isNotNull);
  });

  testWidgets('locking queue does not block seek on row tap',
      (tester) async {
    service.setTestState(
      const PlayerSnapshot(
        queue: [track1, track2],
        currentIndex: 0,
      ),
    );

    await tester.pumpWidget(
      buildPanel(
        overrides: [queueLockedProvider.overrideWith((ref) => true)],
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Tap on track 2 row and wait for double-tap disambiguation
    await tester.tap(find.text('Song Two'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(service.seekCalls, 1);
  });
}
