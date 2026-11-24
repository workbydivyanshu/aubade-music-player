import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/features/library/audio_metadata_fallback.dart';
import 'package:aubade/features/library/local_scanner.dart';
import 'package:aubade/features/library/local_track.dart';
import 'package:aubade/features/library/stream_props.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a FLAC file carrying STREAMINFO + Vorbis comments (+ optional
/// PICTURE). No audio frames: metadata readers only look at the header.
List<int> _flacFile({
  int sampleRate = 48000,
  int channels = 2,
  int bits = 24,
  int totalSamples = 9330073,
  List<String> comments = const [],
  List<int>? picture,
  String pictureMime = 'image/jpeg',
}) {
  final packed =
      (BigInt.from(sampleRate) << 44) |
      (BigInt.from(channels - 1) << 41) |
      (BigInt.from(bits - 1) << 36) |
      BigInt.from(totalSamples);

  final streamInfo = <int>[
    0x10, 0x00, // min block size
    0x10, 0x00, // max block size
    0x00, 0x00, 0x00, // min frame size
    0x00, 0x00, 0x00, // max frame size
    for (var i = 7; i >= 0; i--)
      ((packed >> (i * 8)) & BigInt.from(0xFF)).toInt(),
    for (var i = 0; i < 16; i++) 0x00, // MD5
  ];

  final vendor = utf8.encode('aubade-test');
  final vorbis = <int>[];
  void le32(int value) => vorbis.addAll([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
  le32(vendor.length);
  vorbis.addAll(vendor);
  le32(comments.length);
  for (final comment in comments) {
    final encoded = utf8.encode(comment);
    le32(encoded.length);
    vorbis.addAll(encoded);
  }

  final blocks = <(int, List<int>)>[(0, streamInfo), (4, vorbis)];
  if (picture != null && picture.isNotEmpty) {
    final mime = utf8.encode(pictureMime);
    final picturePayload = <int>[];
    void u32(int value) => picturePayload.addAll([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
    u32(3); // Front cover.
    u32(mime.length);
    picturePayload.addAll(mime);
    u32(0); // Empty description.
    u32(1280); // Width.
    u32(1280); // Height.
    u32(24); // Depth.
    u32(0); // Indexed colors.
    u32(picture.length);
    picturePayload.addAll(picture);
    blocks.add((6, picturePayload));
  }

  final out = <int>[0x66, 0x4C, 0x61, 0x43]; // 'fLaC'
  for (var i = 0; i < blocks.length; i++) {
    final (type, payload) = blocks[i];
    final last = i == blocks.length - 1;
    out.addAll([
      (last ? 0x80 : 0x00) | type,
      (payload.length >> 16) & 0xFF,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
    ]);
    out.addAll(payload);
  }
  return out;
}

/// Builds a small ID3v2.3 file with text frames and an APIC picture.
List<int> _id3File({
  String title = 'ID3 Title',
  String artist = 'ID3 Artist',
  String album = 'ID3 Album',
  String albumArtist = 'ID3 Album Artist',
  String track = '3/12',
  String disc = '1/2',
  String year = '2026',
  String genre = 'Pop',
  String bpm = 'null',
  List<int>? picture,
}) {
  final frames = <int>[];
  void textFrame(String id, String value) {
    final payload = <int>[0, ...latin1.encode(value)];
    frames.addAll(ascii.encode(id));
    frames.addAll([
      (payload.length >> 24) & 0xFF,
      (payload.length >> 16) & 0xFF,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      0x00,
      0x00,
    ]);
    frames.addAll(payload);
  }

  textFrame('TIT2', title);
  textFrame('TPE1', artist);
  textFrame('TALB', album);
  textFrame('TPE2', albumArtist);
  textFrame('TRCK', track);
  textFrame('TPOS', disc);
  textFrame('TYER', year);
  textFrame('TCON', genre);
  textFrame('TBPM', bpm);

  if (picture != null && picture.isNotEmpty) {
    final payload = <int>[
      0, // ISO-8859-1
      ...latin1.encode('image/jpeg'),
      0,
      3, // Front cover.
      0, // Empty description.
      ...picture,
    ];
    frames.addAll(ascii.encode('APIC'));
    frames.addAll([
      (payload.length >> 24) & 0xFF,
      (payload.length >> 16) & 0xFF,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      0x00,
      0x00,
    ]);
    frames.addAll(payload);
  }

  final size = frames.length;
  final syncsafe = [
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
  ];
  return <int>[
    0x49, 0x44, 0x33, // 'ID3'
    0x03, 0x00, // v2.3.0
    0x00, // flags
    ...syncsafe,
    ...frames,
  ];
}

List<int> _wavFile({required int dataBytes}) {
  const channels = 2;
  const sampleRate = 48000;
  const bits = 24;
  final byteRate = sampleRate * channels * (bits ~/ 8);
  final blockAlign = channels * (bits ~/ 8);
  return <int>[
    0x52, 0x49, 0x46, 0x46, // 'RIFF'
    0x00, 0x00, 0x00, 0x00, // RIFF chunk size (unused by the reader)
    0x57, 0x41, 0x56, 0x45, // 'WAVE'
    0x66, 0x6D, 0x74, 0x20, // 'fmt '
    0x10, 0x00, 0x00, 0x00, // 16-byte fmt payload
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
    dataBytes & 0xFF,
    (dataBytes >> 8) & 0xFF,
    (dataBytes >> 16) & 0xFF,
    (dataBytes >> 24) & 0xFF,
  ];
}

void main() {
  group('readAudioMetadataFallback / FLAC', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('aubade_meta_flac');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('parses Vorbis comments and never throws on bpm=null', () async {
      final artwork = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final path = '${tempDir.path}/01 - Hit the Wall.flac';
      File(path).writeAsBytesSync(
        _flacFile(
          comments: [
            'TITLE=Hit the Wall',
            'ARTIST=Gracie Abrams',
            'ALBUM=Daughter from Hell (Deluxe)',
            'ALBUMARTIST=Gracie Abrams',
            'TRACKNUMBER=1',
            'DISCNUMBER=1',
            'DATE=2026-11-20',
            'GENRE=Pop',
            'BPM=null',
            'TBPM=null',
            'LYRICS=[00:01.00]First line',
          ],
          picture: artwork,
        ),
      );

      final metadata = await readAudioMetadataFallback(path);

      expect(metadata, isNotNull);
      expect(metadata!.title, 'Hit the Wall');
      expect(metadata.artist, 'Gracie Abrams');
      expect(metadata.album, 'Daughter from Hell (Deluxe)');
      expect(metadata.albumArtist, 'Gracie Abrams');
      expect(metadata.trackNumber, 1);
      expect(metadata.discNumber, 1);
      expect(metadata.year, 2026);
      expect(metadata.genre, 'Pop');
      expect(metadata.lyrics, contains('First line'));
      expect(
        metadata.bpm,
        isNull,
        reason: '"null" is not a number and must not throw',
      );
      expect(metadata.duration, const Duration(milliseconds: 194376));
      expect(metadata.hasPicture, isTrue);
      expect(metadata.picture, artwork);
      expect(metadata.pictureMimeType, 'image/jpeg');
      expect(metadata.pictureWidth, 1280);
    });

    test('accepts real numbers in bpm fields', () async {
      final path = '${tempDir.path}/tempo.flac';
      File(path).writeAsBytesSync(_flacFile(comments: ['BPM=120.5']));

      final metadata = await readAudioMetadataFallback(path);

      expect(metadata!.bpm, 120.5);
    });

    test('handles "N/A" and empty numeric values without throwing', () async {
      final path = '${tempDir.path}/weird.flac';
      File(path).writeAsBytesSync(
        _flacFile(comments: ['BPM=N/A', 'TRACKNUMBER=', 'DATE=not-a-date']),
      );

      final metadata = await readAudioMetadataFallback(path);

      expect(metadata, isNotNull);
      expect(metadata!.bpm, isNull);
      expect(metadata.trackNumber, isNull);
      expect(metadata.year, isNull);
    });

    test('returns null for non-metadata junk', () async {
      final path = '${tempDir.path}/junk.flac';
      File(path).writeAsStringSync('not a flac file');

      expect(await readAudioMetadataFallback(path), isNull);
    });
  });

  group('readAudioMetadataFallback / ID3v2', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('aubade_meta_id3');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reads text frames, track/disc totals and APIC safely', () async {
      final artwork = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDB, 9, 8, 7]);
      final path = '${tempDir.path}/tagged.mp3';
      File(path).writeAsBytesSync(_id3File(picture: artwork));

      final metadata = await readAudioMetadataFallback(path);

      expect(metadata, isNotNull);
      expect(metadata!.title, 'ID3 Title');
      expect(metadata.artist, 'ID3 Artist');
      expect(metadata.album, 'ID3 Album');
      expect(metadata.albumArtist, 'ID3 Album Artist');
      expect(metadata.trackNumber, 3);
      expect(metadata.discNumber, 1);
      expect(metadata.year, 2026);
      expect(metadata.genre, 'Pop');
      expect(metadata.bpm, isNull);
      expect(metadata.picture, artwork);
      expect(metadata.pictureMimeType, 'image/jpeg');
    });
  });

  group('parseTrackFilename', () {
    test('strips the leading track number and separator', () {
      final parsed = parseTrackFilename('01 - Hit the Wall');
      expect(parsed.trackNumber, 1);
      expect(parsed.title, 'Hit the Wall');
    });

    test('handles dot, underscore and mixed separators', () {
      expect(parseTrackFilename('02. Death Wish').trackNumber, 2);
      expect(parseTrackFilename('02. Death Wish').title, 'Death Wish');
      expect(parseTrackFilename('03_The Knife').trackNumber, 3);
      expect(parseTrackFilename('03_The Knife').title, 'The Knife');
      expect(
        parseTrackFilename('04 -Look at My Life').title,
        'Look at My Life',
      );
    });

    test('keeps a leading year as the title when no name follows', () {
      final parsed = parseTrackFilename('1979');
      expect(parsed.trackNumber, isNull);
      expect(parsed.title, '1979');
    });

    test('leaves ordinary titles untouched', () {
      final parsed = parseTrackFilename('Corrupted Song');
      expect(parsed.trackNumber, isNull);
      expect(parsed.title, 'Corrupted Song');
    });
  });

  group('inferFolderMetadata', () {
    test('reads "Album - Artist" folders', () {
      final inferred = inferFolderMetadata(
        '/music/Daughter from Hell (Deluxe) - Gracie Abrams/01 - Hit the Wall.flac',
      );
      expect(inferred.album, 'Daughter from Hell (Deluxe)');
      expect(inferred.artist, 'Gracie Abrams');
    });

    test('reads "Artist/Album" folders', () {
      final inferred = inferFolderMetadata(
        '/music/Gracie Abrams/Daughter from Hell (Deluxe)/01 - Hit the Wall.flac',
      );
      expect(inferred.album, 'Daughter from Hell (Deluxe)');
      expect(inferred.artist, 'Gracie Abrams');
    });

    test('ignores generic roots and home directories', () {
      expect(inferFolderMetadata('/home/someone/Music/song.mp3').album, isNull);
      expect(
        inferFolderMetadata('/tmp/scan_folders_test/song.mp3').artist,
        isNull,
      );
    });
  });

  group('header duration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('aubade_duration');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('FLAC STREAMINFO duration matches total samples', () {
      final path = '${tempDir.path}/tone.flac';
      File(path).writeAsBytesSync(_flacFile());

      final props = readStreamPropsSync(path);

      expect(props.sampleRate, 48000);
      expect(props.bitDepth, 24);
      expect(props.channels, 2);
      expect(props.durationMs, 194376);
    });

    test('WAV duration is data size divided by byte rate', () {
      final path = '${tempDir.path}/tone.wav';
      // 1 second of 48 kHz / 24-bit / stereo PCM.
      const dataBytes = 48000 * 2 * 3;
      File(path).writeAsBytesSync(_wavFile(dataBytes: dataBytes));

      final props = readStreamPropsSync(path);

      expect(props.sampleRate, 48000);
      expect(props.bitDepth, 24);
      expect(props.durationMs, 1000);
    });
  });

  group('scanner integration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('aubade_scan_meta');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('a FLAC with bpm=null keeps tags, duration and artwork', () async {
      final albumDir = Directory(
        '${tempDir.path}/Daughter from Hell (Deluxe) - Gracie Abrams',
      )..createSync(recursive: true);
      final artwork = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]);
      List<String> commentsFor(int track, String title) => [
        'TITLE=$title',
        'ARTIST=Gracie Abrams',
        'ALBUM=Daughter from Hell (Deluxe)',
        'ALBUMARTIST=Gracie Abrams',
        'TRACKNUMBER=$track',
        'BPM=null',
        'TBPM=null',
      ];

      final one = File('${albumDir.path}/01 - Hit the Wall.flac')
        ..writeAsBytesSync(
          _flacFile(comments: commentsFor(1, 'Hit the Wall'), picture: artwork),
        );
      final two = File('${albumDir.path}/02 - Death Wish.flac')
        ..writeAsBytesSync(
          _flacFile(comments: commentsFor(2, 'Death Wish'), picture: artwork),
        );

      final artCache = Directory('${tempDir.path}/art')..createSync();
      final tracks = await scanFolders([
        tempDir.path,
      ], artCacheDirOverride: artCache);

      expect(tracks, hasLength(2));
      final byPath = {for (final track in tracks) track.path: track};
      final hit = byPath[one.path]!;
      expect(hit.title, 'Hit the Wall');
      expect(hit.artist, 'Gracie Abrams');
      expect(hit.album, 'Daughter from Hell (Deluxe)');
      expect(hit.albumArtist, 'Gracie Abrams');
      expect(hit.trackNumber, 1);
      expect(hit.duration.inSeconds, 194);
      expect(hit.sampleRate, 48000);
      expect(hit.bitDepth, 24);
      expect(hit.hasEmbeddedArt, isTrue);
      expect(hit.artworkPath, isNotNull);
      expect(File(hit.artworkPath!).existsSync(), isTrue);

      expect(byPath[two.path]!.title, 'Death Wish');
      expect(byPath[two.path]!.trackNumber, 2);

      expect(
        hit.artworkPath,
        byPath[two.path]!.artworkPath,
        reason: 'one album shares one extracted cover file',
      );
      final cachedFiles = artCache.listSync().whereType<File>().toList();
      expect(
        cachedFiles,
        hasLength(1),
        reason: '20-track album writes its cover once, not once per track',
      );
    });

    test('forceRescanPaths re-reads an otherwise mtime-skipped file', () async {
      final file = File('${tempDir.path}/keep.mp3')..writeAsBytesSync([0x00]);
      final first = await scanFolders([tempDir.path]);
      expect(first, hasLength(1));

      final timestamps = {
        file.path: file.statSync().modified.millisecondsSinceEpoch,
      };
      expect(
        await scanFolders([tempDir.path], existingTimestamps: timestamps),
        isEmpty,
        reason: 'unchanged mtime takes the fast path',
      );
      expect(
        await scanFolders(
          [tempDir.path],
          existingTimestamps: timestamps,
          forceRescanPaths: {file.path},
        ),
        hasLength(1),
        reason: 'repaired rows must bypass the mtime fast path',
      );
    });
  });

  group('degraded metadata repair', () {
    test('flags rows with Unknown Artist/Album or zero duration', () {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      db.insertOrUpdateLocalTracks([
        LocalTrack(
          path: '/music/broken.flac',
          title: '01 - Hit the Wall',
          artist: 'Unknown Artist',
          album: 'Unknown Album',
          albumArtist: '',
          duration: Duration.zero,
          format: 'flac',
          hasEmbeddedArt: false,
          modifiedAt: 1,
        ),
        LocalTrack(
          path: '/music/good.flac',
          title: 'Good',
          artist: 'Gracie Abrams',
          album: 'Daughter from Hell (Deluxe)',
          albumArtist: 'Gracie Abrams',
          duration: const Duration(minutes: 3),
          format: 'flac',
          hasEmbeddedArt: true,
          modifiedAt: 1,
        ),
      ]);

      expect(db.getLocalTrackPathsNeedingMetadataRepair(), {
        '/music/broken.flac',
      });
    });
  });
}
