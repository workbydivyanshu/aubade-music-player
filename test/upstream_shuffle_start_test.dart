import 'dart:io';

import 'package:dio/dio.dart';
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

/// Regression coverage for the upstream LastWave fix d9716d0 (ported to
/// Aubade): `playQueue` clamps `startIndex`, but the `startShuffled`
/// branch looked the start track up with the raw value, so an
/// out-of-range start threw a RangeError instead of starting from the
/// clamped track. In-range starts behave exactly as before.
///
/// The test drives the real PlaybackService (media_kit player, vo=null)
/// and proves selection with the track lengths: each queue row is a
/// distinct-length silence WAV, so the duration mpv reports back is
/// evidence that the clamped intended media was actually opened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late AppDatabase db;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    tempDir = Directory.systemTemp.createTempSync('shuffle_start');
    addTearDown(() => tempDir.deleteSync(recursive: true));
  });

  List<int> le32(int v) => [
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  /// Writes a silent 8-bit mono WAV of [seconds]; mpv opens it without
  /// any network resolution, and reports the real length.
  String writeWav(String name, int seconds) {
    const sampleRate = 8000;
    final data = List<int>.filled(sampleRate * seconds, 0);
    final header = <int>[
      ...'RIFF'.codeUnits,
      ...le32(36 + data.length),
      ...'WAVE'.codeUnits,
      ...'fmt '.codeUnits,
      ...le32(16), // PCM fmt chunk size
      ...(const [1, 0]), // PCM
      ...(const [1, 0]), // mono
      ...le32(sampleRate),
      ...le32(sampleRate), // byte rate, one byte per sample
      ...(const [1, 0]), // block align
      ...(const [8, 0]), // bits per sample
      ...'data'.codeUnits,
      ...le32(data.length),
    ];
    final file = File('${tempDir.path}/$name.wav')
      ..writeAsBytesSync([...header, ...data]);
    return file.path;
  }

  List<PlayableTrack> buildTracks() => [
    PlayableTrack(
      title: 'First',
      artist: 'Test',
      playbackUrl: writeWav('first', 1),
    ),
    PlayableTrack(
      title: 'Second',
      artist: 'Test',
      playbackUrl: writeWav('second', 2),
    ),
    PlayableTrack(
      title: 'Third',
      artist: 'Test',
      playbackUrl: writeWav('third', 4),
    ),
  ];

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

  /// mpv reports the opened media length asynchronously; poll up to a
  /// generous deadline instead of racing it.
  Future<Duration> waitForDuration(
    PlaybackService service,
    bool Function(Duration) done,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var last = Duration.zero;
    while (DateTime.now().isBefore(deadline)) {
      last = service.state.duration;
      if (done(last)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail(
      'no mpv duration within the deadline; last=$last, '
      'error=${service.state.error}',
    );
  }

  /// Runs one shuffle start case against the real service and asserts:
  /// no RangeError from the awaited call, the shuffled queue is a
  /// permutation of the input, the clamped [expected] track owns
  /// `current` and `currentIndex`, and mpv reports a length inside
  /// [expected] track's unique window — evidence that the intended
  /// media was actually opened, not just placed in state.
  Future<void> runCase({
    required int startIndex,
    required PlayableTrack expected,
    required int openedMsMin,
    required int openedMsMax,
  }) async {
    final service = buildService();
    addTearDown(service.disposePlayer);
    final tracks = buildTracks();

    // This awaited call is the regression itself: pre-fix, an
    // out-of-range start threw a RangeError here.
    await service.playQueue(
      tracks,
      startIndex,
      startShuffled: true,
      sourceLabel: 'shuffle-start',
    );

    final queue = service.state.queue;
    expect(queue, hasLength(tracks.length));
    expect(
      queue.map((t) => t.queueKey).toSet(),
      tracks.map((t) => t.queueKey).toSet(),
      reason: 'the shuffled queue is a permutation of the input',
    );
    expect(service.state.shuffleEnabled, isTrue);
    // tracks[index], not tracks[startIndex]: the clamped value selects
    // the intended track.
    expect(service.state.current?.queueKey, expected.queueKey);
    expect(queue[service.state.currentIndex].queueKey, expected.queueKey);

    // And playback starts from it: mpv reports the opened media's real
    // length, and every queue row has its own distinct window.
    final duration = await waitForDuration(
      service,
      (d) => d.inMilliseconds >= openedMsMin,
    );
    expect(duration.inMilliseconds >= openedMsMin, isTrue);
    expect(
      duration.inMilliseconds < openedMsMax,
      isTrue,
      reason:
          'mpv opened the ${expected.title} media, not a different '
          'queue row',
    );
  }

  test('an out-of-range start shuffles from the clamped last track', () async {
    await runCase(
      startIndex: 42,
      expected: buildTracks()[2], // Third, 4s
      openedMsMin: 3500,
      openedMsMax: 5000,
    );
  });

  test('a negative start shuffles from the clamped first track', () async {
    await runCase(
      startIndex: -7,
      expected: buildTracks()[0], // First, 1s
      openedMsMin: 500,
      openedMsMax: 1500,
    );
  });

  test('an in-range start still shuffles from the requested track', () async {
    await runCase(
      startIndex: 1,
      expected: buildTracks()[1], // Second, 2s
      openedMsMin: 1500,
      openedMsMax: 3000,
    );
  });
}
