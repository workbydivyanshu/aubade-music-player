import 'dart:async';
import 'dart:io';

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
import 'package:aubade/features/lyrics/lyrics_models.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/ui/lyrics/lyrics_panel.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v1.0.9 Auto source priority:
/// 1. any acceptable Apple Music result (regardless of sync quality),
/// 2. other word-synced lyrics,
/// 3. other line-synced lyrics,
/// 4. other plain lyrics,
/// 5. the adjacent local `.lrc` sidecar (Auto last resort; manual picks
///    keep the older sidecar-first path).

LyricsResult _word(String source) => LyricsResult(
  lines: const [
    LyricLine(
      timeMs: 1000,
      durationMs: 3000,
      text: 'Hello world',
      syllables: [
        LyricSyllable(timeMs: 1000, durationMs: 500, text: 'Hello '),
        LyricSyllable(timeMs: 1500, durationMs: 500, text: 'world'),
      ],
    ),
    LyricLine(
      timeMs: 5000,
      durationMs: 3000,
      text: 'Second line',
      syllables: [
        LyricSyllable(timeMs: 5000, durationMs: 500, text: 'Second '),
        LyricSyllable(timeMs: 5500, durationMs: 500, text: 'line'),
      ],
    ),
  ],
  isSynced: true,
  isWordSynced: true,
  plainLyrics: 'Hello world\nSecond line',
  source: source,
);

LyricsResult _line(String source) => LyricsResult(
  lines: const [
    LyricLine(timeMs: 1000, durationMs: 3000, text: 'Hello world'),
    LyricLine(timeMs: 5000, durationMs: 3000, text: 'Second line'),
  ],
  isSynced: true,
  isWordSynced: false,
  plainLyrics: 'Hello world\nSecond line',
  source: source,
);

LyricsResult _plain(String source) => LyricsResult(
  lines: const [
    LyricLine(timeMs: 0, text: 'Hello world'),
    LyricLine(timeMs: 0, text: 'Second line'),
  ],
  isSynced: false,
  isWordSynced: false,
  plainLyrics: 'Hello world\nSecond line',
  source: source,
);

/// Repository with stubbed providers and short deadlines.
class _StubRepo extends LyricsRepository {
  final Map<String, LyricsResult?> results;
  final Map<String, int> calls = {};
  final Map<String, Duration> delays;
  final Map<String, Completer<LyricsResult?>> pendingProviders;

  _StubRepo(
    this.results, {
    this.delays = const {},
    this.pendingProviders = const {},
    Duration raceTotal = const Duration(seconds: 2),
  }) : super(Dio(), const Duration(milliseconds: 200), raceTotal);

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) {
    calls[providerId] = (calls[providerId] ?? 0) + 1;
    final pending = pendingProviders[providerId];
    if (pending != null) return pending.future;
    final result = results[providerId];
    final delay = delays[providerId] ?? Duration.zero;
    if (delay == Duration.zero) return Future.value(result);
    return Future.delayed(delay, () => result);
  }
}

/// Offline double that also records the filePath argument, for
/// provider-level assertions.
class _RecordingRepo extends LyricsRepository {
  bool providersHit = false;
  final List<String?> seenFilePaths = [];

  _RecordingRepo() : super(Dio());

  @override
  Future<LyricsResult> getLyrics({
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    bool forceRefresh = false,
    bool wordByWord = true,
    String? videoId,
    String preferredProviderId = 'auto',
    Set<String> excludeProviderIds = const {},
    String? filePath,
    void Function(LyricsResult partial)? onPartialResult,
  }) {
    seenFilePaths.add(filePath);
    return super.getLyrics(
      title: title,
      artist: artist,
      album: album,
      durationSeconds: durationSeconds,
      forceRefresh: forceRefresh,
      wordByWord: wordByWord,
      videoId: videoId,
      preferredProviderId: preferredProviderId,
      excludeProviderIds: excludeProviderIds,
      filePath: filePath,
      onPartialResult: onPartialResult,
    );
  }

  @override
  Future<LyricsResult?> fetchFromProvider(
    String providerId, {
    required String title,
    required String artist,
    String album = '',
    int? durationSeconds,
    String? videoId,
  }) async {
    providersHit = true;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Auto tier priority', () {
    test('faster word candidate is provisional; any acceptable Apple '
        'result wins final regardless of sync quality', () async {
      final repo = _StubRepo(
        {
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'apple_music': _line('Apple Music (Line-Sync)'),
        },
        delays: {
          'kugou': const Duration(milliseconds: 40),
          'apple_music': const Duration(milliseconds: 120),
        },
      );
      final partials = <LyricsResult>[];
      final result = await repo.getLyrics(
        title: 'T',
        artist: 'A',
        onPartialResult: partials.add,
      );
      expect(
        result.source,
        contains('Apple'),
        reason: 'Apple is top tier even when it serves a line-synced cut',
      );
      expect(result.isWordSynced, isFalse);
      expect(
        partials.map((r) => r.source).toList(),
        ['Kugou KRC (Word-Sync)'],
        reason:
            'the non-Apple word hit streamed as a provisional partial '
            'while the Apple attempt was still pending',
      );
    });

    test('Apple-null falls through to the best non-Apple result', () async {
      final repo = _StubRepo(
        {
          'apple_music': null,
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'lrclib': _line('lrclib'),
        },
        delays: {'kugou': const Duration(milliseconds: 30)},
      );
      final result = await repo.getLyrics(title: 'T', artist: 'A');
      expect(result.source, contains('Kugou'));
      expect(result.isWordSynced, isTrue);
    });

    test('Apple-unacceptable (alternate-recording instrumental) falls '
        'through', () async {
      final repo = _StubRepo({
        'apple_music': const LyricsResult(
          isInstrumental: true,
          isSynced: false,
          plainLyrics: 'Instrumental',
          source: 'Apple Music',
        ),
        'kugou': _word('Kugou KRC (Word-Sync)'),
      });
      final result = await repo.getLyrics(title: 'T', artist: 'A');
      expect(result.source, contains('Kugou'));
    });

    test('Apple pending past the race deadline no longer gates the '
        'fallback tiers', () async {
      final repo = _StubRepo(
        {
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'apple_music': _line('Apple Music (Line-Sync)'),
        },
        delays: {
          'kugou': const Duration(milliseconds: 30),
          // Apple never answers inside the race deadline.
          'apple_music': const Duration(seconds: 30),
        },
        raceTotal: const Duration(milliseconds: 400),
      );
      final result = await repo.getLyrics(title: 'T', artist: 'A');
      expect(
        result.source,
        contains('Kugou'),
        reason:
            'the deadline lets the collected word candidate finalize '
            'even with the Apple attempt still pending',
      );
    });

    test('word > line > plain among collected candidates', () async {
      // Line arrives first, plain second, word last: the tier order,
      // not arrival order, must decide.
      final repo = _StubRepo(
        {
          'better_lyrics': _line('BetterLyrics (Line-Sync)'),
          'lrclib': _plain('lrclib'),
          'kugou': _word('Kugou KRC (Word-Sync)'),
        },
        delays: {
          'lrclib': const Duration(milliseconds: 30),
          'kugou': const Duration(milliseconds: 60),
        },
      );
      final result = await repo.getLyrics(title: 'T', artist: 'A');
      expect(result.source, contains('Kugou'));
      expect(result.isWordSynced, isTrue);

      // Isolated same test for the line/plain edge: plain is delivered
      // first, the line-sync still wins.
      final lineVsPlain = _StubRepo(
        {
          'lrclib': _plain('lrclib'),
          'better_lyrics': _line('BetterLyrics (Line-Sync)'),
        },
        delays: {'better_lyrics': const Duration(milliseconds: 50)},
      );
      final lineWin = await lineVsPlain.getLyrics(title: 'T', artist: 'A');
      expect(lineWin.source, contains('BetterLyrics'));
      expect(lineWin.isSynced, isTrue);
      expect(lineWin.isWordSynced, isFalse);
    });

    test('Catalog line beats an earlier collected plain candidate, and '
        'is itself exclusion-respecting', () async {
      // LRCLIB plain arrives first as a provisional partial; the
      // raced Musixmatch line-sync then outranks it (line > plain).
      final repo = _StubRepo(
        {
          'lrclib': _plain('lrclib'),
          'musixmatch': _line('Catalog (Line-Sync)'),
        },
        delays: {'musixmatch': const Duration(milliseconds: 50)},
      );
      final partials = <LyricsResult>[];
      final result = await repo.getLyrics(
        title: 'T',
        artist: 'A',
        onPartialResult: partials.add,
      );
      expect(result.source, 'Catalog (Line-Sync)');
      expect(result.isSynced, isTrue);
      expect(
        partials.map((r) => r.source).toList(),
        ['lrclib', 'Catalog (Line-Sync)'],
        reason:
            'the plain cut streamed as a provisional while Musixmatch '
            'was pending, and the displacing line-sync streamed itself; '
            'the FINAL result is the line-sync',
      );

      // Excluding the Catalog entry leaves plain (or whatever else)
      // as the best collected candidate, and no Catalog call at all.
      final noCatalog = _StubRepo({
        'lrclib': _plain('lrclib'),
        'musixmatch': _line('Catalog (Line-Sync)'),
      });
      final plainWin = await noCatalog.getLyrics(
        title: 'T',
        artist: 'A',
        excludeProviderIds: const {'musixmatch'},
      );
      expect(plainWin.source, 'lrclib');
      expect(noCatalog.calls.containsKey('musixmatch'), isFalse);
    });

    test('an exceptionally richer plain cut cannot displace a '
        'line-synced candidate', () async {
      // The plain candidate is deliberately massive enough that the
      // cross-sync richness rule inside isBetterCandidate would pick
      // it (2x fuller, packed ≥60 chars/line) — the tier wall must
      // hold regardless.
      final longPlain = LyricsResult(
        lines: [
          for (var i = 0; i < 4; i++)
            LyricLine(timeMs: 0, text: 'Plain filler line ${'x' * 92} $i'),
        ],
        isSynced: false,
        plainLyrics: 'Plain fillers',
        source: 'lrclib',
      );
      final repo = _StubRepo(
        {
          'better_lyrics': _line('BetterLyrics (Line-Sync)'),
          'lrclib': longPlain,
        },
        delays: {'lrclib': const Duration(milliseconds: 50)},
      );
      final partials = <LyricsResult>[];
      final result = await repo.getLyrics(
        title: 'T',
        artist: 'A',
        onPartialResult: partials.add,
      );
      expect(result.source, contains('BetterLyrics'));
      expect(result.isSynced, isTrue);
      expect(result.isWordSynced, isFalse);
      // The line candidate was emitted once; the later plain event
      // must not re-emit or replace it.
      expect(partials.map((r) => r.source).toList(), [
        'BetterLyrics (Line-Sync)',
      ]);

      // Control: isBetterCandidate would indeed favor the plain cut
      // cross-tier, which is exactly what the tier wall blocks.
      expect(
        LyricsRepository.isBetterCandidate(
          longPlain,
          _line('BetterLyrics (Line-Sync)'),
          queryTitle: 'T',
        ),
        isTrue,
        reason:
            'precondition: the richness rule alone would replace; '
            'the equal-tier restriction is what prevents it',
      );
    });

    test(
      'only the real apple_music provider gets top-tier treatment; '
      'Apple-labeled results from other providers rank by sync flags',
      () async {
        // A non-Apple provider carrying an Apple-looking source label is
        // classified by its sync flags (word → tier 1), and the race
        // still honors the actual apple_music attempt (null here) under
        // the same gating rules.
        final repo = _StubRepo({
          'kugou': _word('Apple Music (Word-Sync)'),
          'apple_music': null,
        });
        final result = await repo.getLyrics(title: 'T', artist: 'A');
        expect(
          repo.calls['apple_music'],
          1,
          reason:
              'the apple_music provider itself was attempted once '
              'and its null does not gate the fallback tiers',
        );
        expect(result.source, 'Apple Music (Word-Sync)');
        expect(result.isWordSynced, isTrue);
      },
    );

    test(
      'exclusions respected: an excluded provider is never attempted',
      () async {
        final repo = _StubRepo({
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'apple_music': _line('Apple Music (Line-Sync)'),
        });
        final result = await repo.getLyrics(
          title: 'T',
          artist: 'A',
          excludeProviderIds: const {'kugou'},
        );
        expect(result.source, contains('Apple'));
        expect(repo.calls.containsKey('kugou'), isFalse);

        final noApple = _StubRepo({
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'apple_music': _line('Apple Music (Line-Sync)'),
        });
        final wordOnly = await noApple.getLyrics(
          title: 'T',
          artist: 'A',
          excludeProviderIds: const {'apple_music'},
        );
        expect(wordOnly.source, contains('Kugou'));
        expect(noApple.calls.containsKey('apple_music'), isFalse);
      },
    );

    test('simp_music requires a videoId', () async {
      final repo = _StubRepo({'simp_music': _word('Video-Match (Word-Sync)')});
      final result = await repo.getLyrics(title: 'T', artist: 'A');
      expect(repo.calls.containsKey('simp_music'), isFalse);
      expect(result.isEmpty, isTrue);

      final withVideo = _StubRepo({
        'simp_music': _word('Video-Match (Word-Sync)'),
      });
      final matched = await withVideo.getLyrics(
        title: 'T',
        artist: 'A',
        videoId: 'abc',
      );
      expect(matched.source, 'Video-Match (Word-Sync)');
    });
  });

  group('Auto local sidecar last resort', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('auto_sidecar');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('remote plain beats the adjacent local sidecar', () async {
      File('${tempDir.path}/Track.lrc')
          .writeAsStringSync('[00:10.00] Sidecar Only Line\n');
      final repo = _StubRepo({'lrclib': _plain('lrclib')});
      final result = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
      );
      expect(result.source, 'lrclib');
      expect(
        result.plainLyrics.contains('Sidecar Only Line'),
        isFalse,
        reason: 'the sidecar waits until every remote tier misses',
      );
    });

    test('local sidecar used when all remote sources miss', () async {
      File('${tempDir.path}/Track.lrc')
          .writeAsStringSync('Other tag line\n[00:10.00] Sidecar Line\n');
      final repo = _StubRepo({});
      final result = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
      );
      expect(result.source, 'Local (.lrc)');
      expect(result.isSynced, isTrue);
      expect(result.plainLyrics, 'Sidecar Line');
    });

    test('sidecar waits for the race deadline while a remote is pending',
        () async {
      File('${tempDir.path}/Track.lrc')
          .writeAsStringSync('[00:10.00] Sidecar Line\n');
      final pendingApple = Completer<LyricsResult?>();
      const deadline = Duration(milliseconds: 90);
      final repo = _StubRepo(
        {},
        pendingProviders: {'apple_music': pendingApple},
        raceTotal: deadline,
      );
      final elapsed = Stopwatch()..start();
      final result = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
      );
      elapsed.stop();

      expect(result.source, 'Local (.lrc)');
      expect(
        elapsed.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 70)),
        reason: 'the local sidecar is not an immediate network shortcut',
      );
      expect(
        pendingApple.isCompleted,
        isFalse,
        reason: 'the sidecar is returned when the deadline expires',
      );
      pendingApple.complete(null);
    });

    test('both sidecar name styles load; canonical <track>.lrc wins '
        'when both exist', () async {
      // Only the appended <track.ext>.lrc form exists.
      File('${tempDir.path}/Track.flac.lrc')
          .writeAsStringSync('[00:08.00] Appended form\n');
      final repo = _StubRepo({});
      final appendedOnly = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
      );
      expect(appendedOnly.source, 'Local (.lrc)');
      expect(appendedOnly.plainLyrics, 'Appended form');

      // With both forms present the canonical extension-stripped
      // sidecar wins deterministically.
      File('${tempDir.path}/Track.lrc')
          .writeAsStringSync('[00:10.00] Canonical form\n');
      final both = _StubRepo({});
      final canonical = await both.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
        forceRefresh: true,
      );
      expect(canonical.source, 'Local (.lrc)');
      expect(
        canonical.plainLyrics,
        'Canonical form',
        reason:
            'extension-stripped <track>.lrc is preferred over '
            '<track.ext>.lrc',
      );
    });

    test('an unreadable/invalid canonical <track>.lrc falls through to '
        'a valid appended <track.ext>.lrc', () async {
      // Canonical exists but is binary garbage → read throws, the
      // appended form must still be tried.
      File('${tempDir.path}/Track.lrc')
          .writeAsBytesSync(const [0xFF, 0xFE, 0x00, 0x01]);
      File('${tempDir.path}/Track.flac.lrc')
          .writeAsStringSync('[00:08.00] Appended recovery\n');
      final repo = _StubRepo({});
      final binary = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
        forceRefresh: true,
      );
      expect(binary.source, 'Local (.lrc)');
      expect(binary.plainLyrics, 'Appended recovery');

      // Canonical is readable text but parses to nothing → the next
      // candidate is tried.
      File('${tempDir.path}/TrackB.lrc')
          .writeAsStringSync('completely not an lrc\n');
      File('${tempDir.path}/TrackB.flac.lrc')
          .writeAsStringSync('[00:09.00] Appended recovery B\n');
      final text = await repo.getLyrics(
        title: 'TrackB',
        artist: 'Artist',
        filePath: '${tempDir.path}/TrackB.flac',
        forceRefresh: true,
      );
      expect(text.plainLyrics, 'Appended recovery B');
    });

    test('different file paths never share a cached sidecar', () async {
      Directory('${tempDir.path}/copyB').createSync();
      File('${tempDir.path}/copyB/Track.lrc')
          .writeAsStringSync('[00:10.00] Same Title A\n');
      final repo = _StubRepo({});
      final first = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/copyB/Track.flac',
      );
      expect(first.source, 'Local (.lrc)');

      // The other copy has no sidecar of its own: even with identical
      // title/artist it must not replay copy A's cached result.
      final second = await repo.getLyrics(
        title: 'Track',
        artist: 'Artist',
        filePath: '${tempDir.path}/Track.flac',
      );
      expect(second.source, isNot('Local (.lrc)'));
      expect(
        repo.calls['kugou'],
        2,
        reason:
            'the second call refetched: filePath is part of the '
            'cache key',
      );
    });
  });

  group('manual selection keeps its existing path', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('manual_sidecar');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'a sidecar still short-circuits the network on a manual pick',
      () async {
        File('${tempDir.path}/Track.lrc')
            .writeAsStringSync('[00:10.00] Hand-curated\n');
        final repo = _StubRepo({
          'kugou': _word('Kugou KRC (Word-Sync)'),
          'apple_music': _line('Apple Music (Line-Sync)'),
        });
        final result = await repo.getLyrics(
          title: 'Track',
          artist: 'Artist',
          filePath: '${tempDir.path}/Track.flac',
          preferredProviderId: 'kugou',
        );
        expect(result.source, 'Local (.lrc)');
        expect(
          repo.calls,
          isEmpty,
          reason: 'manual picks keep the sidecar-first precedence',
        );
      },
    );

    test('a preferred word provider wins without Apple gating it', () async {
      final repo = _StubRepo({
        'kugou': _word('Kugou KRC (Word-Sync)'),
        'apple_music': _line('Apple Music (Line-Sync)'),
      });
      final result = await repo.getLyrics(
        title: 'T',
        artist: 'A',
        preferredProviderId: 'kugou',
      );
      expect(result.source, contains('Kugou'));
      expect(result.isWordSynced, isTrue);
      expect(
        repo.calls['apple_music'],
        isNull,
        reason:
            'the explicit pick resolves on its head-start hit; '
            'Apple never overrides a manual choice',
      );
    });
  });

  group('karaoke panel reaches the local sidecar', () {
    late Directory tempDir;
    late AppDatabase db;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('panel_sidecar');
      db = AppDatabase.inMemory();
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
      db.close();
    });

    test('waveLyricsProvider passes the local file path to the repo', () async {
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      final prefs = Prefs(sp);
      final trackPath = '${tempDir.path}/Track.flac';
      File(trackPath).writeAsBytesSync([0x00]);
      File('${tempDir.path}/Track.lrc')
          .writeAsStringSync('[00:10.00] Panel Sidecar\n');

      final repo = _RecordingRepo();
      final track = PlayableTrack(
        title: 'Track',
        artist: 'Artist',
        playbackUrl: trackPath,
      );
      final container = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          playbackServiceProvider.overrideWith((ref) {
            final dio = Dio();
            final service = PlaybackService(
              InnerTubeMusicApi(dio, SecureStore()),
              AddonApi(const []),
              ScrobbleRepository(
                LastFmApiService(dio, LastFmRateGuard()),
                prefs,
                db,
              ),
              DownloadManager(
                db,
                prefs,
                AddonApi(const []),
                InnerTubeMusicApi(dio, SecureStore()),
                LyricsRepository(Dio()),
              ),
              PrefsHandle(prefs),
              SessionStore(db),
              OfficialArtworkService(),
            );
            service.state = service.state.copyWith(
              current: track,
              queue: [track],
              currentIndex: 0,
            );
            ref.onDispose(service.disposePlayer);
            return service;
          }),
          lyricsRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(
        waveLyricsProvider(track.queueKey).future,
      );
      expect(
        result.source,
        'Local (.lrc)',
        reason:
            'the karaoke panel reaches the sidecar through the '
            'passed file path',
      );
      expect(repo.seenFilePaths, isNotEmpty);
      expect(repo.seenFilePaths.single, trackPath);
      expect(
        repo.providersHit,
        isTrue,
        reason:
            'Auto tried the remotes before falling back to the '
            'sidecar',
      );
    });
  });
}
