import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/artwork/official_artwork_service.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/core/network/lastfm_api.dart';
import 'package:aubade/core/network/rate_guard.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/secure_store.dart';
import 'package:aubade/design_system/fluent/aubade_scrollbar.dart';
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
import 'package:aubade/ui/queue/queue_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'aubade_word_by_word': false});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);
  });

  /// A real PlaybackService over throwaway test doubles. The karaoke view
  /// listens to playback state, so the provider must resolve to something
  /// constructible without platform channels. Nothing here plays audio.
  PlaybackService buildService() {
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
    );
  }

  Future<void> pumpLine(
    WidgetTester tester, {
    required String text,
    bool isActive = false,
    bool? karaoke,
    List<LyricSyllable> syllables = const [],
  }) async {
    await tester.pumpWidget(
      FluentApp(
        themeMode: ThemeMode.dark,
        home: Center(
          child: SizedBox(
            width: 640,
            child: WaveKaraokeLyricLine(
              line: LyricLine(
                timeMs: 0,
                durationMs: 4000,
                text: text,
                syllables: syllables,
              ),
              positionMs: 0,
              isActive: isActive,
              isPast: false,
              karaoke: karaoke ?? isActive,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpKaraoke(
    WidgetTester tester,
    LyricsResult result, {
    bool withControlList = false,
  }) async {
    final service = buildService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          playbackServiceProvider.overrideWith((ref) => service),
          waveLyricsProvider.overrideWith(
            (ref, key) => Stream<LyricsResult>.value(result),
          ),
        ],
        child: FluentApp(
          themeMode: ThemeMode.dark,
          scrollBehavior: const WaveScrollBehavior(),
          home: Column(
            children: [
              Expanded(
                child: WaveKaraokeLyricsView(
                  track: const PlayableTrack(title: 'Test', artist: 'Artist'),
                  showHeaderControls: false,
                ),
              ),
              if (withControlList)
                SizedBox(
                  height: 80,
                  child: ListView(
                    key: const Key('scrollbar-control'),
                    children: const [SizedBox(height: 400)],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // Loading resolves to the overridden stream value.
    await tester.pump();
    await tester.pump();
  }

  group('isJoinedScript', () {
    test('flags joined scripts, including Devanagari', () {
      expect(isJoinedScript('नमस्ते दुनिया'), isTrue);
      expect(isJoinedScript('বাংলা'), isTrue);
      expect(isJoinedScript('සිංහල'), isTrue);
      expect(isJoinedScript('สวัสดี'), isTrue);
      expect(isJoinedScript('ສະບາຍດີ'), isTrue);
      expect(isJoinedScript('မင်္ဂလာပါ'), isTrue);
      expect(isJoinedScript('ជំរាបសួរ'), isTrue);
    });

    test('leaves Latin and other non-joined scripts alone', () {
      expect(isJoinedScript('Hello world'), isFalse);
      expect(isJoinedScript('Привет мир'), isFalse);
      expect(isJoinedScript('こんにちは'), isFalse);
      expect(isJoinedScript(''), isFalse);
    });
  });

  group('joined-script line rendering', () {
    testWidgets('Devanagari idle line has natural tracking and a group fade', (
      tester,
    ) async {
      await pumpLine(tester, text: 'नमस्ते दुनिया');

      final text = tester.widget<Text>(find.text('नमस्ते दुनिया'));
      expect(text.style?.letterSpacing, 0.0);
      expect(text.style?.color?.a, closeTo(1.0, 0.001));

      final opacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.text('नमस्ते दुनिया'),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, closeTo(0.44, 0.001));
    });

    testWidgets('Latin idle line keeps the existing tight tracking', (
      tester,
    ) async {
      await pumpLine(tester, text: 'Hello world');

      final text = tester.widget<Text>(find.text('Hello world'));
      expect(text.style?.letterSpacing, -0.3);
      expect(text.style?.color?.a, closeTo(0.44, 0.001));
      expect(
        find.ancestor(
          of: find.text('Hello world'),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('Devanagari active line resets tracking but does not fade', (
      tester,
    ) async {
      await pumpLine(
        tester,
        text: 'नमस्ते दुनिया',
        isActive: true,
        karaoke: false,
      );

      final text = tester.widget<Text>(find.text('नमस्ते दुनिया'));
      expect(text.style?.letterSpacing, 0.0);
      expect(text.style?.color?.a, closeTo(1.0, 0.001));
      expect(
        find.ancestor(
          of: find.text('नमस्ते दुनिया'),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('Devanagari syllable idle run fades as one group', (
      tester,
    ) async {
      await pumpLine(
        tester,
        text: 'नमस्ते दुनिया',
        isActive: true,
        syllables: const [
          LyricSyllable(timeMs: 0, durationMs: 2000, text: 'नमस्ते '),
          LyricSyllable(timeMs: 2000, durationMs: 2000, text: 'दुनिया'),
        ],
      );

      final text = tester.widget<Text>(find.text('नमस्ते'));
      expect(text.style?.letterSpacing, 0.0);
      expect(text.style?.color?.a, closeTo(1.0, 0.001));

      final opacity = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('नमस्ते'), matching: find.byType(Opacity))
            .first,
      );
      expect(opacity.opacity, closeTo(0.38, 0.001));
    });

    testWidgets('Latin syllable idle run stays on the plain path', (
      tester,
    ) async {
      await pumpLine(
        tester,
        text: 'Hello world',
        isActive: true,
        syllables: const [
          LyricSyllable(timeMs: 0, durationMs: 2000, text: 'Hello '),
          LyricSyllable(timeMs: 2000, durationMs: 2000, text: 'world'),
        ],
      );

      final text = tester.widget<Text>(find.text('Hello'));
      expect(text.style?.letterSpacing, -0.3);
      expect(text.style?.color?.a, closeTo(0.38, 0.001));
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('joined partial syllables use the group-fade stack', (
      tester,
    ) async {
      await pumpLine(
        tester,
        text: 'नमस्ते',
        isActive: true,
        syllables: const [
          LyricSyllable(timeMs: 0, durationMs: 4000, text: 'नमस्ते'),
        ],
      );
      // Position 0 keeps every syllable idle; rebuild at halfway below.
      await tester.pumpWidget(
        FluentApp(
          themeMode: ThemeMode.dark,
          home: Center(
            child: SizedBox(
              width: 640,
              child: WaveKaraokeLyricLine(
                line: const LyricLine(
                  timeMs: 0,
                  durationMs: 4000,
                  text: 'नमस्ते',
                  syllables: [
                    LyricSyllable(timeMs: 0, durationMs: 4000, text: 'नमस्ते'),
                  ],
                ),
                positionMs: 2000,
                isActive: true,
                isPast: false,
                karaoke: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ShaderMask), findsOneWidget);
      expect(find.byType(Opacity), findsOneWidget);
      final text = tester.widget<Text>(find.text('नमस्ते').first);
      expect(text.style?.letterSpacing, 0.0);
      expect(text.style?.color?.a, closeTo(1.0, 0.001));
    });
  });

  group('Apple line lyrics scrollbar', () {
    testWidgets('synced list hides the bar while other lists keep it', (
      tester,
    ) async {
      await pumpKaraoke(
        tester,
        const LyricsResult(
          isSynced: true,
          lines: [
            LyricLine(timeMs: 1000, durationMs: 1000, text: 'First line'),
            LyricLine(timeMs: 2000, durationMs: 1000, text: 'Second line'),
          ],
        ),
        withControlList: true,
      );

      final list = find.byType(ScrollablePositionedList);
      expect(list, findsOneWidget);
      expect(
        find.descendant(of: list, matching: find.byType(RawScrollbar)),
        findsNothing,
      );
      // The app-wide behavior still dresses ordinary lists.
      expect(
        find.descendant(
          of: find.byKey(const Key('scrollbar-control')),
          matching: find.byType(RawScrollbar),
        ),
        findsOneWidget,
      );
    });

    testWidgets('untimed list hides the bar too', (tester) async {
      await pumpKaraoke(
        tester,
        const LyricsResult(
          lines: [
            LyricLine(timeMs: 0, text: 'Line one'),
            LyricLine(timeMs: 0, text: 'Line two'),
          ],
        ),
      );

      final list = find.descendant(
        of: find.byType(WaveKaraokeLyricsView),
        matching: find.byType(ListView),
      );
      expect(list, findsOneWidget);
      expect(
        find.descendant(of: list, matching: find.byType(RawScrollbar)),
        findsNothing,
      );
    });
  });

  group('queue drag handle cursor', () {
    testWidgets('only the drag handle advertises move', (tester) async {
      final service = buildService();
      await service.addToQueue(const PlayableTrack(title: 'First', artist: ''));
      await service.addToQueue(
        const PlayableTrack(title: 'Second', artist: ''),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            playbackServiceProvider.overrideWith((ref) => service),
          ],
          child: FluentApp(
            themeMode: ThemeMode.dark,
            home: Center(
              child: SizedBox(
                width: 360,
                height: 600,
                child: WaveQueuePanel(onClose: () {}, embedded: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final handles = find.byType(ReorderableDragStartListener);
      expect(handles, findsNWidgets(2));
      expect(
        find.byWidgetPredicate(
          (w) => w is LWTooltip && w.message == 'Drag to reorder',
        ),
        findsNWidgets(2),
      );

      final regions = find.descendant(
        of: handles,
        matching: find.byType(MouseRegion),
      );
      expect(regions, findsNWidgets(2));
      for (final element in regions.evaluate()) {
        expect((element.widget as MouseRegion).cursor, SystemMouseCursors.move);
      }
      // The row keeps its click cursor outside the handle.
      final rowCursors = tester
          .widgetList<MouseRegion>(
            find.ancestor(
              of: handles.first,
              matching: find.byType(MouseRegion),
            ),
          )
          .map((region) => region.cursor);
      expect(rowCursors, contains(SystemMouseCursors.click));

      // The painted cursor follows the hovered sub-region.
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(
        tester.getCenter(find.byIcon(FluentIcons.gripper_bar_vertical).first),
      );
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.move,
      );

      await gesture.moveTo(tester.getCenter(find.text('First')));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );

      // Let the queue's throttled persist timer drain before teardown.
      await service.disposePlayer();
    });
  });
}
