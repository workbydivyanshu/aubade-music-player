import 'dart:io';

import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/secure_store.dart';
import 'package:aubade/features/addons/addon_api.dart';
import 'package:aubade/features/downloads/download_manager.dart';
import 'package:aubade/features/innertube/innertube_api.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DownloadManager.delete() owns only the appended `.ext.lrc` sidecar it
/// wrote next to the audio. A separate extension-stripped `.lrc`
/// (Potentially a hand-curated or `saveLocalLrc`-written file) must
/// survive an audio deletion.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    tempDir = Directory.systemTemp.createTempSync('download_delete_sidecar');
    addTearDown(() => tempDir.deleteSync(recursive: true));
  });

  DownloadManager buildManager() => DownloadManager(
    db,
    prefs,
    AddonApi(const []),
    InnerTubeMusicApi(Dio(), SecureStore()),
    LyricsRepository(Dio()),
  );

  test('deleting a download removes the audio and its appended '
      '.ext.lrc only', () async {
    final audio = File('${tempDir.path}/Artist - Song.flac')
      ..writeAsBytesSync([0x00, 0x01, 0x02]);
    final appended = File('${audio.path}.lrc')
      ..writeAsStringSync('[00:01.00] Appended by the downloader\n');
    final stripped = File('${tempDir.path}/Artist - Song.lrc')
      ..writeAsStringSync('[00:10.00] User authored\n');
    expect(stripped.existsSync(), isTrue);

    // Seed the registry the manager restores its state from.
    db.raw.execute(
      'INSERT INTO downloaded_tracks(track_key, title, artist, file_path, '
      'lrc_file_path, downloaded_at_millis) VALUES(?, ?, ?, ?, ?, ?);',
      [
        DownloadManager.keyOf('Song', 'Artist'),
        'Song',
        'Artist',
        audio.path,
        appended.path,
        0,
      ],
    );

    final manager = buildManager();
    expect(manager.state.single.filePath, audio.path);

    await manager.delete(DownloadManager.keyOf('Song', 'Artist'));

    expect(manager.state, isEmpty);
    expect(
      audio.existsSync(),
      isFalse,
      reason: 'the downloaded audio file is removed',
    );
    expect(
      appended.existsSync(),
      isFalse,
      reason: "the downloader-owned appended '.ext.lrc' is removed",
    );
    expect(
      stripped.existsSync(),
      isTrue,
      reason:
          'a separate extension-stripped .lrc is never deleted with '
          'an audio download',
    );
  });

  test(
    'deleting is a no-op on the sidecars when the entry has no file',
    () async {
      db.raw.execute(
        'INSERT INTO downloaded_tracks(track_key, title, artist, file_path) '
        'VALUES(?, ?, ?, ?);',
        [DownloadManager.keyOf('Ghost', 'Artist'), 'Ghost', 'Artist', ''],
      );
      final manager = buildManager();
      await manager.delete(DownloadManager.keyOf('Ghost', 'Artist'));
      expect(manager.state, isEmpty);
    },
  );
}
