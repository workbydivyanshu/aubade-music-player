import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/ui/now_playing/now_playing_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NowPlayingStyle enum', () {
    test('fromId maps valid strings and falls back to fullBleed', () {
      expect(NowPlayingStyle.fromId('fullBleed'), NowPlayingStyle.fullBleed);
      expect(NowPlayingStyle.fromId('minimal'), NowPlayingStyle.minimal);
      expect(NowPlayingStyle.fromId('standard'), NowPlayingStyle.standard);
      expect(NowPlayingStyle.fromId(null), NowPlayingStyle.fullBleed);
      expect(NowPlayingStyle.fromId('unknown'), NowPlayingStyle.fullBleed);
    });

    test('default style is fullBleed', () {
      expect(NowPlayingStyle.values.first, NowPlayingStyle.fullBleed);
    });
  });

  group('NowPlayingStyle persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to fullBleed and persists changes', () async {
      final prefs = await Prefs.load();
      expect(prefs.nowPlayingStyle, 'fullBleed');

      await prefs.setNowPlayingStyle('minimal');
      expect(prefs.nowPlayingStyle, 'minimal');

      await prefs.setNowPlayingStyle('standard');
      expect(prefs.nowPlayingStyle, 'standard');

      await prefs.setNowPlayingStyle('invalid');
      expect(prefs.nowPlayingStyle, 'fullBleed');
    });

    test('NowPlayingStyleNotifier flips state and updates prefs', () async {
      final prefs = await Prefs.load();
      final notifier = NowPlayingStyleNotifier(prefs);

      expect(notifier.state, NowPlayingStyle.fullBleed);

      notifier.set(NowPlayingStyle.minimal);
      expect(notifier.state, NowPlayingStyle.minimal);
      expect(prefs.nowPlayingStyle, 'minimal');

      notifier.set(NowPlayingStyle.standard);
      expect(notifier.state, NowPlayingStyle.standard);
      expect(prefs.nowPlayingStyle, 'standard');
    });
  });
}
