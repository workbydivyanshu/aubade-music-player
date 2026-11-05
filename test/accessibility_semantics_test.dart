import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/semantics.dart';
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
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/features/player/player_state.dart';
import 'package:aubade/features/search/shared_providers.dart'
    show databaseProvider;
import 'package:aubade/ui/components/buttons.dart';
import 'package:aubade/ui/components/focus_glyph.dart';
import 'package:aubade/ui/components/track_row.dart';
import 'package:aubade/ui/navigation/side_rail.dart';
import 'package:aubade/ui/queue/queue_panel.dart';
import 'package:aubade/ui/settings/settings_page.dart';

class _MockPlaybackService extends PlaybackService {
  _MockPlaybackService(
    super.tube,
    super.lossless,
    super.scrobbler,
    super.downloads,
    super.prefs,
    super.sessionStore,
    super.artwork,
  );

  void setTestState(PlayerSnapshot s) => state = s;
}

class _PlaybackAnnouncementHost extends ConsumerStatefulWidget {
  const _PlaybackAnnouncementHost();
  @override
  ConsumerState<_PlaybackAnnouncementHost> createState() =>
      _PlaybackAnnouncementHostState();
}

class _PlaybackAnnouncementHostState
    extends ConsumerState<_PlaybackAnnouncementHost> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<PlayerSnapshot>(playbackServiceProvider, (previous, next) {
      if (!mounted) return;
      final view =
          View.maybeOf(context) ?? ui.PlatformDispatcher.instance.implicitView;
      if (view == null) return;
      final prevTrack = previous?.current;
      final nextTrack = next.current;
      if (nextTrack != null && nextTrack.queueKey != prevTrack?.queueKey) {
        SemanticsService.sendAnnouncement(
          view,
          'Now playing: ${nextTrack.title} by ${nextTrack.artist}',
          ui.TextDirection.ltr,
        );
        return;
      }
      if (previous != null &&
          next.isPlaying != previous.isPlaying &&
          nextTrack != null) {
        SemanticsService.sendAnnouncement(
          view,
          next.isPlaying ? 'Playing' : 'Paused',
          ui.TextDirection.ltr,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late Prefs prefs;
  late AppDatabase db;
  late _MockPlaybackService service;

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
    service = _MockPlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
      OfficialArtworkService(),
    );
  });

  group('FocusGlyph keyboard and semantic contracts', () {
    testWidgets('activates on Enter and Space, exposes semantic button',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var activated = 0;
        await tester.pumpWidget(
          FluentApp(
            home: ScaffoldPage(
              content: FocusGlyph(
                autofocus: true,
                semanticLabel: 'Custom Action',
                onActivate: () => activated++,
                child: const SizedBox(width: 30, height: 30),
              ),
            ),
          ),
        );
        await tester.pump();

        final data =
            tester.getSemantics(find.byType(FocusGlyph)).getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.label, 'Custom Action');
        expect(data.flagsCollection.isFocused == ui.Tristate.isTrue, isTrue);

        // Press Enter to activate
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(activated, 1);

        // Press Space to activate
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(activated, 2);
      } finally {
        handle.dispose();
      }
    });
  });

  group('Queue lock glyph semantics & keyboard citizenship', () {
    testWidgets('exposes toggle state and button role to semantics',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        const trackA = PlayableTrack(
          title: 'Song A',
          artist: 'Artist A',
          playbackUrl: '/music/a.flac',
          artworkUrl: 'https://e-cdns-images.dzcdn.net/images/cover/sample.jpg',
        );
        service.setTestState(
          const PlayerSnapshot(
            current: trackA,
            queue: [trackA],
            currentIndex: 0,
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              prefsProvider.overrideWithValue(prefs),
              databaseProvider.overrideWithValue(db),
              playbackServiceProvider.overrideWith((ref) => service),
            ],
            child: FluentApp(
              home: ScaffoldPage(
                content: SizedBox(
                  width: 360,
                  child: WaveQueuePanel(onClose: () {}),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Lock glyph is present with "Lock queue" tooltip and semantics
        final lockFinder = find.bySemanticsLabel('Lock queue');
        expect(lockFinder, findsOneWidget);

        final lockSemantics =
            tester.getSemantics(lockFinder).getSemanticsData();
        expect(lockSemantics.flagsCollection.isButton, isTrue);
        expect(
            lockSemantics.flagsCollection.isToggled != ui.Tristate.none,
            isTrue);
        expect(
            lockSemantics.flagsCollection.isToggled == ui.Tristate.isTrue,
            isFalse);

        // Tap lock button to lock queue
        await tester.tap(lockFinder);
        await tester.pump();

        // Now tooltip and semantics reflect locked state
        final unlockFinder = find.bySemanticsLabel('Unlock queue');
        expect(unlockFinder, findsOneWidget);

        final unlockSemantics =
            tester.getSemantics(unlockFinder).getSemanticsData();
        expect(unlockSemantics.flagsCollection.isButton, isTrue);
        expect(
            unlockSemantics.flagsCollection.isToggled != ui.Tristate.none,
            isTrue);
        expect(
            unlockSemantics.flagsCollection.isToggled == ui.Tristate.isTrue,
            isTrue);
      } finally {
        handle.dispose();
      }
    });
  });

  group('Side rail navigation semantics', () {
    testWidgets('exposes selected and button states for destinations',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          FluentApp(
            home: ScaffoldPage(
              content: SizedBox(
                width: 60,
                height: 600,
                child: WaveSideRail(
                  active: '/liked',
                  onGo: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final likedFinder = find.bySemanticsLabel('Liked Songs');
        expect(likedFinder, findsOneWidget);

        final likedSemantics =
            tester.getSemantics(likedFinder).getSemanticsData();
        expect(likedSemantics.flagsCollection.isButton, isTrue);
        expect(
            likedSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
            isTrue);

        final songsFinder = find.bySemanticsLabel('Songs');
        expect(songsFinder, findsOneWidget);

        final songsSemantics =
            tester.getSemantics(songsFinder).getSemanticsData();
        expect(songsSemantics.flagsCollection.isButton, isTrue);
        expect(
            songsSemantics.flagsCollection.isSelected == ui.Tristate.isTrue,
            isFalse);
      } finally {
        handle.dispose();
      }
    });
  });

  group('Track row semantics', () {
    testWidgets('exposes track name, artist, and selected state',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              prefsProvider.overrideWithValue(prefs),
              databaseProvider.overrideWithValue(db),
              playbackServiceProvider.overrideWith((ref) => service),
            ],
            child: const FluentApp(
              home: ScaffoldPage(
                content: WaveTrackRow(
                  title: 'Starlight',
                  artist: 'Muse',
                  album: 'Black Holes',
                  artworkUrl: 'https://e-cdns-images.dzcdn.net/images/cover/sample.jpg',
                  isCurrent: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final trackFinder = find.byType(WaveTrackRow);
        expect(trackFinder, findsOneWidget);

        final semantics = tester.getSemantics(trackFinder).getSemanticsData();
        expect(semantics.label, contains('Starlight by Muse'));
        expect(semantics.flagsCollection.isButton, isTrue);
        expect(
            semantics.flagsCollection.isSelected == ui.Tristate.isTrue,
            isTrue);
      } finally {
        handle.dispose();
      }
    });
  });

  group('Sliders accessibility semantics', () {
    testWidgets('LWProgressSlider and LWVolumeSlider expose slider semantics',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          FluentApp(
            home: ScaffoldPage(
              content: Column(
                children: [
                  LWProgressSlider(value: 0.42, onChanged: (_) {}),
                  LWVolumeSlider(value: 0.85, onChanged: (_) {}),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        final seekSemantics =
            tester.getSemantics(find.byType(LWProgressSlider)).getSemanticsData();
        expect(seekSemantics.flagsCollection.isSlider, isTrue);
        expect(seekSemantics.value, '42%');

        final volSemantics =
            tester.getSemantics(find.byType(LWVolumeSlider)).getSemanticsData();
        expect(volSemantics.flagsCollection.isSlider, isTrue);
        expect(volSemantics.value, '85%');
      } finally {
        handle.dispose();
      }
    });
  });

  group('Settings search keyboard Esc handling', () {
    testWidgets('Esc key clears search query when search field has focus',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
          ],
          child: const FluentApp(
            home: ScaffoldPage(
              content: WaveSettingsPage(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final searchBox = find.byType(TextBox).first;
      expect(searchBox, findsOneWidget);

      await tester.enterText(searchBox, 'crossfade');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('crossfade'), findsOneWidget);

      // Press Esc to clear search
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('crossfade'), findsNothing);
    });
  });

  group('Playback semantic announcements deduplication', () {
    testWidgets('announces track change without double-announcing play state',
        (tester) async {
      final List<String> announcements = [];

      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (dynamic message) async {
          if (message is Map && message['type'] == 'announce') {
            final data = message['data'] as Map;
            announcements.add(data['message'] as String);
          }
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            playbackServiceProvider.overrideWith((ref) => service),
          ],
          child: const FluentApp(
            home: ScaffoldPage(
              content: _PlaybackAnnouncementHost(),
            ),
          ),
        ),
      );
      await tester.pump();

      const trackA = PlayableTrack(
        title: 'Song A',
        artist: 'Artist A',
        playbackUrl: '/music/a.flac',
      );

      // Transition to Track A playing:
      service.setTestState(
        const PlayerSnapshot(
          current: trackA,
          queue: [trackA],
          currentIndex: 0,
          isPlaying: true,
        ),
      );
      await tester.pump();

      // Only "Now playing" should be announced, NOT a separate "Playing"
      expect(announcements, [
        'Now playing: Song A by Artist A',
      ]);

      // Now toggle play/pause while keeping track the same:
      service.setTestState(
        const PlayerSnapshot(
          current: trackA,
          queue: [trackA],
          currentIndex: 0,
          isPlaying: false,
        ),
      );
      await tester.pump();

      expect(announcements, [
        'Now playing: Song A by Artist A',
        'Paused',
      ]);

      // Resume playback on same track:
      service.setTestState(
        const PlayerSnapshot(
          current: trackA,
          queue: [trackA],
          currentIndex: 0,
          isPlaying: true,
        ),
      );
      await tester.pump();

      expect(announcements, [
        'Now playing: Song A by Artist A',
        'Paused',
        'Playing',
      ]);
    });
  });
}
