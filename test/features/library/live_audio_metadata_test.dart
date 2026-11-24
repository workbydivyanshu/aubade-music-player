@Tags(['live'])
library;

import 'dart:io';

import 'package:aubade/features/library/audio_metadata_fallback.dart';
import 'package:aubade/features/library/local_scanner.dart';
import 'package:aubade/features/library/stream_props.dart';
import 'package:flutter_test/flutter_test.dart';

/// LIVE on-disk verification against a real Rhythmax/yt-dlp FLAC whose
/// Vorbis comments contain `bpm=null` / `TBPM=null` — the exact payload
/// that makes the audiotags Rust bridge panic.
///
/// Run explicitly:
///   flutter test test/features/library/live_audio_metadata_test.dart
///
/// Excluded from the default suite (`--exclude-tags=live`) because it
/// depends on a file outside the repository.
const String _albumDir =
    '/home/whocares/Music/a literal roller coaster/'
    'Daughter from Hell (Deluxe) - Gracie Abrams';
const String _trackPath = '$_albumDir/01 - Hit the Wall.flac';

void main() {
  test('reads the real bpm=null FLAC without FFI panics', () async {
    if (!File(_trackPath).existsSync()) {
      markTestSkipped('Live FLAC not present at $_trackPath');
      return;
    }

    final metadata = await readAudioMetadataFallback(_trackPath);

    expect(metadata, isNotNull);
    expect(metadata!.title, 'Hit the Wall');
    expect(metadata.artist, 'Gracie Abrams');
    expect(metadata.album, 'Daughter from Hell (Deluxe)');
    expect(metadata.albumArtist, 'Gracie Abrams');
    expect(metadata.trackNumber, 1);
    expect(metadata.discNumber, 1);
    expect(metadata.year, 2026);
    expect(metadata.bpm, isNull);
    expect(metadata.hasPicture, isTrue);
    expect(metadata.picture, isNotNull);
    expect(metadata.picture!.length, greaterThan(1000));
    expect(metadata.duration.inSeconds, 194);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('STREAMINFO gives the exact 3:14 duration', () {
    if (!File(_trackPath).existsSync()) {
      markTestSkipped('Live FLAC not present at $_trackPath');
      return;
    }

    final props = readStreamPropsSync(_trackPath);

    expect(props.sampleRate, 48000);
    expect(props.bitDepth, 24);
    expect(props.channels, 2);
    expect(props.durationMs, 194376);
  });

  test(
    'scanner surfaces title/artist/album/duration/artwork/bitrate',
    () async {
      if (!File(_trackPath).existsSync()) {
        markTestSkipped('Live FLAC not present at $_trackPath');
        return;
      }

      final artCache = Directory.systemTemp.createTempSync('aubade_live_art');
      try {
        final tracks = await scanFolders([
          _albumDir,
        ], artCacheDirOverride: artCache);

        final hit = tracks.where((track) => track.path == _trackPath).single;
        expect(hit.title, 'Hit the Wall');
        expect(hit.artist, 'Gracie Abrams');
        expect(hit.album, 'Daughter from Hell (Deluxe)');
        expect(hit.trackNumber, 1);
        expect(hit.duration.inSeconds, 194);
        expect(hit.duration.inMilliseconds, inInclusiveRange(193000, 195000));
        expect(hit.sampleRate, 48000);
        expect(hit.bitDepth, 24);
        expect(hit.hasEmbeddedArt, isTrue);
        expect(hit.artworkPath, isNotNull);
        expect(File(hit.artworkPath!).existsSync(), isTrue);
        expect(File(hit.artworkPath!).lengthSync(), greaterThan(1000));
        expect(hit.bitrate, isNotNull);
        expect(hit.bitrate!, inInclusiveRange(1500, 1800));

        // One shared cover for the whole album, not one file per track.
        final artworkPaths = tracks.map((track) => track.artworkPath).toSet();
        expect(artworkPaths, hasLength(1));
        final cachedFiles = artCache.listSync().whereType<File>().toList();
        expect(cachedFiles, hasLength(1));
        expect(tracks, hasLength(greaterThan(1)));
      } finally {
        artCache.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
