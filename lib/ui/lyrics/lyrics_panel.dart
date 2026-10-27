import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/lyrics/karaoke_lyrics_view.dart';
import '../../features/lyrics/lyrics_models.dart';
import '../../features/lyrics/lyrics_repository.dart';
import '../../features/player/playback_service.dart';

// Lyrics fetch is keyed by track identity — never by the playback clock
// or duration (duration arrives late and would refetch). Position ticks
// only drive the highlight index.
final lyricsProviderOverrideProvider =
    StateProvider.autoDispose.family<String?, String>((_, _) => null);
final lyricsExcludedProvidersProvider =
    StateProvider.autoDispose.family<Set<String>, String>((_, _) => <String>{});

final waveLyricsProvider = StreamProvider.autoDispose
    .family<LyricsResult, String>((ref, key) {
  final current = ref.watch(
      playbackServiceProvider.select((s) => s.current));
  if (current == null || current.queueKey != key) {
    return Stream.value(const LyricsResult.empty());
  }
  final repo = ref.watch(lyricsRepositoryProvider);
  final prefs = ref.watch(prefsProvider);
  final wordByWord = prefs.wordByWord;
  // Per-track source control (Task 9): an explicit provider pick
  // (null = follow the Settings default) plus excluded providers.
  // Watched, so switching sources refetches through a new cache key.
  final override = ref.watch(lyricsProviderOverrideProvider(key));
  final excludes = ref.watch(lyricsExcludedProvidersProvider(key));
  // Duration read once (no watch) so late duration arrival doesn't refetch.
  final durationSecs =
      ref.read(playbackServiceProvider).duration.inSeconds;
  final results = StreamController<LyricsResult>();
  final guard = LyricsStreamGuard(results);
  ref.onDispose(guard.dispose);
  unawaited(repo.getLyrics(
    title: current.title,
    artist: current.artist,
    album: current.album,
    durationSeconds: durationSecs > 0 ? durationSecs : null,
    wordByWord: wordByWord,
    videoId: current.videoId.isNotEmpty ? current.videoId : null,
    preferredProviderId: override ?? prefs.lyricsProviderId,
    excludeProviderIds: excludes,
    onPartialResult: guard.emit,
  ).then(guard.emit, onError: guard.fail).whenComplete(guard.finish));
  return results.stream;
});

/// Guarded writer for the lyrics provider's single-subscription stream.
///
/// A fetch can resolve after the provider is disposed (the route or track
/// changed mid-flight), and a result can also arrive after the stream was
/// already closed for content. Either way, writing straight to the
/// controller throws `Cannot add event after closing`, so every emit,
/// error, and close checks both lifecycle flags and the controller state
/// first. Late results are dropped instead of escaping.
class LyricsStreamGuard {
  LyricsStreamGuard(this._controller);

  final StreamController<LyricsResult> _controller;
  bool _disposed = false;
  bool _closed = false;

  bool get isClosed => _closed;

  void emit(LyricsResult result) {
    if (_disposed || _closed || _controller.isClosed) return;
    _controller.add(result);
  }

  void fail(Object error, StackTrace stack) {
    if (_disposed || _closed || _controller.isClosed) return;
    _controller.addError(error, stack);
  }

  void finish() {
    if (_disposed || _closed) return;
    _closed = true;
    unawaited(_controller.close());
  }

  void dispose() {
    _disposed = true;
    _closed = true;
    unawaited(_controller.close());
  }
}

/// Premium Apple Music Karaoke lyrics reading experience.
///
/// Backed by [WaveKaraokeLyricsView] with word-level progressive syllable wipe,
/// blur falloff, active line pop, timing offset controls, and autoscroll.
class WaveLyricsPanel extends StatelessWidget {
  final PlayableTrack track;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;

  const WaveLyricsPanel({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return WaveKaraokeLyricsView(
      track: track,
      compact: compact,
      showHeaderControls: showHeaderControls,
      onClose: onClose,
    );
  }
}

