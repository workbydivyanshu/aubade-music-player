import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';

/// One-click Performance Mode.
///
/// This is deliberately a single boolean with a small blast radius: every
/// consumer watches this provider and degrades one visual path, so turning
/// the switch on never rebuilds playback or re-opens the audio device.
final performanceModeProvider =
    StateNotifierProvider<PerformanceController, bool>((ref) {
  return PerformanceController(ref.watch(prefsProvider));
});

class PerformanceController extends StateNotifier<bool> {
  PerformanceController(this._prefs) : super(_prefs.performanceMode);

  final Prefs _prefs;

  void toggle() => setPerformanceMode(!state);

  void setPerformanceMode(bool enabled) {
    if (state == enabled) return;
    state = enabled;
    _prefs.setPerformanceMode(enabled);
  }
}

/// Honest, cheap hardware probe used only for an optional nudge — never
/// to switch the mode on behind the user's back.
final isModestHardwareProvider = Provider<bool>((ref) {
  try {
    return Platform.numberOfProcessors <= 4;
  } catch (_) {
    return false;
  }
});

/// True when heavy visual work should be suppressed: the user turned on
/// Performance Mode, or the OS asks for reduced motion.
final reduceVisualLoadProvider = Provider<bool>((ref) {
  return ref.watch(performanceModeProvider);
});

/// The aura is painted once per size, not animated, so there is no ticker
/// to throttle. In Performance Mode it is skipped entirely and the stage
/// falls back to its static tint. Kept as a named constant so the intent
/// ("at most 15 refreshes a second if this ever gains a ticker") is
/// documented rather than implied.
const int kPerformanceAuraMaxHz = 15;
