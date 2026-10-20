import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:aubade/core/storage/prefs.dart';

/// In-memory store whose writes to selected keys can be made to fail,
/// mimicking a platform `setX` that returns false.
class _FlakyStore extends InMemorySharedPreferencesStore {
  _FlakyStore(super.data) : super.withData();

  final Set<String> failingKeys = <String>{};

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failingKeys.contains(key)) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  group('legacy prefs migration', () {
    test('moves lw_* keys to aubade_* and preserves their values', () async {
      SharedPreferences.setMockInitialValues({
        'lw_lastfm_api_key': 'api-key',
        'lw_guest_mode': true,
        'lw_accent': 0xFF1E88E5,
        'lw_accent_mode': 'artwork',
        'lw_amoled': true,
        'lw_theme_mode': 'light',
        'lw_recent_searches': ['rain', 'aurora'],
        'lw_download_dir': 'D:/Music',
        'lw_lyrics_offset_track/1': 250,
      });

      final prefs = await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(prefs.lastFmApiKey, 'api-key');
      expect(prefs.isGuest, isTrue);
      expect(prefs.accentColor, 0xFF1E88E5);
      expect(prefs.accentSource, 'artwork');
      expect(prefs.amoled, isTrue);
      expect(prefs.themeMode, 'light');
      expect(prefs.recentSearches, ['rain', 'aurora']);
      expect(prefs.downloadDir, 'D:/Music');
      expect(prefs.getLyricsOffset('track/1'), 250);

      expect(sp.getInt('aubade_accent'), 0xFF1E88E5);
      expect(sp.getStringList('aubade_recent_searches'), ['rain', 'aurora']);
      expect(sp.getInt('aubade_lyrics_offset_track/1'), 250);
      expect(
        sp.getKeys().where((k) => k.startsWith('lw_')),
        isEmpty,
        reason: 'every legacy key must be removed after the move',
      );
    });

    test('migrates a desktop-shaped List<dynamic> legacy list', () async {
      // shared_preferences_linux/windows round-trip lists through
      // json.decode → List<dynamic>; macOS NSArray → [Any]. Seed that real
      // shape instead of a List<String>, which masked the old type check.
      final realShape = jsonDecode(jsonEncode(<String>['a', 'b']));
      SharedPreferences.setMockInitialValues({'lw_recent_searches': realShape});

      final sp = await SharedPreferences.getInstance();
      expect(
        sp.get('lw_recent_searches').runtimeType,
        List<dynamic>,
        reason: 'the fixture must reproduce the platform list type',
      );

      final prefs = await Prefs.load();

      expect(prefs.recentSearches, ['a', 'b']);
      expect(sp.containsKey('lw_recent_searches'), isFalse);
      final migrated = sp.getStringList('aubade_recent_searches');
      expect(migrated, ['a', 'b']);
      expect(migrated, everyElement(isA<String>()));
    });

    test('non-String list elements keep the legacy key untouched', () async {
      SharedPreferences.setMockInitialValues({
        'lw_recent_searches': <Object>[1, 'b'],
      });

      final prefs = await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(prefs.recentSearches, isEmpty);
      expect(sp.containsKey('aubade_recent_searches'), isFalse);
      expect(sp.get('lw_recent_searches'), <Object>[1, 'b']);
    });

    test('prefix lookalikes are not treated as lyrics-offset keys', () async {
      SharedPreferences.setMockInitialValues({
        'lw_lyrics_offset': 10,
        'lw_lyrics_offsetting': 20,
        'lw_lyrics_offset_track/1': 250,
      });

      final prefs = await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(prefs.getLyricsOffset('track/1'), 250);
      expect(sp.getInt('lw_lyrics_offset'), 10);
      expect(sp.getInt('lw_lyrics_offsetting'), 20);
      expect(sp.containsKey('aubade_lyrics_offset'), isFalse);
      expect(sp.containsKey('aubade_lyrics_offsetting'), isFalse);
    });

    test('unrelated aubade_* keys are preserved', () async {
      SharedPreferences.setMockInitialValues({
        'aubade_music_folders': ['/music/a', '/music/b'],
        'lw_accent': 0xFF1E88E5,
      });

      final prefs = await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(prefs.musicFolders, ['/music/a', '/music/b']);
      expect(sp.getStringList('aubade_music_folders'), [
        '/music/a',
        '/music/b',
      ]);
      expect(prefs.accentColor, 0xFF1E88E5);
    });

    test('a second run is a no-op', () async {
      SharedPreferences.setMockInitialValues({
        'lw_accent': 0xFF123456,
        'lw_recent_searches': ['one'],
      });
      await Prefs.load();
      final sp = await SharedPreferences.getInstance();
      final keysAfterFirst = sp.getKeys().toSet();
      final accentAfterFirst = sp.getInt('aubade_accent');

      await Prefs.load();

      expect(sp.getKeys().toSet(), keysAfterFirst);
      expect(sp.getInt('aubade_accent'), accentAfterFirst);
      expect(sp.getKeys().where((k) => k.startsWith('lw_')), isEmpty);
    });

    test('an existing aubade_* value wins over the legacy copy', () async {
      SharedPreferences.setMockInitialValues({
        'lw_accent': 0xFF111111,
        'aubade_accent': 0xFF222222,
      });

      final prefs = await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(prefs.accentColor, 0xFF222222);
      expect(sp.getInt('aubade_accent'), 0xFF222222);
      expect(sp.containsKey('lw_accent'), isFalse);
    });

    test('no legacy keys leaves storage untouched', () async {
      SharedPreferences.setMockInitialValues({'aubade_amoled': true});
      await Prefs.load();
      final sp = await SharedPreferences.getInstance();

      expect(sp.getKeys(), {'aubade_amoled'});
      expect(sp.getBool('aubade_amoled'), isTrue);
    });

    test('a failed write keeps the legacy key for the next launch', () async {
      SharedPreferences.setMockInitialValues({});
      final store = _FlakyStore({'flutter.lw_accent': 0xFF123456});
      store.failingKeys.add('flutter.aubade_accent');
      SharedPreferencesStorePlatform.instance = store;

      await Prefs.load();
      final sp = await SharedPreferences.getInstance();
      await sp.reload(); // drop the facade's optimistic cache write

      expect(sp.containsKey('lw_accent'), isTrue);
      expect(sp.getInt('lw_accent'), 0xFF123456);
      expect(sp.containsKey('aubade_accent'), isFalse);

      // Next launch: the write succeeds, so the legacy key is dropped.
      store.failingKeys.clear();
      await Prefs.load();
      await sp.reload();

      expect(sp.getInt('aubade_accent'), 0xFF123456);
      expect(sp.containsKey('lw_accent'), isFalse);
    });
  });
}
