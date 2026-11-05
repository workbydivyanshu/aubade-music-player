import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
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
import 'package:aubade/features/library/local_library_providers.dart';
import 'package:aubade/features/library/local_track.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/features/search/shared_providers.dart'
    show databaseProvider;
import 'package:aubade/ui/app_shell/command_palette.dart';
import 'package:aubade/ui/components/menus.dart';
import 'package:aubade/ui/theme/wave_icons.dart';

class _TestPlaybackService extends PlaybackService {
  int playCalls = 0;
  int playNextCalls = 0;
  int addToQueueCalls = 0;

  _TestPlaybackService(
    super.tube,
    super.lossless,
    super.scrobbler,
    super.downloads,
    super.prefs,
    super.sessionStore,
    super.artwork,
  );

  @override
  Future<void> play(
    PlayableTrack track, {
    String sourceLabel = '',
    bool startRadio = false,
  }) async {
    playCalls++;
  }

  @override
  Future<void> playNext(PlayableTrack track) async {
    playNextCalls++;
  }

  @override
  Future<void> addToQueue(PlayableTrack track) async {
    addToQueueCalls++;
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

  group('spotlightTrackMenuItems contracts', () {
    testWidgets('omits copy actions and retains core track actions',
        (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('aubade_pal_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final tempFile = File('${tempDir.path}/track.flac')
        ..writeAsStringSync('audio');

      final track = PlayableTrack(
        title: 'Supermassive Black Hole',
        artist: 'Muse',
        album: 'Black Holes',
        playbackUrl: tempFile.path,
      );

      List<WaveMenuEntry>? entries;
      var closeCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWith((ref) => service),
          ],
          child: FluentApp(
            home: Consumer(
              builder: (context, ref, _) {
                entries = spotlightTrackMenuItems(
                  context: context,
                  ref: ref,
                  track: track,
                  closePalette: () => closeCalls++,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(entries, isNotNull);
      final actions = entries!.whereType<WaveMenuAction>().toList();

      // Ensure NO copy action exists (e.g. Copy File Path)
      final copyActions =
          actions.where((a) => a.label.toLowerCase().contains('copy'));
      expect(copyActions, isEmpty);

      // Verify core track actions exist
      expect(actions.any((a) => a.label == 'Play'), isTrue);
      expect(actions.any((a) => a.label == 'Play next'), isTrue);
      expect(actions.any((a) => a.label == 'Add to queue'), isTrue);
      expect(actions.any((a) => a.label == 'Properties'), isTrue);
      expect(actions.any((a) => a.label == 'Go to album'), isTrue);
      expect(actions.any((a) => a.label == 'Go to artist'), isTrue);
      expect(actions.any((a) => a.label == 'Show in File Manager'), isTrue);

      // Triggering 'Play' closes palette before proceeding
      final playAction = actions.firstWhere((a) => a.label == 'Play');
      playAction.onPressed?.call();
      expect(closeCalls, 1);
      expect(service.playCalls, 1);

      // Triggering 'Play next' does NOT close palette (queue-preserving)
      final playNextAction = actions.firstWhere((a) => a.label == 'Play next');
      playNextAction.onPressed?.call();
      expect(closeCalls, 1);
      expect(service.playNextCalls, 1);

      // Triggering 'Add to queue' does NOT close palette (queue-preserving)
      final addToQueueAction =
          actions.firstWhere((a) => a.label == 'Add to queue');
      addToQueueAction.onPressed?.call();
      expect(closeCalls, 1);
      expect(service.addToQueueCalls, 1);
    });
  });

  group('showWaveSpotlight keyboard & menu integration', () {
    testWidgets(
        'commands and navigation items do not show More button or track menu',
        (tester) async {
      var navigatedTo = '';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWith((ref) => service),
          ],
          child: FluentApp(
            home: ScaffoldPage(
              content: Builder(
                builder: (context) => Button(
                  onPressed: () => showWaveSpotlight(
                    context,
                    recentSearches: const ['Recent Artist'],
                    onSearch: (_) {},
                    onGo: (route) => navigatedTo = route,
                  ),
                  child: const Text('Open Spotlight'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Open Spotlight'));
      await tester.pump(const Duration(milliseconds: 200));

      // Commands / routes are visible
      expect(find.text('Go to Songs'), findsOneWidget);

      // Non-track rows must not have the 'More' button
      expect(find.byIcon(WaveIcons.more), findsNothing);

      // Pressing ContextMenu key on a command row does not open a flyout
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Properties'), findsNothing);

      // Tapping on 'Go to Songs' runs the action and closes Spotlight
      await tester.tap(find.text('Go to Songs'));
      await tester.pumpAndSettle();

      // Spotlight sheet closed and navigation occurred
      expect(find.text('Go to Songs'), findsNothing);
      expect(navigatedTo, '/songs');
    });

    testWidgets(
        'track rows display More button and open track context menu',
        (tester) async {
      final mockTrack = LocalTrack(
        path: '/music/hysteria.flac',
        title: 'Hysteria',
        artist: 'Muse',
        album: 'Absolution',
        albumArtist: 'Muse',
        duration: const Duration(seconds: 227),
        format: 'flac',
        hasEmbeddedArt: false,
        modifiedAt: 0,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWith((ref) => service),
            localSearchTracksProvider('Hysteria')
                .overrideWithValue([mockTrack]),
          ],
          child: FluentApp(
            home: ScaffoldPage(
              content: Builder(
                builder: (context) => Button(
                  onPressed: () => showWaveSpotlight(
                    context,
                    recentSearches: const [],
                    onSearch: (_) {},
                    onGo: (_) {},
                  ),
                  child: const Text('Open Spotlight'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Open Spotlight'));
      await tester.pump(const Duration(milliseconds: 200));

      // Enter query 'Hysteria'
      await tester.enterText(find.byType(TextBox), 'Hysteria');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // Track row is found
      expect(find.text('Hysteria'), findsWidgets);

      // More button is visible on the track row
      expect(find.byIcon(WaveIcons.more), findsWidgets);

      // Tap More button to open context menu
      await tester.tap(find.byIcon(WaveIcons.more).first);
      await tester.pump(const Duration(milliseconds: 200));

      // Menu flyout appears with track actions
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Properties'), findsOneWidget);
    });

    testWidgets(
        'ContextMenu keyboard shortcut opens track context menu on selected track',
        (tester) async {
      final mockTrack = LocalTrack(
        path: '/music/hysteria.flac',
        title: 'Hysteria',
        artist: 'Muse',
        album: 'Absolution',
        albumArtist: 'Muse',
        duration: const Duration(seconds: 227),
        format: 'flac',
        hasEmbeddedArt: false,
        modifiedAt: 0,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWith((ref) => service),
            localSearchTracksProvider('Hysteria')
                .overrideWithValue([mockTrack]),
          ],
          child: FluentApp(
            home: ScaffoldPage(
              content: Builder(
                builder: (context) => Button(
                  onPressed: () => showWaveSpotlight(
                    context,
                    recentSearches: const [],
                    onSearch: (_) {},
                    onGo: (_) {},
                  ),
                  child: const Text('Open Spotlight'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Open Spotlight'));
      await tester.pump(const Duration(milliseconds: 200));

      // Enter query 'Hysteria'
      await tester.enterText(find.byType(TextBox), 'Hysteria');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // Track row is found
      expect(find.text('Hysteria'), findsWidgets);

      // Press ContextMenu key on keyboard
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(const Duration(milliseconds: 200));

      // Menu flyout appears via keyboard activation
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Properties'), findsOneWidget);
    });
  });
}
