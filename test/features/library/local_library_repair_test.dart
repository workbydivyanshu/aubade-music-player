import 'dart:convert';
import 'dart:io';

import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/features/library/local_library_providers.dart';
import 'package:aubade/features/library/local_track.dart';
import 'package:aubade/features/search/shared_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal valid FLAC: STREAMINFO (194,376 ms at 48 kHz) plus Vorbis
/// comments carrying the same `bpm=null` payload as a yt-dlp download.
List<int> _taggedFlac() {
  final packed =
      (BigInt.from(48000) << 44) |
      (BigInt.from(1) << 41) |
      (BigInt.from(23) << 36) |
      BigInt.from(9330073);
  final streamInfo = <int>[
    0x10,
    0x00,
    0x10,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    for (var i = 7; i >= 0; i--)
      ((packed >> (i * 8)) & BigInt.from(0xFF)).toInt(),
    for (var i = 0; i < 16; i++) 0x00,
  ];

  final comments = <String>[
    'TITLE=Hit the Wall',
    'ARTIST=Gracie Abrams',
    'ALBUM=Daughter from Hell (Deluxe)',
    'ALBUMARTIST=Gracie Abrams',
    'TRACKNUMBER=1',
    'BPM=null',
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

  final out = <int>[0x66, 0x4C, 0x61, 0x43]; // 'fLaC'
  void block(int type, List<int> payload, {required bool last}) {
    out.addAll([
      (last ? 0x80 : 0x00) | type,
      (payload.length >> 16) & 0xFF,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
    ]);
    out.addAll(payload);
  }

  block(0, streamInfo, last: false);
  block(4, vorbis, last: true);
  return out;
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the repair scan');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one-shot repair re-reads degraded rows and marks the flag', () async {
    final dir = Directory.systemTemp.createTempSync('aubade_repair');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/01 - Hit the Wall.flac')
      ..writeAsBytesSync(_taggedFlac());
    final mtime = file.statSync().modified.millisecondsSinceEpoch;

    SharedPreferences.setMockInitialValues({
      'aubade_music_folders': [dir.path],
    });

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    db.insertOrUpdateLocalTracks([
      LocalTrack(
        path: file.path,
        title: '01 - Hit the Wall',
        artist: 'Unknown Artist',
        album: 'Unknown Album',
        albumArtist: '',
        duration: Duration.zero,
        format: 'flac',
        hasEmbeddedArt: false,
        modifiedAt: mtime,
      ),
    ]);

    final prefs = await Prefs.load();
    expect(prefs.libraryMetadataRepaired, isFalse);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        prefsProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    container.listen(localLibraryNotifierProvider, (_, _) {});

    await _waitFor(() => prefs.libraryMetadataRepaired);

    final repaired = db.getLocalTrackByPath(file.path);
    expect(repaired, isNotNull);
    expect(repaired!.title, 'Hit the Wall');
    expect(repaired.artist, 'Gracie Abrams');
    expect(repaired.album, 'Daughter from Hell (Deluxe)');
    expect(repaired.albumArtist, 'Gracie Abrams');
    expect(repaired.trackNumber, 1);
    expect(repaired.duration.inSeconds, 194);
    expect(repaired.format, 'flac');
  });
}
