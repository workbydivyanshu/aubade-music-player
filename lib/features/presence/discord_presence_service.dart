import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';
import 'discord_ipc.dart';

/// Discord Rich Presence ("Listening to Aubade") over local IPC.
///
/// Setup: [discordApplicationId] is Aubade's public application ID — a
/// client id is not a secret. Under Rich Presence > Art Assets the
/// uploaded `logo` asset is the no-artwork fallback: Discord can only
/// load http(s) image URLs and platform asset keys, never local files.
///
/// The wire protocol and the failure rules re-create the web project's
/// raw IPC daemon (`daemon/discord-native.js`): "Artist - Title" in
/// details, the album as the state line, "Paused - ..."-worded state so
/// a paused album never looks live, and timestamps only while playing.
///
/// Behaviour: pushes on track/play-state change, throttled to one send
/// every [pushInterval] (well inside Discord's 5-per-20s budget), with
/// an unchanged presence re-pushed every [refreshInterval] as a
/// self-heal. Rate-limit replies back the sender off for
/// [_rateBackoff]; a missing Discord client is retried at most once per
/// [_retryInterval]; a dead socket is destroyed in place — a failed
/// send never leaves a half-dead connection behind. Silent otherwise.
class DiscordPresenceService {
  /// Application ID from the Discord Developer Portal (General Information).
  /// Public by design — safe to ship in source (it is not a secret; only
  /// the Client Secret / bot token must stay private).
  static const discordApplicationId = '1561930829456867368';

  static const _fieldLimit = 128;
  static const pushInterval = Duration(seconds: 5);
  static const refreshInterval = Duration(seconds: 15);
  // While music plays, a missing connection is retried at most this often:
  // a closed Discord costs ~10 fast-failed pipe opens (sub-millisecond),
  // so retrying eagerly is cheap and keeps worst-case invisibility tiny.
  static const _retryInterval = Duration(seconds: 15);
  // Back the sender off after a rate-limit reply, like the daemon does.
  static const _rateBackoff = Duration(seconds: 20);

  final Ref _ref;
  DiscordIpc? _ipc;
  Timer? _heartbeat;
  bool _disposed = false;
  bool _connecting = false;
  DateTime? _lastAttempt;
  String _lastKey = '';
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _backoffUntil;
  PlayerSnapshot? _lastSnap;

  DiscordPresenceService(this._ref) {
    // Self-heal: re-evaluates on a slow tick so presence can never go
    // stale unnoticed (missed snapshot, dropped pipe, Discord restarted
    // while paused). Tick does nothing when up to date; with the 5s
    // push throttle, a playing track refreshes at most every 15s even
    // if every event-driven push was somehow missed.
    _heartbeat = Timer.periodic(refreshInterval, (_) {
      if (_disposed) return;
      unawaited(refresh());
    });
  }

  bool get _configured =>
      discordApplicationId.isNotEmpty &&
      discordApplicationId != 'YOUR_DISCORD_APPLICATION_ID';

  bool get _enabled {
    try {
      return _ref.read(prefsProvider).discordRichPresence;
    } catch (_) {
      return true;
    }
  }

  /// Push the current snapshot once (startup / settings toggle).
  Future<void> startup() => refresh();

  Future<void> refresh() async {
    PlayerSnapshot? snap;
    try {
      snap = _ref.read(playbackServiceProvider);
    } catch (_) {
      return;
    }
    final current = snap;
    if (current == null) return;
    await onSnapshot(current);
  }

  Future<void> onSnapshot(PlayerSnapshot snap) async {
    _lastSnap = snap;
    await _evaluate();
  }

  Future<void> _evaluate() async {
    if (_disposed) return;
    final snap = _lastSnap;
    // Disabled, unconfigured, or unsupported: clear anything visible.
    if (!_enabled || !_configured || !DiscordIpc.isSupported) {
      await _clearQuiet();
      return;
    }
    if (snap == null) return;
    final track = snap.current;
    if (track == null || track.title.trim().isEmpty) {
      await _clearQuiet();
      return;
    }
    final key =
        '${track.queueKey}|playing=${snap.isPlaying}|dur=${snap.duration.inSeconds}|br=${snap.bitrateKbps}';
    final now = DateTime.now();
    final changed = key != _lastKey;
    // Position ticks never reach here (see the provider slice below);
    // everything else waits out the push throttle and any backoff.
    if (!shouldPush(changed: changed, lastPush: _lastPush,
        backoffUntil: _backoffUntil, now: now)) {
      return;
    }
    if (!await _ensureConnected()) return;
    final ipc = _ipc;
    if (ipc == null) return;
    try {
      // Empty titles produce no activity; nothing to send.
      final payload = DiscordPresenceService.buildActivity(track, snap, now);
      if (payload == null) return;
      final verdict = await ipc.setActivity(payload);
      if (verdict == DiscordSend.ok) {
        _lastKey = key;
        _lastPush = now;
      } else if (verdict == DiscordSend.rateLimited) {
        // Live socket with a telling reply: back off, don't reconnect.
        _backoffUntil = now.add(_rateBackoff);
      } else {
        // Pipe died mid-send: destroy it so the next snapshot reconnects.
        _dropNow(now);
      }
    } catch (_) {
      _dropNow(now);
    }
  }

  /// Any failure path funnels here: close the broken transport, forget
  /// it, and record the attempt time so reconnection stays quiet.
  void _dropNow(DateTime now) {
    try {
      _ipc?.close();
    } catch (_) {}
    _ipc = null;
    _lastAttempt = now;
  }

  /// Push gating: new activity waits out [pushInterval]; an unchanged
  /// presence re-pushes only at [refreshInterval] (self-heal); a
  /// rate-limit backoff blocks everything until it expires. Bench for
  /// the pins in test/presence_ipc_test.dart.
  static bool shouldPush({
    required bool changed,
    required DateTime? lastPush,
    required DateTime? backoffUntil,
    required DateTime now,
  }) {
    if (backoffUntil != null && now.isBefore(backoffUntil)) return false;
    if (lastPush == null) return true;
    final since = now.difference(lastPush);
    return changed ? since >= pushInterval : since >= refreshInterval;
  }

  /// Activity payload for SET_ACTIVITY (type 2 = listening), in the
  /// shape the raw IPC daemon used: artist-first details, album state,
  /// Paused wording, start-only timestamps. Bench for the pins.
  static Map<String, Object?>? buildActivity(
      PlayableTrack track, PlayerSnapshot snap, DateTime now) {
    final title = _clipField(track.title);
    if (title.isEmpty) return null;
    final artist = track.artist.trim();
    final album = track.album.trim();
    final playing = snap.isPlaying;
    final details = artist.isEmpty ? title : _clipField('$artist - $title');
    // Empty album while playing drops the state line; pause always
    // says Paused so Discord never shows a still album as live.
    final state = playing
        ? (album.isEmpty ? null : _clipField(album))
        : _clipField(album.isEmpty ? 'Paused' : 'Paused - $album');
    Map<String, Object?>? ts;
    if (playing) {
      var pos = snap.position;
      if (snap.duration > Duration.zero && pos > snap.duration) {
        pos = snap.duration;
      }
      if (pos < Duration.zero) pos = Duration.zero;
      ts = {'start': now.millisecondsSinceEpoch ~/ 1000 - pos.inSeconds};
    }
    final art = track.artworkUrl.trim();
    final artIsUrl = art.startsWith('http://') || art.startsWith('https://');
    return {
      'type': 2,
      'details': details,
      'state': ?state,
      'timestamps': ?ts,
      'assets': {
        'large_image': artIsUrl ? art : 'logo',
        'large_text': album.isEmpty ? title : _clipField(album),
      },
    };
  }

  /// Fields Discord renders, capped at the displayed limit.
  static String _clipField(String s, {int limit = _fieldLimit}) {
    final t = s.trim();
    return t.length > limit ? t.substring(0, limit) : t;
  }

  /// Connect if needed. Returns true when ready to send. Never throws.
  Future<bool> _ensureConnected() async {
    final ipc = _ipc;
    if (ipc != null) {
      if (ipc.isOpen) return true;
      _dropNow(DateTime.now());
    }
    if (_connecting) return false;
    final last = _lastAttempt;
    if (last != null &&
        DateTime.now().difference(last) < _retryInterval) {
      return false; // Discord closed recently; back off quietly.
    }
    _connecting = true;
    _lastAttempt = DateTime.now();
    try {
      final fresh = await DiscordIpc.connect(discordApplicationId);
      if (fresh == null) return false;
      _ipc = fresh;
      return true;
    } catch (_) {
      return false;
    } finally {
      _connecting = false;
    }
  }

  Future<void> _clearQuiet() async {
    _lastKey = '';
    final ipc = _ipc;
    if (ipc == null) return;
    try {
      ipc.clearActivity();
    } catch (_) {}
  }

  /// Best-effort clear + release (app quit). Never throws.
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _heartbeat?.cancel();
    } catch (_) {}
    _heartbeat = null;
    try {
      await _clearQuiet();
    } catch (_) {}
    try {
      _ipc?.close();
    } catch (_) {}
    _ipc = null;
  }

  void dispose() {
    unawaited(shutdown());
  }
}

final discordPresenceProvider = Provider<DiscordPresenceService>((ref) {
  final svc = DiscordPresenceService(ref);
  // Slice matches the push key exactly
  // (queueKey/isPlaying/duration/bitrate): position ticks fired this 10Hz
  // and would have died in the throttle every time. Settings toggles call
  // refresh() explicitly and the 15s heartbeat self-heals, so no push
  // path is lost. (MPRIS/SMTC must keep the full snapshot: their seek
  // detection diffs consecutive positions. This one never does.)
  ref.listen(
    playbackServiceProvider.select((s) => (
      s.current?.queueKey ?? '',
      s.isPlaying,
      s.duration,
      s.bitrateKbps,
    )),
    (_, _) {
      unawaited(svc.onSnapshot(ref.read(playbackServiceProvider)));
    },
  );
  ref.onDispose(svc.dispose);
  return svc;
});
