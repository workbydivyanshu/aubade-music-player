import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';

/// SMTC status codes consumed by `windows/runner/smtc_channel.cpp`.
const smtcStatusStopped = 0;
const smtcStatusPlaying = 1;
const smtcStatusPaused = 2;
const smtcStatusChanging = 3;

/// Positions that moved further than playback time explains count as a
/// seek (mirrors the MPRIS Seeked threshold).
const smtcSeekThreshold = Duration(seconds: 3);

/// Maps a snapshot to the SMTC playback status.
///
/// `Stopped` only when there is no track; buffering while playing reports
/// `Changing` so the flyout shows a spinner instead of flickering.
int smtcStatusFor(PlayerSnapshot snap) {
  if (snap.current == null) return smtcStatusStopped;
  if (snap.isPlaying && snap.isBuffering) return smtcStatusChanging;
  return snap.isPlaying ? smtcStatusPlaying : smtcStatusPaused;
}

/// Builds the `update` payload for [next], or null when nothing worth
/// pushing changed.
///
/// The shell extrapolates position from `rate` (0 while paused), so
/// position is only pushed on track/status/seek changes — never per tick.
Map<String, Object>? smtcUpdateFor(PlayerSnapshot? prev, PlayerSnapshot next) {
  final track = next.current;
  final hasTrack = track != null;
  final status = smtcStatusFor(next);
  final canGo = hasTrack;

  bool changed = prev == null;
  if (!changed) {
    final prevTrack = prev.current;
    changed =
        prevTrack?.mediaId != track?.mediaId ||
        prev.duration != next.duration ||
        prevTrack?.artworkUrl != track?.artworkUrl ||
        smtcStatusFor(prev) != status ||
        prev.speed != next.speed ||
        (prev.current == null) != (track == null);
  }
  if (!changed && prev != null) {
    // User seek on the same track: position jumped further than the
    // snapshot cadence explains while the play state held steady.
    final delta = (next.position - prev.position).abs();
    changed = prev.current?.mediaId == track?.mediaId &&
        delta > smtcSeekThreshold &&
        prev.isPlaying == next.isPlaying;
  }
  if (!changed) return null;

  return {
    'title': track?.title ?? '',
    'artist': track?.artist ?? '',
    'album': track?.album ?? '',
    'artUrl': track?.artworkUrl ?? '',
    'status': status,
    'positionMs': next.position.inMilliseconds,
    'durationMs': next.duration.inMilliseconds,
    // The shell advances the timeline itself at this rate; 0 freezes it.
    'rate': next.isPlaying ? next.speed : 0.0,
    'hasTrack': hasTrack,
    'canNext': canGo,
    'canPrev': canGo,
  };
}

/// System media transport endpoint for Windows (SMTC) and macOS
/// (Now Playing) — the counterpart to the MPRIS service on Linux.
///
/// Pushes now-playing metadata + transport state to the native
/// `aubade/smtc` channel (Windows: volume flyout, lock screen;
/// macOS: menu bar Now Playing, Control Center; both: Bluetooth and
/// hardware media keys) and routes button presses back into
/// [PlaybackService]. Windows always publishes; macOS is opt-in via
/// [Prefs.macosNowPlaying] because the system entry is user-visible.
/// The native side lives in `windows/runner/smtc_channel.cpp` and
/// `macos/Runner/NowPlayingChannel.swift`. Every failure degrades to
/// silence.
class SmtcService {
  final Ref _ref;
  final MethodChannel _channel = const MethodChannel('aubade/smtc');
  PlayerSnapshot? _last;
  bool _handlerSet = false;
  bool _disposed = false;

  SmtcService(this._ref);

  PlaybackService get _player => _ref.read(playbackServiceProvider.notifier);

  /// Platforms whose runner implements the `aubade/smtc` channel.
  bool get _supported => Platform.isWindows || Platform.isMacOS;

  /// Windows always publishes; macOS only after the Now Playing opt-in.
  bool get _enabled =>
      Platform.isWindows ||
      (Platform.isMacOS && _ref.read(prefsProvider).macosNowPlaying);

  Future<void> startup() async {
    if (!_supported || _disposed) return;
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onNativeCall);
    }
    _last = null;
    if (!_enabled) {
      // macOS opt-in off: make sure no earlier session's entry survives.
      await _clearNative();
      return;
    }
    onSnapshot(_ref.read(playbackServiceProvider));
  }

  /// Re-applies the macOS opt-in after the Settings toggle changes.
  ///
  /// Turning it off clears the system Now Playing entry immediately;
  /// turning it on republishes the current snapshot. No-op on Windows,
  /// whose SMTC endpoint is always on.
  void refreshMacosOptIn() {
    if (!Platform.isMacOS || _disposed) return;
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onNativeCall);
    }
    _last = null;
    if (!_ref.read(prefsProvider).macosNowPlaying) {
      unawaited(_clearNative());
      return;
    }
    onSnapshot(_ref.read(playbackServiceProvider));
  }

  void onSnapshot(PlayerSnapshot snap) {
    if (!_enabled || _disposed) return;
    final update = smtcUpdateFor(_last, snap);
    _last = snap;
    if (update == null) return;
    unawaited(_channel.invokeMethod('update', update).catchError((_) {}));
  }

  /// Drops the macOS Now Playing entry; also used when opt-in is turned
  /// off so Control Center stops showing a stale track.
  Future<void> _clearNative() async {
    try {
      await _channel.invokeMethod('clear');
    } catch (_) {
      // Native side absent or the engine is tearing down: nothing to do.
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'onButton') return null;
    final player = _player;
    try {
      switch (call.arguments as String?) {
        case 'play':
          await player.playResume();
        case 'pause':
          await player.pause();
        case 'toggle':
          await player.toggle();
        case 'stop':
          // No quit-via-SMTC (MPRIS CanQuit=false parity): stop = pause.
          await player.pause();
        case 'next':
          await player.next();
        case 'previous':
          await player.previous();
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _disposed = true;
    _last = null;
    if (Platform.isMacOS) unawaited(_clearNative());
  }
}

final smtcProvider = Provider<SmtcService>((ref) {
  final svc = SmtcService(ref);
  ref.listen<PlayerSnapshot>(
      playbackServiceProvider, (prev, next) => svc.onSnapshot(next));
  ref.onDispose(svc.dispose);
  return svc;
});
