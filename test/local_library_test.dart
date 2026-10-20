import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/features/library/local_scanner.dart';
import 'package:aubade/features/library/local_track.dart';
import 'package:aubade/features/library/stream_props.dart';
import 'package:aubade/features/lyrics/lyrics_models.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';

/// Repository subclass that fails loudly on any provider (network) call,
/// so tests can assert the sidecar path never touches the network.
class _NoNetworkLyricsRepository extends LyricsRepository {
  bool providersHit = false;

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

/// Canonical 44-byte PCM WAV header: RIFF → fmt (16 bytes) → empty data.
List<int> _wavFixture({
  int channels = 2,
  int sampleRate = 96000,
  int bits = 24,
}) {
  final byteRate = sampleRate * channels * (bits ~/ 8);
  final blockAlign = channels * (bits ~/ 8);
  return <int>[
    0x52, 0x49, 0x46, 0x46, // 'RIFF'
    0x24, 0x00, 0x00, 0x00, // RIFF chunk size (36)
    0x57, 0x41, 0x56, 0x45, // 'WAVE'
    0x66, 0x6D, 0x74, 0x20, // 'fmt '
    0x10, 0x00, 0x00, 0x00, // fmt chunk size (16)
    0x01, 0x00, // PCM
    channels & 0xFF, (channels >> 8) & 0xFF,
    sampleRate & 0xFF,
    (sampleRate >> 8) & 0xFF,
    (sampleRate >> 16) & 0xFF,
    (sampleRate >> 24) & 0xFF,
    byteRate & 0xFF,
    (byteRate >> 8) & 0xFF,
    (byteRate >> 16) & 0xFF,
    (byteRate >> 24) & 0xFF,
    blockAlign & 0xFF, (blockAlign >> 8) & 0xFF,
    bits & 0xFF, (bits >> 8) & 0xFF,
    0x64, 0x61, 0x74, 0x61, // 'data'
    0x00, 0x00, 0x00, 0x00, // 0 samples
  ];
}

/// Valid-enough FLAC: 'fLaC' + first STREAMINFO block (34-byte payload)
/// with the canonical 20-bit rate / 3-bit channels / 5-bit depth / 36-bit
/// total-samples packing at payload offset 10.
List<int> _flacFixture({
  int sampleRate = 96000,
  int channels = 2,
  int bits = 24,
}) {
  final packed = (BigInt.from(sampleRate) << 44) |
      (BigInt.from(channels - 1) << 41) |
      (BigInt.from(bits - 1) << 36) |
      BigInt.from(11520000);
  return <int>[
    0x66, 0x4C, 0x61, 0x43, // 'fLaC'
    0x00, 0x00, 0x00, 0x22, // STREAMINFO, 34-byte payload
    0x10, 0x00, // min block size (4096)
    0x10, 0x00, // max block size (4096)
    0x00, 0x00, 0x00, // min frame size
    0x00, 0x00, 0x00, // max frame size
    for (var i = 7; i >= 0; i--)
      ((packed >> (i * 8)) & BigInt.from(0xFF)).toInt(),
    for (var i = 0; i < 16; i++) 0x00, // MD5
  ];
}

void main() {
  group('formatLrc', () {
    test('formats lines as [mm:ss.xx] with zero padding', () {
      final lrc = formatLrc([
        const LyricLine(timeMs: 1_000, text: 'First'),
        const LyricLine(timeMs: 65_230, text: 'Second'),
        const LyricLine(timeMs: 3_720_920, text: 'Late'),
      ]);
      final entries = lrc.split('\n');
      expect(entries.length, 3);
      expect(RegExp(r'^\[00:01\.00\] First$').hasMatch(entries[0]), isTrue,
          reason: 'got ${entries[0]}');
      expect(RegExp(r'^\[01:05\.23\] Second$').hasMatch(entries[1]), isTrue,
          reason: 'got ${entries[1]}');
      expect(RegExp(r'^\[62:00\.92\] Late$').hasMatch(entries[2]), isTrue,
          reason: 'got ${entries[2]}');
      // Every entry matches the canonical [mm:ss.xx] shape.
      for (final e in entries) {
        expect(RegExp(r'^\[\d{2}:\d{2}\.\d{2}\] ').hasMatch(e), isTrue);
      }
    });

    test('round-trips through parseLrc', () {
      final lines = [
        const LyricLine(timeMs: 0, text: 'Intro'),
        const LyricLine(timeMs: 12_345, text: 'Verse line'),
        const LyricLine(timeMs: 121_000, text: 'Chorus'),
      ];
      final parsed = parseLrc(formatLrc(lines));
      expect(parsed.length, 3);
      expect(parsed.map((l) => l.text), lines.map((l) => l.text));
      for (var i = 0; i < 3; i++) {
        expect((parsed[i].timeMs - lines[i].timeMs).abs(), lessThan(50),
            reason: 'line $i timing drifted');
      }
    });
  });

  group('.lrc sidecar', () {
    late Directory tempDir;
    late LyricsRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('lrc_sidecar_test');
      repo = _NoNetworkLyricsRepository();
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('getLyrics loads a sidecar .lrc and never hits providers', () async {
      File('${tempDir.path}/Song.lrc').writeAsStringSync(
        'Other tag line\n'
        '[00:10.00] Hello world\n'
        '[00:12.50] Second line\n',
      );
      final result = await repo.getLyrics(
        title: 'Song',
        artist: 'Artist',
        filePath: '${tempDir.path}/Song.mp3',
      );
      expect(result.source, 'Local (.lrc)');
      expect(result.isSynced, isTrue);
      expect(result.plainLyrics, 'Hello world\nSecond line');
      expect(result.lines.first.timeMs, 10_000);
      final noNet = repo as _NoNetworkLyricsRepository;
      expect(noNet.providersHit, isFalse,
          reason: 'valid local .lrc must short-circuit the network');
    });

    test('missing sidecar falls through without error', () async {
      final result = await repo.getLyrics(
        title: 'No Sidecar',
        artist: 'Artist',
        filePath: '${tempDir.path}/missing.mp3',
      );
      final noNet = repo as _NoNetworkLyricsRepository;
      expect(noNet.providersHit, isTrue);
      expect(result.isEmpty, isTrue);
    });

    test('saveLocalLrc writes a valid .lrc for synced lyrics', () async {
      final path = '${tempDir.path}/Track.flac';
      final saved = await repo.saveLocalLrc(
        filePath: path,
        lyrics: const LyricsResult(
          lines: [
            LyricLine(timeMs: 15_000, text: 'Rebuilt line'),
            LyricLine(timeMs: 42_100, text: 'Another line'),
          ],
          isSynced: true,
        ),
      );
      expect(saved, isTrue);
      final sidecarFile = File('${tempDir.path}/Track.lrc');
      expect(sidecarFile.existsSync(), isTrue);
      final content = sidecarFile.readAsStringSync();
      expect(
        RegExp(r'^\[00:15\.00\] Rebuilt line$', multiLine: true)
            .hasMatch(content),
        isTrue,
        reason: 'got: $content',
      );
      final parsed = parseLrc(content);
      expect(parsed.map((l) => l.text).toList(),
          ['Rebuilt line', 'Another line']);
      expect(parsed.first.timeMs, 15_000);
    });

    test('saveLocalLrc skips plain/empty lyrics', () async {
      final path = '${tempDir.path}/NoSync.flac';
      final saved = await repo.saveLocalLrc(
        filePath: path,
        lyrics: const LyricsResult(isSynced: false, plainLyrics: 'plain'),
      );
      expect(saved, isFalse);
      expect(File('${tempDir.path}/NoSync.lrc').existsSync(), isFalse);
    });
  });

  group('LocalTrack serialization', () {
    test('toMap/fromMap round-trips every field', () {
      final original = LocalTrack(
        path: '/music/Artist/Album/01 Song.flac',
        title: 'Song One',
        artist: 'The Artist',
        album: 'The Album',
        albumArtist: 'Album Artist',
        trackNumber: 1,
        discNumber: 2,
        year: 2021,
        genre: 'Rock',
        duration: const Duration(minutes: 3, seconds: 45),
        bitrate: 1411,
        sampleRate: 44100,
        format: 'flac',
        artworkPath: '/music/Artist/Album/cover.jpg',
        hasEmbeddedArt: true,
        modifiedAt: 1_700_000_000_000,
      );

      final back = LocalTrack.fromMap(original.toMap());

      expect(back.path, original.path);
      expect(back.title, original.title);
      expect(back.artist, original.artist);
      expect(back.album, original.album);
      expect(back.albumArtist, original.albumArtist);
      expect(back.trackNumber, original.trackNumber);
      expect(back.discNumber, original.discNumber);
      expect(back.year, original.year);
      expect(back.genre, original.genre);
      expect(back.duration, original.duration);
      expect(back.bitrate, original.bitrate);
      expect(back.sampleRate, original.sampleRate);
      expect(back.format, original.format);
      expect(back.artworkPath, original.artworkPath);
      expect(back.hasEmbeddedArt, original.hasEmbeddedArt);
      expect(back.modifiedAt, original.modifiedAt);
    });

    test('fromMap tolerates nullable columns and missing keys', () {
      final back = LocalTrack.fromMap({
        'path': '/music/a.mp3',
        'title': 'T',
        'artist': 'A',
        'album': 'B',
        'album_artist': null,
        'duration_ms': 123456,
        'format': 'mp3',
        'has_embedded_art': 0,
        'modified_at': 0,
      });

      expect(back.path, '/music/a.mp3');
      expect(back.albumArtist, '');
      expect(back.trackNumber, isNull);
      expect(back.duration, const Duration(milliseconds: 123456));
      expect(back.bitrate, isNull);
      expect(back.sampleRate, isNull);
      expect(back.genre, isNull);
      expect(back.artworkPath, isNull);
      expect(back.hasEmbeddedArt, isFalse);
    });

    test('toMap stores booleans as 0/1 and duration as ms', () {
      final track = LocalTrack(
        path: '/x.mp3',
        title: 'T',
        artist: 'A',
        album: 'B',
        albumArtist: 'AA',
        duration: const Duration(seconds: 7),
        format: 'mp3',
        hasEmbeddedArt: false,
        modifiedAt: 9,
      );
      final map = track.toMap();

      expect(map['duration_ms'], 7000);
      expect(map['has_embedded_art'], 0);
      expect(map['modified_at'], 9);
    });
  });

  group('LocalTrack.toPlayableTrack', () {
    test('maps fields to a queue item with file:// artwork url', () {
      final track = LocalTrack(
        path: '/music/song.mp3',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        albumArtist: 'AA',
        duration: const Duration(seconds: 1),
        format: 'mp3',
        artworkPath: '/music/cover.jpg',
        hasEmbeddedArt: false,
        modifiedAt: 0,
      );

      final playable = track.toPlayableTrack();

      expect(playable, isA<PlayableTrack>());
      expect(playable.title, 'Title');
      expect(playable.artist, 'Artist');
      expect(playable.album, 'Album');
      expect(playable.playbackUrl, '/music/song.mp3');
      expect(playable.artworkUrl, 'file:///music/cover.jpg');
      expect(playable.mediaId, 'local:/music/song.mp3');
    });

    test('artworkUrl is empty when there is no artwork path', () {
      final track = LocalTrack(
        path: '/music/song.mp3',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        albumArtist: 'AA',
        duration: const Duration(seconds: 1),
        format: 'mp3',
        artworkPath: null,
        hasEmbeddedArt: false,
        modifiedAt: 0,
      );

      expect(track.toPlayableTrack().artworkUrl, '');
    });
  });

  group('AppDatabase.inMemory() local tracks', () {
    test('insertOrUpdateLocalTracks then getAllLocalTracks round-trips', () {
      final db = AppDatabase.inMemory();
      try {
        expect(db.getAllLocalTracks(), isEmpty);

        final tracks = [
          LocalTrack(
            path: '/music/b.mp3',
            title: 'B Track',
            artist: 'Artist B',
            album: 'Album B',
            albumArtist: 'AA B',
            duration: const Duration(minutes: 2),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/music/a.mp3',
            title: 'A Track',
            artist: 'Artist A',
            album: 'Album A',
            albumArtist: 'AA A',
            trackNumber: 3,
            year: 2020,
            duration: const Duration(minutes: 5),
            format: 'flac',
            hasEmbeddedArt: true,
            modifiedAt: 2,
          ),
        ];
        db.insertOrUpdateLocalTracks(tracks);

        final all = db.getAllLocalTracks();
        expect(all.length, 2);
        // Ordered by album_artist, album, track_number, title.
        expect(all[0].path, '/music/a.mp3');
        expect(all[0].trackNumber, 3);
        expect(all[0].year, 2020);
        expect(all[1].path, '/music/b.mp3');

        // Update one track in place (same path = upsert).
        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: '/music/a.mp3',
            title: 'A Track (Remix)',
            artist: 'Artist A',
            album: 'Album A',
            albumArtist: 'AA A',
            duration: const Duration(minutes: 6),
            format: 'flac',
            hasEmbeddedArt: true,
            modifiedAt: 3,
          ),
        ]);
        final updated = db.getAllLocalTracks();
        expect(updated.length, 2);
        expect(updated.firstWhere((t) => t.path == '/music/a.mp3').title,
            'A Track (Remix)');
      } finally {
        db.close();
      }
    });

    test('getLocalArtists groups tracks by artist', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: '/music/a1.mp3',
            title: 'T1',
            artist: 'Artist A',
            album: 'Album X',
            albumArtist: 'AA',
            duration: const Duration(minutes: 1),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/music/a2.mp3',
            title: 'T2',
            artist: 'Artist A',
            album: 'Album X',
            albumArtist: 'AA',
            duration: const Duration(minutes: 1),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/music/b1.mp3',
            title: 'T3',
            artist: 'Artist B',
            album: 'Album Y',
            albumArtist: 'AA',
            duration: const Duration(minutes: 1),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
        ]);

        final artists = db.getLocalArtists();
        expect(artists.length, 2);
        expect(artists[0]['artist'], 'Artist A');
        expect(artists[0]['track_count'], 2);
        expect(artists[1]['artist'], 'Artist B');
        expect(artists[1]['track_count'], 1);
      } finally {
        db.close();
      }
    });

    test('deleteLocalTracksNotIn removes only missing paths', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: '/music/keep.mp3',
            title: 'Keep',
            artist: 'Artist',
            album: 'Album',
            albumArtist: 'AA',
            duration: const Duration(minutes: 1),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/music/drop.mp3',
            title: 'Drop',
            artist: 'Artist',
            album: 'Album',
            albumArtist: 'AA',
            duration: const Duration(minutes: 1),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
        ]);

        db.deleteLocalTracksNotIn({'/music/keep.mp3'});
        final remaining = db.getAllLocalTracks();
        expect(remaining.length, 1);
        expect(remaining.first.path, '/music/keep.mp3');

        // Empty set wipes the table.
        db.deleteLocalTracksNotIn({});
        expect(db.getAllLocalTracks(), isEmpty);
      } finally {
        db.close();
      }
    });
  });

  group('duration unit correctness', () {
    // The pre-0.01.07 scanner stored audiotags' true-seconds duration
    // straight into `duration_ms` (1000x too small). The v9 migration
    // repairs those legacy rows in place. No migration-rung test
    // precedent exists in this suite, and AppDatabase.inMemory() runs
    // _migrate() before any row can be seeded, so the repair statement
    // is exercised at the SQL level through the public raw handle.
    test('v9 repair scales legacy second-counts to milliseconds', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: '/music/legacy.mp3',
            title: 'Legacy',
            artist: 'Artist',
            album: 'Album',
            albumArtist: 'Artist',
            // Value the old buggy scanner wrote for a 4:05 track:
            // true seconds (245) mislabeled as milliseconds.
            duration: const Duration(milliseconds: 245),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/music/legacy-zero.mp3',
            title: 'Legacy Zero',
            artist: 'Artist',
            album: 'Album',
            albumArtist: 'Artist',
            // Tag-less rows stored 0; the guard must leave them be.
            duration: Duration.zero,
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
        ]);

        // Same statement as the v9 ladder block in AppDatabase._migrate().
        db.raw.execute(
            'UPDATE local_tracks SET duration_ms = duration_ms * 1000 '
            'WHERE duration_ms > 0 AND duration_ms < 3600000;');

        final byPath = {for (final t in db.getAllLocalTracks()) t.path: t};
        expect(byPath['/music/legacy.mp3']!.duration,
            const Duration(milliseconds: 245000),
            reason: 'second-count 245 must become 245000 ms (4:05)');
        expect(byPath['/music/legacy-zero.mp3']!.duration, Duration.zero,
            reason: 'zero-length rows stay zero (duration_ms > 0 guard)');
      } finally {
        db.close();
      }
    });
  });

  group('scanFolders', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('scan_folders_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('skips non-audio files and picks up supported extensions', () async {
      // Non-audio: must be ignored.
      File('${tempDir.path}/notes.txt').writeAsStringSync('text');
      File('${tempDir.path}/script.py').writeAsStringSync('print(1)');
      File('${tempDir.path}/readme.md').writeAsStringSync('# hi');
      File('${tempDir.path}/cover.jpg').writeAsStringSync('jpeg');

      // Supported: one dummy file per extension.
      final extensions = [
        '.mp3',
        '.flac',
        '.wav',
        '.m4a',
        '.opus',
        '.ogg',
      ];
      final expected = <String>{};
      for (final ext in extensions) {
        final path = '${tempDir.path}/sample$ext';
        File(path).writeAsBytesSync([0x00, 0x01, 0x02]); // dummy, not audio
        expected.add(path);
      }

      final tracks = await scanFolders([tempDir.path]);

      expect(tracks.map((t) => t.path).toSet(), expected,
          reason: 'only supported audio extensions survive the scan');
    });

    test('picks up a companion cover.jpg and sets artworkPath', () async {
      final trackDir = Directory('${tempDir.path}/album')..createSync();
      File('${trackDir.path}/song.mp3').writeAsBytesSync([0x00, 0x01, 0x02]);
      File('${trackDir.path}/cover.jpg').writeAsBytesSync([0xFF, 0xD8, 0xFF]);

      final tracks = await scanFolders([tempDir.path]);

      expect(tracks, hasLength(1));
      expect(tracks.single.artworkPath, '${trackDir.path}/cover.jpg',
          reason: 'companion cover.jpg next to the track wins');
    });

    test('tolerates corrupted/dummy audio files '
        '(Tauon-style basename fallback)', () async {
      final a = File('${tempDir.path}/Corrupted Song.mp3')
        ..writeAsBytesSync([0x00, 0x01, 0x02, 0x03]);
      final b = File('${tempDir.path}/Also Broken.flac')
        ..writeAsStringSync('this is not really a flac');

      final tracks = await scanFolders([tempDir.path]);

      expect(tracks, hasLength(2)); // did not crash or drop the files
      final byPath = {for (final t in tracks) t.path: t};
      expect(byPath[a.path]!.title, 'Corrupted Song',
          reason: 'basename is the fallback title when tags are unreadable');
      expect(byPath[b.path]!.title, 'Also Broken');
      expect(byPath[a.path]!.artist, 'Unknown Artist');
      expect(byPath[b.path]!.album, 'Unknown Album');
      expect(byPath[a.path]!.duration, Duration.zero);
    });

    test('scans multiple folders and dedupes by file path', () async {
      final dirA = Directory('${tempDir.path}/music_a')
        ..createSync(recursive: true);
      final dirB = Directory('${tempDir.path}/music_b')..createSync();
      final nested = Directory('${dirA.path}/nested')..createSync();
      File('${dirA.path}/one.mp3').writeAsBytesSync([0x00]);
      File('${nested.path}/two.flac').writeAsBytesSync([0x00]);
      File('${dirB.path}/three.opus').writeAsBytesSync([0x00]);

      // dirA is listed twice; dirA/nested is covered both by dirA's
      // recursive walk and as its own folder. Every file must appear once.
      final tracks = await scanFolders(
        [dirA.path, dirB.path, dirA.path, nested.path],
      );

      expect(tracks.map((t) => t.path).toList(), unorderedEquals([
        '${dirA.path}/one.mp3',
        '${nested.path}/two.flac',
        '${dirB.path}/three.opus',
      ]));
      expect(tracks.where((t) => t.path.endsWith('two.flac')), hasLength(1),
          reason: 'same file seen through two folders must not be duplicated');
    });

    test('emits incremental batches via onBatch and onProgress', () async {
      for (var i = 0; i < 5; i++) {
        File('${tempDir.path}/track_$i.mp3').writeAsBytesSync([0x00]);
      }

      final emittedBatches = <List<LocalTrack>>[];
      var progressCalls = 0;

      final tracks = await scanFolders(
        [tempDir.path],
        batchSize: 2,
        onBatch: (batch, count) {
          emittedBatches.add(batch);
        },
        onProgress: (count) {
          progressCalls++;
        },
      );

      expect(tracks.length, 5);
      expect(progressCalls, 5);
      // With 5 items and batchSize 2, batches are 2 + 2 + 1 = 3 batches.
      expect(emittedBatches.length, 3);
      expect(emittedBatches[0].length, 2);
      expect(emittedBatches[1].length, 2);
      expect(emittedBatches[2].length, 1);
    });

    test('mtime-matching files are not re-read but stay alive for pruning',
        () async {
      final paths = <String>[];
      for (var i = 0; i < 3; i++) {
        final path = '${tempDir.path}/keep_$i.mp3';
        File(path).writeAsBytesSync([0x00]); // dummy, not audio
        paths.add(path);
      }

      final first = await scanFolders([tempDir.path]);
      expect(first, hasLength(3)); // control: full scan finds all three

      final timestamps = {
        for (final t in first)
          t.path: File(t.path).statSync().modified.millisecondsSinceEpoch,
      };

      var batchCalls = 0;
      final alive = <String>{};
      final second = await scanFolders(
        [tempDir.path],
        existingTimestamps: timestamps,
        alivePaths: alive,
        onBatch: (batch, count) => batchCalls++,
      );

      expect(second, isEmpty, reason: 'unchanged mtimes skip the tag re-read');
      expect(batchCalls, 0, reason: 'skipped files emit no batches');
      expect(alive, hasLength(3));
      expect(alive, containsAll(paths));
    });

    test('changed files rescan while unchanged files skip', () async {
      final changed = File('${tempDir.path}/changed.mp3')
        ..writeAsBytesSync([0x00]);
      final stableA = File('${tempDir.path}/stable_a.mp3')
        ..writeAsBytesSync([0x00]);
      final stableB = File('${tempDir.path}/stable_b.flac')
        ..writeAsBytesSync([0x00]);

      final first = await scanFolders([tempDir.path]);
      expect(first, hasLength(3)); // control: no timestamps, full scan

      // Modify exactly one file so its on-disk mtime moves on.
      changed.writeAsBytesSync([0x01, 0x02, 0x03]);

      // Fresh statSync snapshots for the untouched files; the changed
      // file gets an intentionally wrong value so it must be re-read.
      final timestamps = {
        stableA.path: stableA.statSync().modified.millisecondsSinceEpoch,
        stableB.path: stableB.statSync().modified.millisecondsSinceEpoch,
        changed.path: changed.statSync().modified.millisecondsSinceEpoch -
            1000000,
      };

      final alive = <String>{};
      final second = await scanFolders(
        [tempDir.path],
        existingTimestamps: timestamps,
        alivePaths: alive,
      );

      expect(second, hasLength(1));
      expect(second.single.path, changed.path,
          reason: 'only the file whose mtime moved is re-read');
      expect(alive, hasLength(3));
      expect(alive, containsAll([changed.path, stableA.path, stableB.path]));
    });

    test('concurrent pool keeps dedupe + correct sorted order across chunks',
        () async {
      final dirA = Directory('${tempDir.path}/pool_a')
        ..createSync(recursive: true);
      final dirB = Directory('${tempDir.path}/pool_b')..createSync();
      final nested = Directory('${dirA.path}/nested')..createSync();

      // ~20 dummy files spread across the dirs, mix of extensions.
      final expected = <String>{};
      for (var i = 0; i < 8; i++) {
        final path = '${dirA.path}/a_$i.mp3';
        File(path).writeAsBytesSync([0x00]);
        expected.add(path);
      }
      for (var i = 0; i < 6; i++) {
        final path = '${nested.path}/n_$i.flac';
        File(path).writeAsBytesSync([0x00]);
        expected.add(path);
      }
      for (var i = 0; i < 6; i++) {
        final path = '${dirB.path}/b_$i.opus';
        File(path).writeAsBytesSync([0x00]);
        expected.add(path);
      }

      // dirA is listed twice; dirA/nested is covered both by dirA's
      // recursive walk and as its own folder.
      final batches = <List<LocalTrack>>[];
      var lastTotalSoFar = 0;
      final tracks = await scanFolders(
        [dirA.path, dirB.path, dirA.path, nested.path],
        batchSize: 3,
        onBatch: (batch, totalSoFar) {
          batches.add(batch);
          expect(totalSoFar, greaterThanOrEqualTo(lastTotalSoFar),
              reason: 'totalSoFar must never decrease across batches');
          lastTotalSoFar = totalSoFar;
        },
      );

      expect(tracks, hasLength(expected.length));
      expect(tracks.map((t) => t.path).toSet(), expected,
          reason: 'each unique path appears exactly once');
      expect(
        tracks.map((t) => t.path),
        equals([...tracks.map((t) => t.path)]..sort()),
        reason: 'final list is sorted by path',
      );

      final emitted = batches.fold<int>(0, (sum, b) => sum + b.length);
      expect(emitted, tracks.length,
          reason: 'batches cover every track exactly once');
      for (var i = 0; i < batches.length - 1; i++) {
        expect(batches[i], hasLength(3),
            reason: 'flushes before the last one hold exactly batchSize');
      }
      expect(batches.last, isNotEmpty);
      expect(batches.last.length, lessThanOrEqualTo(3));
      for (final batch in batches) {
        expect(batch.length, lessThanOrEqualTo(3));
      }
    });

    test('alivePaths is complete even on fresh scan without timestamps',
        () async {
      final a = File('${tempDir.path}/alive_a.mp3')..writeAsBytesSync([0x00]);
      final b = File('${tempDir.path}/alive_b.flac')..writeAsBytesSync([0x00]);
      File('${tempDir.path}/not_audio.txt').writeAsStringSync('nope');

      final alive = <String>{};
      final tracks = await scanFolders([tempDir.path], alivePaths: alive);

      expect(alive, {a.path, b.path});
      expect(alive, tracks.map((t) => t.path).toSet());
    });
  });

  group('AppDatabase.searchLocalTracks', () {
    final db = AppDatabase.inMemory();

    /// Minimal row helper for search seeding.
    LocalTrack seed(String path,
            {required String title,
            required String artist,
            required String album}) =>
        LocalTrack(
          path: path,
          title: title,
          artist: artist,
          album: album,
          albumArtist: artist,
          duration: const Duration(minutes: 3),
          format: 'mp3',
          hasEmbeddedArt: false,
          modifiedAt: 0,
        );

    setUp(() {
      db.insertOrUpdateLocalTracks([
        // Titles: one exact, one prefix, one contains-only hit.
        seed('/music/s1.mp3',
            title: 'Nightcall', artist: 'Kavinsky', album: 'Outrun'),
        seed('/music/s2.mp3',
            title: 'Nightcall Drive',
            artist: 'Drive Club',
            album: 'Retrospace'),
        seed('/music/s3.mp3',
            title: 'Not Nightcall Live',
            artist: 'Other Band',
            album: 'Globals'),
        // Artist-only match (title/album share no token with the query).
        seed('/music/s4.mp3',
            title: 'Sunset',
            artist: 'Kavinsky',
            album: 'Outrun'),
        // Album-only match.
        seed('/music/s5.mp3',
            title: 'Endless',
            artist: 'Somebody',
            album: 'Midnight City Sessions'),
      ]);
    });

    tearDownAll(() {
      db.close();
    });

    test('matches on title (case-insensitive)', () {
      final hits = db.searchLocalTracks('nightcall');
      expect(hits.map((t) => t.path).toSet(),
          {'/music/s1.mp3', '/music/s2.mp3', '/music/s3.mp3'});
    });

    test('matches on artist', () {
      final hits = db.searchLocalTracks('kavinsky');
      expect(hits.map((t) => t.path).toSet(),
          {'/music/s1.mp3', '/music/s4.mp3'});
    });

    test('matches on album', () {
      final hits = db.searchLocalTracks('midnight city');
      expect(hits, hasLength(1));
      expect(hits.single.path, '/music/s5.mp3');
    });

    test('ranks exact, then prefix, then contains', () {
      final hits = db.searchLocalTracks('nightcall');
      expect(hits.map((t) => t.path).toList(), [
        '/music/s1.mp3', // exact title match
        '/music/s2.mp3', // title prefix match
        '/music/s3.mp3', // contains-only match
      ]);
    });

    test('empty query returns nothing', () {
      expect(db.searchLocalTracks(''), isEmpty);
      expect(db.searchLocalTracks('   '), isEmpty);
    });

    test('LIKE wildcards in the query are literal', () {
      // None of the seeded titles/artists/albums contain % or _.
      expect(db.searchLocalTracks('%'), isEmpty);
      expect(db.searchLocalTracks('_'), isEmpty);
    });

    test('respects the limit (default 100)', () {
      db.insertOrUpdateLocalTracks([
        for (var i = 0; i < 105; i++)
          seed('/music/bulk$i.mp3',
              title: 'Limitless $i', artist: 'Bulk', album: 'Bulk Album'),
      ]);
      final hits = db.searchLocalTracks('limitless');
      expect(hits.length, 100);
      // Explicit limit also works.
      expect(db.searchLocalTracks('limitless', limit: 7).length, 7);
    });
  });

  group('local discovery queries', () {
    /// Row helper with every constructor field explicit (path is
    /// unique per test; each test gets its own in-memory db).
    LocalTrack seed(
      String path, {
      required String title,
      String artist = 'Discovery Artist',
      String album = 'Discovery Album',
      String albumArtist = 'Discovery Artist',
      int? trackNumber,
      int? year,
      String? genre,
      int? bitrate,
      int? sampleRate,
      String format = 'mp3',
      String? artworkPath,
      int modifiedAt = 0,
    }) =>
        LocalTrack(
          path: path,
          title: title,
          artist: artist,
          album: album,
          albumArtist: albumArtist,
          trackNumber: trackNumber,
          discNumber: null,
          year: year,
          genre: genre,
          duration: const Duration(minutes: 3),
          bitrate: bitrate,
          sampleRate: sampleRate,
          format: format,
          artworkPath: artworkPath,
          hasEmbeddedArt: false,
          modifiedAt: modifiedAt,
        );

    test('getLocalGenres groups non-blank genres with counts', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/g/rock1.mp3',
              title: 'R1',
              album: 'Rock Album A',
              genre: 'Rock',
              artworkPath: '/art/rock.jpg'),
          seed('/g/rock2.mp3',
              title: 'R2', album: 'Rock Album A', genre: 'Rock'),
          seed('/g/rock3.mp3',
              title: 'R3', album: 'Rock Album B', genre: 'Rock'),
          seed('/g/jazz1.mp3',
              title: 'J1', album: 'Jazz Album', genre: 'Jazz'),
          seed('/g/nogenre.mp3', title: 'N1', album: 'Unknown Album'),
          seed('/g/blank.mp3',
              title: 'B1', album: 'Unknown Album', genre: '  '),
        ]);

        final genres = db.getLocalGenres();
        expect(genres, hasLength(2));
        expect(genres[0]['genre'], 'Rock');
        expect(genres[0]['track_count'], 3);
        expect(genres[0]['album_count'], 2);
        expect(genres[0]['artwork_path'], '/art/rock.jpg',
            reason: 'MAX aggregate picks the one non-null artwork path');
        expect(genres[1]['genre'], 'Jazz');
        expect(genres[1]['track_count'], 1);
        expect(genres[1]['album_count'], 1);
      } finally {
        db.close();
      }
    });

    test('getLocalDecades buckets years and drops out-of-range ones', () {
      final db = AppDatabase.inMemory();
      try {
        final years = <int?>[
          1977, 1985, 1985, 1999, 2019, 2020, 2013, null, 1899, 2100,
        ];
        db.insertOrUpdateLocalTracks([
          for (var i = 0; i < years.length; i++)
            seed('/d/t$i.mp3', title: 'Track $i', year: years[i]),
        ]);

        final decades = db.getLocalDecades();
        expect(decades.map((r) => r['decade']).toList(),
            [2020, 2010, 1990, 1980, 1970]);
        // 2020 -> 1; 2019 + 2013 -> 2010; 1999 -> 1990; 1985 x2 -> 1980;
        // 1977 -> 1970. Null / 1899 / 2100 excluded.
        expect(decades.map((r) => r['track_count']).toList(),
            [1, 2, 1, 2, 1]);
      } finally {
        db.close();
      }
    });

    test('getLocalFormatStats counts formats, most tracks first', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/f/flac1.flac', title: 'F1', format: 'flac'),
          seed('/f/flac2.flac', title: 'F2', format: 'flac'),
          seed('/f/flac3.flac', title: 'F3', format: 'flac'),
          seed('/f/mp3a.mp3', title: 'M1', format: 'mp3'),
          seed('/f/mp3b.mp3', title: 'M2', format: 'mp3'),
          seed('/f/ogg1.ogg', title: 'O1', format: 'ogg'),
        ]);

        final stats = db.getLocalFormatStats();
        expect(stats.map((r) => r['format']).toList(),
            ['flac', 'mp3', 'ogg']);
        expect(stats.map((r) => r['track_count']).toList(), [3, 2, 1]);
      } finally {
        db.close();
      }
    });

    test('searchLocalAlbums ranks and aggregates per album', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/a/abbey1.mp3',
              title: 'Come Together',
              album: 'Abbey Road',
              albumArtist: 'The Beatles',
              year: 1969,
              artworkPath: '/art/abbey.jpg'),
          seed('/a/abbey2.mp3',
              title: 'Something',
              album: 'Abbey Road',
              albumArtist: 'The Beatles',
              year: 1969),
          seed('/a/abbey3.mp3',
              title: 'Maxwell',
              album: 'Abbey Road',
              albumArtist: 'The Beatles',
              year: 1969),
          seed('/a/aqualung1.mp3',
              title: 'Aqualung',
              album: 'Aqualung',
              albumArtist: 'Jethro Tull',
              year: 1971),
          seed('/a/aqualung2.mp3',
              title: 'Cross-Eyed Mary',
              album: 'Aqualung',
              albumArtist: 'Jethro Tull',
              year: 1971),
          seed('/a/wish1.mp3',
              title: 'Shine On',
              album: 'Wish You Were Here',
              albumArtist: 'Pink Floyd',
              year: 1975),
        ]);

        final aq = db.searchLocalAlbums('aq');
        expect(aq, hasLength(1));
        expect(aq.first['album'], 'Aqualung');
        expect(aq.first['track_count'], 2);

        final road = db.searchLocalAlbums('ROAD');
        expect(road, hasLength(1),
            reason: 'case-insensitive substring match');
        expect(road.first['album'], 'Abbey Road');
        expect(road.first['album_artist'], 'The Beatles');
        expect(road.first['year'], 1969);
        expect(road.first['artwork_path'], '/art/abbey.jpg');
        expect(road.first['track_count'], 3);

        expect(db.searchLocalAlbums(''), isEmpty);
        expect(db.searchLocalAlbums('   '), isEmpty);
        expect(db.searchLocalArtists(''), isEmpty);
        expect(db.searchLocalTracks('   '), isEmpty);

        expect(db.searchLocalAlbums('e', limit: 1), hasLength(1));
      } finally {
        db.close();
      }
    });

    test('searchLocalArtists ranks and aggregates per artist', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/s/pf1.mp3',
              title: 'PF1',
              artist: 'Pink Floyd',
              album: 'The Wall',
              year: 1979),
          seed('/s/pf2.mp3',
              title: 'PF2', artist: 'Pink Floyd', album: 'The Wall'),
          seed('/s/pf3.mp3',
              title: 'PF3', artist: 'Pink Floyd', album: 'Animals'),
          seed('/s/lz1.mp3',
              title: 'LZ1', artist: 'Led Zeppelin', album: 'IV'),
          seed('/s/lz2.mp3',
              title: 'LZ2', artist: 'Led Zeppelin', album: 'IV'),
          seed('/s/tb1.mp3',
              title: 'TB1', artist: 'The Beatles', album: 'Revolver'),
        ]);

        final pink = db.searchLocalArtists('pink');
        expect(pink, hasLength(1));
        expect(pink.first['artist'], 'Pink Floyd');
        expect(pink.first['track_count'], 3);

        final zeppelin = db.searchLocalArtists('ZEpp');
        expect(zeppelin, hasLength(1),
            reason: 'case-insensitive substring match');
        expect(zeppelin.first['artist'], 'Led Zeppelin');
        expect(zeppelin.first['track_count'], 2);

        expect(db.searchLocalArtists(''), isEmpty);
        expect(db.searchLocalArtists('   '), isEmpty);

        // 'l' matches all three artists; the limit still caps to one.
        expect(db.searchLocalArtists('l', limit: 1), hasLength(1));
      } finally {
        db.close();
      }
    });

    test('getLocalTracksForGenre is case-insensitive and trimmed', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/t/rock1.mp3', title: 'R1', album: 'A', genre: 'Rock'),
          seed('/t/rock2.mp3', title: 'R2', album: 'A', genre: ' Rock'),
          seed('/t/rock3.mp3', title: 'R3', album: 'B', genre: 'ROCK'),
          seed('/t/jazz1.mp3', title: 'J1', album: 'C', genre: 'Jazz'),
          seed('/t/none1.mp3', title: 'N1', album: 'C'),
          seed('/t/blank1.mp3', title: 'B1', album: 'C', genre: '  '),
        ]);

        final rock = db.getLocalTracksForGenre('RoCk');
        expect(rock.map((t) => t.path).toSet(),
            {'/t/rock1.mp3', '/t/rock2.mp3', '/t/rock3.mp3'},
            reason: 'only Rock rows, padded/lower/upper variants included');

        expect(db.getLocalTracksForGenre('Polka'), isEmpty);
      } finally {
        db.close();
      }
    });

    test('getLocalTracksForDecade and getLocalTracksForYearRange', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/y/1977.mp3',
              title: 'T77', year: 1977, album: 'Seventies'),
          seed('/y/1985a.mp3',
              title: 'T85a', year: 1985, album: 'Eighties'),
          seed('/y/1985b.mp3',
              title: 'T85b', year: 1985, album: 'Eighties'),
          seed('/y/1999.mp3',
              title: 'T99', year: 1999, album: 'Nineties'),
        ]);

        final eighties = db.getLocalTracksForDecade(1980);
        expect(eighties.map((t) => t.path).toSet(),
            {'/y/1985a.mp3', '/y/1985b.mp3'},
            reason: '1980-1989 bucket only');

        // Range is inclusive: 1900..1989 keeps both 1985 tracks and the
        // 1977 one (year DESC, then canonical), but not 1999.
        final classics = db.getLocalTracksForYearRange(1900, 1989);
        expect(classics.map((t) => t.path).toList(),
            ['/y/1985a.mp3', '/y/1985b.mp3', '/y/1977.mp3']);
      } finally {
        db.close();
      }
    });

    test('getLocalHiResTracks gates on format and quality', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/h/flac96.flac',
              title: 'H1', format: 'flac', sampleRate: 96000),
          seed('/h/flac44.flac',
              title: 'H2', format: 'flac', sampleRate: 44100),
          seed('/h/wav1210.wav',
              title: 'H3', format: 'wav', bitrate: 1210),
          seed('/h/mp396.mp3',
              title: 'H4', format: 'mp3', sampleRate: 96000),
          seed('/h/flacnull.flac', title: 'H5', format: 'flac'),
        ]);

        expect(
          db.getLocalHiResTracks().map((t) => t.path).toSet(),
          {'/h/flac96.flac', '/h/wav1210.wav'},
          reason: 'CD-quality flac, mp3 and null-quality flac stay out',
        );
      } finally {
        db.close();
      }
    });

    test('getLocalRecentTracks orders by modified_at desc and limits', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/r/old.mp3', title: 'Old', modifiedAt: 1700000000000),
          seed('/r/new.mp3', title: 'New', modifiedAt: 1700000005000),
        ]);

        final recent = db.getLocalRecentTracks();
        expect(recent.map((t) => t.path).toList(),
            ['/r/new.mp3', '/r/old.mp3']);
        expect(db.getLocalRecentTracks(limit: 1).single.path, '/r/new.mp3');
      } finally {
        db.close();
      }
    });

    test('getLocalGenres merges canonical genre aliases into one row', () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/canon/hh1.mp3',
              title: 'H1',
              album: 'Street A',
              genre: 'Rap/Hip Hop',
              artworkPath: '/art/rap.jpg'),
          seed('/canon/hh2.mp3',
              title: 'H2', album: 'Street A', genre: 'Hip-Hop/Rap'),
          seed('/canon/hh3.mp3', title: 'H3', album: 'Street B', genre: 'Rap'),
          seed('/canon/hh4.mp3',
              title: 'H4', album: 'Street C', genre: 'Hip Hop'),
          seed('/canon/rock1.mp3',
              title: 'R1', album: 'Rock Album', genre: 'Rock'),
        ]);

        final genres = db.getLocalGenres();
        expect(genres, hasLength(2),
            reason: 'the four rap aliases collapse into one canonical row');
        final hipHop = genres.first;
        expect(hipHop['genre'], 'Hip-Hop / Rap');
        expect(hipHop['track_count'], 4,
            reason: 'counts sum across every alias');
        expect(hipHop['album_count'], 3,
            reason: 'Street A is tagged under two aliases but unions once');
        expect(hipHop['artwork_path'], '/art/rap.jpg',
            reason: 'the alias MAX artwork survives canonicalization');
        expect(genres.last['genre'], 'Rock',
            reason: 'identity genres stay untouched');
        expect(genres.last['track_count'], 1);
      } finally {
        db.close();
      }
    });

    test('getLocalTracksForGenre matches every alias of a canonical family',
        () {
      final db = AppDatabase.inMemory();
      try {
        db.insertOrUpdateLocalTracks([
          seed('/alias/a1.mp3',
              title: 'A1',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 1,
              genre: 'Hip-Hop / Rap'),
          seed('/alias/a2.mp3',
              title: 'A2',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 2,
              genre: 'RAP/hip hop'),
          seed('/alias/a3.mp3',
              title: 'A3',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 3,
              genre: ' hip-hop/rap '),
          seed('/alias/a4.mp3',
              title: 'A4',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 4,
              genre: 'rAp'),
          seed('/alias/a5.mp3',
              title: 'A5',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 5,
              genre: 'HIP HOP'),
          seed('/alias/rock.mp3',
              title: 'R1',
              albumArtist: 'Alias',
              album: 'Union',
              trackNumber: 6,
              genre: 'Rock'),
        ]);

        final tracks = db.getLocalTracksForGenre('Hip-Hop / Rap');
        expect(tracks.map((t) => t.path).toList(), [
          '/alias/a1.mp3',
          '/alias/a2.mp3',
          '/alias/a3.mp3',
          '/alias/a4.mp3',
          '/alias/a5.mp3',
        ], reason: 'all five aliases match; the Rock row stays out');
      } finally {
        db.close();
      }
    });
  });

  group('offline scrobble queue', () {
    test('insert, pending order + limit, delete by id, count', () {
      final db = AppDatabase.inMemory();
      try {
        expect(db.countPendingOfflineScrobbles(), 0);
        expect(db.getPendingOfflineScrobbles(), isEmpty);

        db.insertOfflineScrobble(
            artist: 'A', track: 'First', timestamp: 1000);
        db.insertOfflineScrobble(
            artist: 'B',
            track: 'Second',
            album: 'Alb',
            albumArtist: 'AA',
            timestamp: 2000,
            duration: 180);
        db.insertOfflineScrobble(
            artist: 'C', track: 'Third', timestamp: 3000);

        expect(db.countPendingOfflineScrobbles(), 3);

        final pending = db.getPendingOfflineScrobbles();
        expect(pending.map((r) => r['track']).toList(),
            ['First', 'Second', 'Third'],
            reason: 'oldest-first insertion order (created_at, id)');
        expect(pending[1]['album'], 'Alb');
        expect(pending[1]['album_artist'], 'AA');
        expect(pending[1]['timestamp'], 2000);
        expect(pending[1]['duration'], 180);
        expect(pending[0]['album'], '',
            reason: 'empty optional fields keep their column defaults');

        final limited = db.getPendingOfflineScrobbles(limit: 2);
        expect(limited.map((r) => r['track']).toList(), ['First', 'Second'],
            reason: 'LIMIT keeps the oldest rows');

        // Delete exactly the given ids; the third row survives.
        db.deleteOfflineScrobbles(
            limited.map((r) => (r['id'] as num).toInt()).toList());
        expect(db.countPendingOfflineScrobbles(), 1);
        expect(db.getPendingOfflineScrobbles().single['track'], 'Third');

        // Empty id list is a no-op.
        db.deleteOfflineScrobbles(const []);
        expect(db.countPendingOfflineScrobbles(), 1);

        db.deleteOfflineScrobbles(
            [(db.getPendingOfflineScrobbles().single['id'] as num).toInt()]);
        expect(db.countPendingOfflineScrobbles(), 0);
        expect(db.getPendingOfflineScrobbles(), isEmpty);
      } finally {
        db.close();
      }
    });

    test('PlayableTrack JSON round-trips albumArtist + durationSeconds', () {
      const track = PlayableTrack(
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        albumArtist: 'Album Artist',
        videoId: 'abc123',
        durationSeconds: 245,
      );

      final restored = PlayableTrack.fromJson(track.toJson());
      expect(restored.albumArtist, 'Album Artist');
      expect(restored.durationSeconds, 245);
      expect(restored.videoId, 'abc123');
      expect(restored.queueKey, track.queueKey);

      // Legacy payloads missing the new keys default to '' / 0.
      final legacy = PlayableTrack.fromJson(
          const {'title': 'T', 'artist': 'A'});
      expect(legacy.albumArtist, '');
      expect(legacy.durationSeconds, 0);
    });
  });

  group('stream props and vault', () {
    test('readStreamPropsSync decodes a canonical WAV fmt chunk', () {
      final dir = Directory.systemTemp.createTempSync('stream_props_wav');
      try {
        final path = '${dir.path}/tone.wav';
        File(path).writeAsBytesSync(_wavFixture());

        final props = readStreamPropsSync(path);
        expect(props.sampleRate, 96000);
        expect(props.channels, 2);
        expect(props.bitDepth, 24);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('readStreamPropsSync decodes FLAC STREAMINFO', () {
      final dir = Directory.systemTemp.createTempSync('stream_props_flac');
      try {
        final path = '${dir.path}/tone.flac';
        File(path).writeAsBytesSync(_flacFixture());

        final props = readStreamPropsSync(path);
        expect(props.sampleRate, 96000,
            reason: '20-bit rate from bytes 18-20');
        expect(props.channels, 2, reason: '3-bit channels-1');
        expect(props.bitDepth, 24, reason: '5-bit depth-1 spans 20-21');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('readStreamPropsSync never invents values for junk files', () {
      final dir = Directory.systemTemp.createTempSync('stream_props_junk');
      try {
        final path = '${dir.path}/noise.mp3';
        File(path).writeAsBytesSync(List<int>.generate(200, (i) => i & 0xFF));

        final props = readStreamPropsSync(path);
        expect(props.sampleRate, 0);
        expect(props.bitDepth, 0);
        expect(props.channels, 0);

        // Missing file is equally silent.
        final gone = readStreamPropsSync('${dir.path}/gone.flac');
        expect(gone.sampleRate, 0);
        expect(gone.bitDepth, 0);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('backfill UPDATE shape fills null stream props on a real WAV', () {
      final db = AppDatabase.inMemory();
      final dir = Directory.systemTemp.createTempSync('stream_props_bf');
      try {
        final path = '${dir.path}/tone.wav';
        File(path).writeAsBytesSync(_wavFixture());

        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: path,
            title: 'Tone',
            artist: 'Artist',
            album: 'Album',
            albumArtist: 'Artist',
            duration: const Duration(minutes: 4),
            format: 'wav',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
        ]);
        final before = db.getLocalTrackByPath(path);
        expect(before, isNotNull);
        expect(before!.sampleRate, isNull);
        expect(before.bitDepth, isNull);
        expect(before.sizeBytes, isNull);

        // Same statement shape as backfillStreamPropsOnceIfNeeded.
        final props = readStreamPropsSync(path);
        final size = File(path).lengthSync();
        final durationMs = before.duration.inMilliseconds;
        final bitrate = (size * 8 / durationMs).round().clamp(0, 100000);
        db.raw.execute(
          'UPDATE local_tracks SET sample_rate = ?, bit_depth = ?, '
          'bitrate = ?, size_bytes = ? WHERE path = ?;',
          [props.sampleRate, props.bitDepth, bitrate, size, path],
        );

        final after = db.getLocalTrackByPath(path);
        expect(after, isNotNull);
        expect(after!.sampleRate, 96000);
        expect(after.bitDepth, 24);
        expect(after.sizeBytes, size);
        // New columns survive the map round-trip.
        final restored = LocalTrack.fromMap(after.toMap());
        expect(restored.bitDepth, 24);
        expect(restored.sizeBytes, size);

        // `sample_rate > 48000 OR bit_depth > 16` now catches it.
        expect(db.getLocalHiResTracks().map((t) => t.path).toList(), [path]);
      } finally {
        dir.deleteSync(recursive: true);
        db.close();
      }
    });

    test('loadVaultAnalytics folds plays, durations, streak and hourly',
        () {
      final db = AppDatabase.inMemory();
      try {
        final now = DateTime.now();
        final nowMs = now.millisecondsSinceEpoch;
        final yesterday = DateTime(now.year, now.month, now.day - 1);
        final threeDaysAgo = DateTime(now.year, now.month, now.day - 3);

        db.insertOrUpdateLocalTracks([
          LocalTrack(
            path: '/v/long.flac',
            title: 'Long',
            artist: 'Artist A',
            album: 'A',
            albumArtist: 'Artist A',
            duration: const Duration(minutes: 4),
            format: 'flac',
            sampleRate: 96000,
            bitDepth: 24,
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
          LocalTrack(
            path: '/v/short.mp3',
            title: 'Short',
            artist: 'Artist B',
            album: 'B',
            albumArtist: 'Artist B',
            duration: const Duration(minutes: 2),
            format: 'mp3',
            hasEmbeddedArt: false,
            modifiedAt: 1,
          ),
        ]);

        // Five plays: Long now x2 + yesterday, Short now, Ghost 3 days
        // ago (no local_tracks row -> contributes 0 ms).
        final plays = <({String title, String artist, int at})>[
          (title: 'Long', artist: 'Artist A', at: nowMs - 60000),
          (title: 'Long', artist: 'Artist A', at: nowMs - 30000),
          (
            title: 'Long',
            artist: 'Artist A',
            at: yesterday.millisecondsSinceEpoch + 3600000
          ),
          (title: 'Short', artist: 'Artist B', at: nowMs - 20000),
          (
            title: 'Ghost',
            artist: 'Artist Z',
            at: threeDaysAgo.millisecondsSinceEpoch + 3600000
          ),
        ];
        for (final p in plays) {
          db.raw.execute(
            'INSERT INTO local_plays (title, artist, played_at_millis) '
            'VALUES (?, ?, ?);',
            [p.title, p.artist, p.at],
          );
        }

        // Offline scrobbles: one duplicate of the first Long play
        // (+10 s -> skipped) and one fresh Artist C play (+180 s).
        db.insertOfflineScrobble(
          artist: 'Artist A',
          track: 'Long',
          timestamp: ((nowMs - 60000) ~/ 1000) + 10,
          duration: 240,
        );
        final freshAtMs = nowMs;
        db.insertOfflineScrobble(
          artist: 'Artist C',
          track: 'Fresh',
          timestamp: freshAtMs ~/ 1000,
          duration: 180,
        );

        final analytics = db.loadVaultAnalytics();

        // 5 plays + the fresh scrobble; duplicate scrobble folded out.
        expect(analytics.allTimePlays, 6);
        // Longer durations: 3x4min + 2min local + 3min scrobble.
        expect(analytics.allTimeMinutes, 17);
        expect(analytics.weekMinutes, 17);

        expect(analytics.topTracks.first.title, 'Long');
        expect(analytics.topTracks.first.plays, 3);
        expect(analytics.topTracks.first.ms, 3 * 240000);
        expect(analytics.topTracks.first.format, 'flac');
        expect(analytics.topTracks.first.sampleRate, 96000);
        expect(analytics.topTracks.first.bitDepth, 24);
        expect(
            analytics.topTracks.map((t) => t.title).toSet(),
            containsAll(<String>['Long', 'Short', 'Ghost']));
        expect(
            analytics.topTracks.firstWhere((t) => t.title == 'Ghost').ms, 0,
            reason: 'unmatched titles contribute no duration');

        expect(analytics.topArtists.first.artist, 'Artist A');
        expect(analytics.topArtists.first.plays, 3);

        // The fresh scrobble is folded into the top lists too (and the
        // duplicate one is not).
        final freshTop =
            analytics.topTracks.firstWhere((t) => t.title == 'Fresh');
        expect(freshTop.plays, 1);
        expect(freshTop.ms, 180000);
        expect(
            analytics.topArtists.map((a) => a.artist), contains('Artist C'));

        // Streak: today + yesterday, then a gap, then day-3 -> 2.
        expect(analytics.streakDays, 2);

        // Hourly: local-hour buckets of every play + fresh scrobble.
        expect(analytics.hourlyPlays, hasLength(24));
        final expectedHourly = List<int>.filled(24, 0);
        for (final p in plays) {
          expectedHourly[DateTime.fromMillisecondsSinceEpoch(p.at).hour] += 1;
        }
        expectedHourly[
            DateTime.fromMillisecondsSinceEpoch(freshAtMs).hour] += 1;
        expect(analytics.hourlyPlays, expectedHourly);

        // Fidelity: flac/96k/24 + mp3 in the library.
        expect(analytics.totalCount, 2);
        expect(analytics.losslessCount, 1);
        expect(analytics.lossyCount, 1);
        expect(analytics.hiresCount, 1);
        expect(analytics.topSampleRates, [
          <String, int>{'sample_rate': 96000, 'count': 1},
        ]);
      } finally {
        db.close();
      }
    });

    test('loadVaultAnalytics stays quiet on an empty database', () {
      final db = AppDatabase.inMemory();
      try {
        final analytics = db.loadVaultAnalytics();
        expect(analytics.allTimePlays, 0);
        expect(analytics.allTimeMinutes, 0);
        expect(analytics.topTracks, isEmpty);
        expect(analytics.topArtists, isEmpty);
        expect(analytics.hourlyPlays, List<int>.filled(24, 0));
        expect(analytics.streakDays, 0);
        expect(analytics.totalCount, 0);
        expect(analytics.topSampleRates, isEmpty);
      } finally {
        db.close();
      }
    });
  });
}
