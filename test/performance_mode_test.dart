import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/features/performance/performance_controller.dart';
import 'package:aubade/ui/components/ambient.dart';

/// Performance Mode is a single persisted boolean with a narrow blast
/// radius: opaque surfaces, no animated artwork/aura, gated visualizer.
/// These tests pin the persistence contract and the force-off behavior
/// (the user's saved visualizer preference must survive untouched).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerformanceController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults off and persists the explicit choice', () async {
      final prefs = await Prefs.load();
      expect(prefs.performanceMode, isFalse);

      final controller = PerformanceController(prefs);
      expect(controller.state, isFalse);

      controller.setPerformanceMode(true);
      expect(controller.state, isTrue);
      expect(prefs.performanceMode, isTrue);

      // A fresh Prefs over the same store is what the next launch sees.
      final reloaded = await Prefs.load();
      expect(reloaded.performanceMode, isTrue);
    });

    test('toggle flips and persists', () async {
      final prefs = await Prefs.load();
      final controller = PerformanceController(prefs);
      controller.toggle();
      expect(controller.state, isTrue);
      controller.toggle();
      expect(controller.state, isFalse);
      expect((await Prefs.load()).performanceMode, isFalse);
    });

    test('setPerformanceMode is a no-op when the value is unchanged',
        () async {
      final prefs = await Prefs.load();
      await prefs.setPerformanceMode(false);
      final controller = PerformanceController(prefs);
      var notifications = 0;
      controller.addListener((_) => notifications++);
      // state_notifier replays the current value on add; reset so the
      // assertion measures only what setPerformanceMode does.
      notifications = 0;
      controller.setPerformanceMode(false);
      expect(notifications, 0);
    });
  });

  group('visualizer gating', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('Performance Mode forces the visualizer off but keeps the pref',
        () async {
      SharedPreferences.setMockInitialValues(
          {'aubade_visualizer_enabled': true});
      final prefs = await Prefs.load();
      expect(prefs.visualizerEnabled, isTrue);

      final forced = VisualizerEnabledNotifier(prefs, forceDisabled: true);
      expect(forced.state, isFalse);

      // The toggle must not rewrite the saved preference while forced.
      forced.toggle();
      expect(forced.state, isFalse);
      expect(prefs.visualizerEnabled, isTrue);

      // A forced setEnabled still records intent for the next launch.
      forced.setEnabled(false);
      expect(prefs.visualizerEnabled, isFalse);
    });

    test('provider reflects the mode and reacts to it', () async {
      final prefs = await Prefs.load();
      final container = ProviderContainer(
        overrides: [
          // The real prefsProvider is app-scoped; supply the loaded store.
          prefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(performanceModeProvider), isFalse);
      expect(container.read(visualizerEnabledProvider), isTrue);

      container.read(performanceModeProvider.notifier).setPerformanceMode(true);
      expect(container.read(performanceModeProvider), isTrue);
      expect(container.read(visualizerEnabledProvider), isFalse);

      container
          .read(performanceModeProvider.notifier)
          .setPerformanceMode(false);
      expect(container.read(visualizerEnabledProvider), isTrue);
    });
  });

  test('the aura refresh ceiling documents the 15 Hz contract', () {
    expect(kPerformanceAuraMaxHz, 15);
  });
}
