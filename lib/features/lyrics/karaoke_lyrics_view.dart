import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../core/error/fatal_crumbs.dart';
import '../../core/storage/prefs.dart';
import '../../ui/components/buttons.dart' show LWTooltip;
import '../../ui/components/menus.dart' show fastFlyoutTransition;
import '../../ui/components/states.dart';
import '../../ui/lyrics/lyrics_panel.dart';
import '../../ui/theme/haze.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/theme/wave_icons.dart';
import '../player/playback_service.dart';
import 'desktop_lyrics_painter.dart';
import 'lyrics_models.dart';
import 'lyrics_providers.dart';

/// Provider for track-specific lyrics timing offset in milliseconds.
final lyricsOffsetProvider = StateNotifierProvider.family<LyricsOffsetNotifier, int, String>(
  (ref, trackKey) {
    final prefs = ref.watch(prefsProvider);
    return LyricsOffsetNotifier(prefs, trackKey);
  },
);

class LyricsOffsetNotifier extends StateNotifier<int> {
  final Prefs _prefs;
  final String _trackKey;

  LyricsOffsetNotifier(this._prefs, this._trackKey)
      : super(_prefs.getLyricsOffset(_trackKey));

  void adjust(int deltaMs) {
    final next = state + deltaMs;
    state = next;
    _prefs.setLyricsOffset(_trackKey, next);
  }

  void reset() {
    state = 0;
    _prefs.resetLyricsOffset(_trackKey);
  }

  void setOffset(int offsetMs) {
    state = offsetMs;
    _prefs.setLyricsOffset(_trackKey, offsetMs);
  }
}

/// Provider for transliteration display toggle.
final lyricsTransliterationProvider =
    StateNotifierProvider<LyricsTransliterationNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return LyricsTransliterationNotifier(prefs);
});

class LyricsTransliterationNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  LyricsTransliterationNotifier(this._prefs)
      : super(_prefs.lyricsTransliteration);

  void toggle() {
    state = !state;
    _prefs.setLyricsTransliteration(state);
  }
}

/// Selectable kinetic typography for the desktop karaoke line. Reads the
/// single `aubade_lyrics_style` pref; unknown ids degrade to classic.
final lyricsKineticStyleProvider = Provider<LyricsKineticStyle>((ref) {
  final id = ref.watch(prefsProvider.select((p) => p.lyricsStyle));
  return LyricsKineticStyle.fromId(id);
});

/// Format offset in ms to display string (e.g. "+0.5s", "-1.0s", "0.0s").
String formatOffsetDisplay(int offsetMs) {
  if (offsetMs == 0) return '0.0s';
  final sign = offsetMs > 0 ? '+' : '-';
  final secs = (offsetMs.abs() / 1000.0).toStringAsFixed(1);
  return '$sign${secs}s';
}

/// Apple Music Karaoke-Style Lyrics Engine.
///
/// Features:
/// - Progressive syllable color wipe for word-synced lyrics.
/// - Inactive lines rendered with reduced opacity and soft blur (`ImageFilter.blur`).
/// - Active line pops with 1.025x scale and prominent Segoe UI typography.
/// - Timing offset controls: `[-] 0.0s [+] [Reset]` (persisted per track).
/// - Transliteration / Romaji toggle.
/// - Smooth auto-scrolling with manual scroll detection and "Return to current" pill.
/// - Interactive tap-to-seek on any lyric line.
class WaveKaraokeLyricsView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;
  final double? fontSize;
  final bool fillRemainingSpace;

  const WaveKaraokeLyricsView({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
    this.fontSize,
    this.fillRemainingSpace = true,
  });

  @override
  ConsumerState<WaveKaraokeLyricsView> createState() =>
      _WaveKaraokeLyricsViewState();
}

class _WaveKaraokeLyricsViewState extends ConsumerState<WaveKaraokeLyricsView>
    with SingleTickerProviderStateMixin {
  bool _following = true;
  late final Ticker _ticker;
  final ValueNotifier<int> _interpolatedPositionMs = ValueNotifier<int>(0);
  // Clock subscriptions owned here (initState/dispose), not watched in
  // build: position/isPlaying/speed tick 10Hz and feed only ticker/drift
  // side effects, never widget output.
  ProviderSubscription<Duration>? _posSub;
  ProviderSubscription<bool>? _playingSub;
  ProviderSubscription<double>? _speedSub;
  int _lastAudioMs = 0;
  DateTime _lastSyncTime = DateTime.now();
  bool _isPlaying = false;
  double _speed = 1.0;
  int _offsetMs = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Subscribe without rebuilding: each emission only re-syncs the
    // interpolation clock (same math the in-build block used to run).
    _posSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.position),
      (_, _) => _syncPlaybackClock(),
    );
    _playingSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.isPlaying),
      (_, _) => _syncPlaybackClock(),
    );
    _speedSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.speed),
      (_, _) => _syncPlaybackClock(),
    );
    _syncPlaybackClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // J1: one reduced-motion gate. The OS flag can flip while mounted, so
    // re-sync the clock here; `_syncPlaybackClock` owns start/stop.
    _reduceMotion = WaveMotion.respectReduce(context);
    _syncPlaybackClock();
  }

  @override
  void dispose() {
    _posSub?.close();
    _playingSub?.close();
    _speedSub?.close();
    _ticker.dispose();
    _interpolatedPositionMs.dispose();
    super.dispose();
  }

  DateTime _lastTickWall = DateTime.now();

  void _onTick(Duration _) {
    // Guarded: a throw here (e.g. a progress value the lyric
    // controller rejects) aborts the whole process via fail-fast.
    runGuarded('karaoke.tick', () {
      if (!_isPlaying) return;
    // Cap interpolation at ~30Hz: the ticker fires at display refresh
    // (up to 144Hz), and every admitted tick pushes setProgress + a
    // lyric-view update. Syllable transitions are 50-200ms, so 30Hz
    // loses nothing visible while halving per-frame Dart + raster
    // work — the margin that keeps karaoke smooth while motion art
    // eats the rest of the budget. Accuracy is unaffected — elapsed
    // is wall-clock based, not tick-counted.
    final wall = DateTime.now();
    if (wall.difference(_lastTickWall).inMicroseconds < 33000) return;
    _lastTickWall = wall;
    final elapsed = wall.difference(_lastSyncTime).inMilliseconds;
    final currentMs =
        _lastAudioMs + (elapsed * _speed).round() - _offsetMs;
    _interpolatedPositionMs.value = currentMs;
    });
  }

  /// Syncs the 30Hz interpolation clock from the 10Hz playback snapshot.
  /// Runs from tick listeners and rare rebuilds — writes only the ticker
  /// and the position notifier, never setState, so it never schedules
  /// extra frames.
  void _syncPlaybackClock() {
    final snap = ref.read(playbackServiceProvider);
    final audioMs = snap.position.inMilliseconds;
    _isPlaying = snap.isPlaying;
    _speed = snap.speed <= 0 ? 1.0 : snap.speed;
    if (!_isPlaying) {
      _lastAudioMs = audioMs;
      _lastSyncTime = DateTime.now();
      _interpolatedPositionMs.value = audioMs - _offsetMs;
    } else if (audioMs != _lastAudioMs) {
      final elapsed = DateTime.now().difference(_lastSyncTime).inMilliseconds;
      final predicted = _lastAudioMs + (elapsed * _speed).round();
      final drift = audioMs - predicted;
      if (_reduceMotion || drift < -80 || drift > 80) {
        // Reduced motion has no interpolation ticker: follow the 10Hz
        // snapshot directly (state, not decorative motion).
        _lastAudioMs = audioMs;
        _lastSyncTime = DateTime.now();
        _interpolatedPositionMs.value = audioMs - _offsetMs;
      }
    }

    if (_isPlaying && !_reduceMotion && !_ticker.isActive) {
      _ticker.start();
    } else if ((!_isPlaying || _reduceMotion) && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: position/isPlaying/speed are subscribed in initState
    // (_syncPlaybackClock), not watched here. They tick 10Hz and feed
    // only ticker/drift side effects, never widget output — watching them
    // rebuilt the whole toolbar + style + list 10x/sec for nothing.
    final offsetMs = ref.watch(lyricsOffsetProvider(widget.track.queueKey));
    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    // Select the single pref: toggling theme/quality elsewhere must
    // not rebuild the karaoke view (it recreates the lyric adapter).
    final wordByWord =
        ref.watch(prefsProvider.select((p) => p.wordByWord));
    final async = ref.watch(waveLyricsProvider(widget.track.queueKey));

    _offsetMs = offsetMs;
    // Covers offset/track/data-driven syncs; clock ticks arrive via the
    // initState subscriptions. Rare either way (no per-tick rebuilds).
    _syncPlaybackClock();

    return async.when(
      loading: () => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: const WaveLoading(label: 'Finding lyrics…'),
      ),
      error: (e, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: WaveError(
          title: 'Lyrics unavailable',
          message: 'Check your connection and try again.',
          onRetry: () =>
              ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
        ),
      ),
      data: (result) {
        // Header controls (the source switcher + close) must survive the
        // no-lyrics states. Switching source can land on a provider with
        // no match, and dropping the switcher then strands the user on
        // "Try again" against the same provider, with no way back to
        // another one. So the empty states render the toolbar too.
        Widget withHeader(Widget body) {
          if (!widget.showHeaderControls) return body;
          return RepaintBoundary(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _KaraokeToolbar(
                  track: widget.track,
                  result: result,
                  offsetMs: offsetMs,
                  showTransliteration: showTransliteration,
                  following: _following,
                  compact: widget.compact,
                  wordByWord: wordByWord,
                  onClose: widget.onClose,
                  onToggleFollowing: () {
                    setState(() => _following = !_following);
                  },
                ),
                Expanded(child: body),
              ],
            ),
          );
        }

        if (result.isInstrumental) {
          return withHeader(const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          ));
        }
        if (result.isEmpty) {
          return withHeader(WaveEmpty(
            icon: FluentIcons.microphone,
            title: 'No lyrics found',
            subtitle: 'Try another track or check back later.',
            actionLabel: 'Try again',
            onAction: () =>
                ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
          ));
        }
        if (!result.isSynced && result.lines.length < 2) {
          return _KaraokePlainLyrics(
            text: result.plainLyrics,
            compact: widget.compact,
            showHeaderControls: widget.showHeaderControls,
            onClose: widget.onClose,
          );
        }

        final kineticStyle = ref.watch(lyricsKineticStyleProvider);

        return RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showHeaderControls)
                _KaraokeToolbar(
                  track: widget.track,
                  result: result,
                  offsetMs: offsetMs,
                  showTransliteration: showTransliteration,
                  following: _following,
                  compact: widget.compact,
                  wordByWord: wordByWord,
                  onClose: widget.onClose,
                  onToggleFollowing: () {
                    setState(() => _following = !_following);
                  },
                ),
              Expanded(
                // One renderer for both modes. Word-by-word is now a
                // paint-time detail of the active line (GPU canvas
                // sweep), not a second widget tree with its own
                // controller, scroll view and rebuild cadence.
                child: RepaintBoundary(
                  child: _AppleLineLyricsView(
                    result: result,
                    positionListenable: _interpolatedPositionMs,
                    compact: widget.compact,
                    fontSize: widget.fontSize,
                    showTransliteration: showTransliteration,
                    following: _following,
                    wordByWord: wordByWord && result.isSynced,
                    kineticStyle: kineticStyle,
                    onUserScroll: () {
                      if (_following) setState(() => _following = false);
                    },
                    onResume: () => setState(() => _following = true),
                    onSeekLineMs: (lineMs) {
                      final seekTargetMs = lineMs + _offsetMs;
                      ref.read(playbackServiceProvider.notifier).seek(
                            Duration(
                                milliseconds: math.max(0, seekTargetMs)),
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class KaraokeWordGroup {
  final List<LyricSyllable> syllables;
  final bool hasTrailingSpace;

  const KaraokeWordGroup({
    required this.syllables,
    this.hasTrailingSpace = true,
  });
}

List<KaraokeWordGroup> groupSyllablesIntoWords(
  List<LyricSyllable> syllables,
  String lineText,
) {
  final words = <KaraokeWordGroup>[];
  var currentWordSyllables = <LyricSyllable>[];

  for (var i = 0; i < syllables.length; i++) {
    final syl = syllables[i];
    currentWordSyllables.add(syl);

    var isWordEnd = false;
    if (syl.text.endsWith(' ')) {
      isWordEnd = true;
    } else if (i == syllables.length - 1) {
      isWordEnd = true;
    } else {
      final nextSyl = syllables[i + 1];
      if (nextSyl.text.startsWith(' ')) {
        isWordEnd = true;
      } else {
        final combined = '${syl.text}${nextSyl.text}';
        if (!lineText.contains(combined)) {
          isWordEnd = true;
        }
      }
    }

    if (isWordEnd) {
      words.add(KaraokeWordGroup(
        syllables: currentWordSyllables,
        hasTrailingSpace: i < syllables.length - 1,
      ));
      currentWordSyllables = [];
    }
  }

  if (currentWordSyllables.isNotEmpty) {
    words.add(KaraokeWordGroup(
      syllables: currentWordSyllables,
      hasTrailingSpace: false,
    ));
  }
  return words;
}

double calculateSyllableProgress(LyricSyllable syl, int posMs) {
  final startMs = syl.timeMs;
  final durMs = math.max(1, syl.durationMs);
  final endMs = startMs + durMs;
  if (posMs <= startMs) return 0.0;
  if (posMs >= endMs) return 1.0;
  return (posMs - startMs) / durMs;
}

/// Single Lyric Line rendering with Apple Music Karaoke progressive wipe,
/// blur falloff, and Segoe UI typography.
class WaveKaraokeLyricLine extends StatefulWidget {
  final LyricLine line;
  final int positionMs;
  final ValueListenable<int>? positionListenable;
  final bool isActive;
  final bool isPast;
  final bool compact;
  final bool showTransliteration;
  final double? fontSize;
  final bool karaoke;
  final bool softenIdle;

  /// Spatial staging for duets and background harmonies.
  final VocalRole role;

  /// Kinetic typography for the active word-synced line.
  final LyricsKineticStyle kineticStyle;

  /// When false, the active line sweeps as one block even if syllable
  /// timings exist (the user's word-by-word preference).
  final bool wordByWord;

  const WaveKaraokeLyricLine({
    super.key,
    required this.line,
    required this.positionMs,
    this.positionListenable,
    required this.isActive,
    required this.isPast,
    this.compact = false,
    this.showTransliteration = true,
    this.fontSize,
    this.karaoke = true,
    this.softenIdle = true,
    this.role = VocalRole.leadLeft,
    this.kineticStyle = LyricsKineticStyle.classic,
    this.wordByWord = true,
  });

  @override
  State<WaveKaraokeLyricLine> createState() => _WaveKaraokeLyricLineState();
}

class _WaveKaraokeLyricLineState extends State<WaveKaraokeLyricLine> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final reduceMotion = WaveMotion.respectReduce(context);

    final baseFontSize = (widget.fontSize ?? (widget.compact ? 28.0 : 36.0)) *
        (widget.role == VocalRole.backgroundSubline
            ? DesktopLyricsTokens.backgroundVocalFontScale
            : 1.0);
    // Negative tracking tightens Latin type, but in joined scripts (the
    // Devanagari headline bar) neighbouring glyphs then overlap, and the
    // translucent idle colour composites twice there — bright dots at
    // every join. Those scripts keep their natural advance.
    final tracking = isJoinedScript(widget.line.text) ? 0.0 : -0.3;

    final activeTextColor = dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B);
    final idleTextColor = (dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B))
        .withValues(
          alpha: widget.softenIdle ? (widget.isPast ? 0.38 : 0.44) : 0.92,
        );

    final activeStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor,
      height: 1.42,
      letterSpacing: tracking,
      shadows: widget.isActive
          ? [
              Shadow(
                color: activeTextColor.withValues(
                  alpha: dark
                      ? (widget.kineticStyle.hasGlow ? 0.55 : 0.28)
                      : (widget.kineticStyle.hasGlow ? 0.30 : 0.14),
                ),
                blurRadius: widget.kineticStyle.hasGlow ? 26 : 16,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    );

    // Style for unsung words on the ACTIVE line: identical font metrics to prevent character jitter!
    final activeUnsungStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor.withValues(alpha: 0.38),
      height: 1.42,
      letterSpacing: tracking,
    );

    final idleStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w600,
      color: _isHovered
          ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.88)
          : idleTextColor,
      height: 1.42,
      letterSpacing: tracking,
    );

    Widget content;

    final useKaraokeWipe = widget.karaoke && widget.isActive;
    final effectiveSyllables = useKaraokeWipe
        ? (widget.line.hasSyllables
            ? widget.line.syllables
            : interpolateLineSyllables(
                text: widget.line.text,
                startTimeMs: widget.line.timeMs,
                durationMs: widget.line.durationMs,
              ))
        : const <LyricSyllable>[];

    if (widget.isActive && widget.positionListenable != null) {
      // Active line: ONE GPU canvas paint for the whole line. The idle
      // paragraph paints once, the active paragraph is clipped to the
      // sweep, and the position listenable repaints only this
      // CustomPaint — no per-syllable ShaderMask (each of which is a
      // saveLayer) and no widget rebuilds at tick rate.
      content = _DesktopKaraokeLine(
        line: widget.line,
        position: widget.positionListenable!,
        style: widget.kineticStyle,
        activeStyle: activeStyle,
        idleStyle: widget.kineticStyle == LyricsKineticStyle.minimal
            ? activeUnsungStyle.copyWith(
                color: activeTextColor.withValues(alpha: 0.26),
              )
            : activeUnsungStyle,
        isRtl: widget.line.isRtl,
        wordByWord: widget.wordByWord,
        signature:
            '${baseFontSize}_${dark}_${tracking}_${widget.kineticStyle.name}',
      );
    } else if (effectiveSyllables.isNotEmpty) {
      final words =
          groupSyllablesIntoWords(effectiveSyllables, widget.line.text);

      Widget buildSyllableWrap(int posMs) {
        return Wrap(
          textDirection:
              widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final word in words)
              Row(
                mainAxisSize: MainAxisSize.min,
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
                children: [
                  for (final syl in word.syllables)
                    _KaraokeSyllableWidget(
                      text: syl.text.trimRight(),
                      progress: calculateSyllableProgress(syl, posMs),
                      activeStyle: activeStyle,
                      idleStyle: activeUnsungStyle,
                      highlightColor: accent,
                      isRtl: widget.line.isRtl,
                    ),
                  if (word.hasTrailingSpace) Text(' ', style: activeUnsungStyle),
                ],
              ),
          ],
        );
      }

      if (widget.positionListenable != null) {
        content = ValueListenableBuilder<int>(
          valueListenable: widget.positionListenable!,
          builder: (context, posMs, _) => buildSyllableWrap(posMs),
        );
      } else {
        content = buildSyllableWrap(widget.positionMs);
      }
    } else {
      // Standard line-timed or idle line
      final fade = widget.isActive
          ? (style: activeStyle, alpha: 1.0)
          : _groupFade(idleStyle, widget.line.text);
      content = Text(
        widget.line.text,
        style: fade.style,
        textDirection: widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
        softWrap: true,
        overflow: TextOverflow.visible,
      );
      if (fade.alpha < 1.0) {
        content = Opacity(opacity: fade.alpha, child: content);
      }
    }

    final showBlur =
        widget.softenIdle && !widget.isActive && !_isHovered && !reduceMotion;

    Widget body = AnimatedDefaultTextStyle(
      duration: WaveMotion.fast,
      style: widget.isActive ? activeStyle : idleStyle,
      child: Column(
        crossAxisAlignment:
            widget.line.isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          if (widget.showTransliteration && widget.line.transliteration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.line.transliteration,
                style: TextStyle(
                  fontSize: baseFontSize * 0.52,
                  fontStyle: FontStyle.italic,
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha: widget.isActive ? 0.72 : 0.40,
                  ),
                ),
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
              ),
            ),
        ],
      ),
    );

    if (showBlur) {
      body = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: widget.karaoke ? 1.15 : 1.8,
          sigmaY: widget.karaoke ? 1.15 : 1.8,
        ),
        child: body,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: WaveMotion.normal,
        curve: Curves.easeOutCubic,
        transform: Matrix4.diagonal3Values(
          widget.isActive ? 1.025 : 1.0,
          widget.isActive ? 1.025 : 1.0,
          1.0,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 8 : 12,
          vertical: widget.karaoke ? 4 : 8,
        ),
        decoration: BoxDecoration(
          color: _isHovered && !widget.isActive
              ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }
}

/// Joined scripts (Devanagari, …) overlap neighbouring glyphs on purpose so
/// the headline bar reads as one stroke. Translucent colour is applied per
/// glyph, so those overlaps blend twice and show as bright dots. Draw the
/// run opaque and fade it as a group instead.
({TextStyle style, double alpha}) _groupFade(TextStyle s, String text) {
  final c = s.color;
  if (c == null || c.a >= 0.999 || !isJoinedScript(text)) {
    return (style: s, alpha: 1.0);
  }
  return (style: s.copyWith(color: c.withValues(alpha: 1.0)), alpha: c.a);
}

/// Progressive fill / wipe for an individual syllable with soft anti-aliased edge.
class _KaraokeSyllableWidget extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle activeStyle;
  final TextStyle idleStyle;
  final Color highlightColor;
  final bool isRtl;

  const _KaraokeSyllableWidget({
    required this.text,
    required this.progress,
    required this.activeStyle,
    required this.idleStyle,
    required this.highlightColor,
    this.isRtl = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    if (progress <= 0.0) {
      final fade = _groupFade(idleStyle, text);
      final label = Text(text, style: fade.style);
      return fade.alpha < 1.0
          ? Opacity(opacity: fade.alpha, child: label)
          : label;
    }
    if (progress >= 1.0) {
      return Text(text, style: activeStyle);
    }

    final activeColor = activeStyle.color ?? Colors.white;
    final idleColor = idleStyle.color ?? const Color(0x61FFFFFF);

    const feather = 0.035;
    final stop1 = (progress - feather).clamp(0.0, 1.0);
    final stop2 = (progress + feather).clamp(0.0, 1.0);

    // Joined scripts paint the unsung tail as one opaque run and fade it
    // as a group; the active portion is masked on top. Per-glyph alpha
    // would double-composite where those glyphs overlap (bright dots).
    if (isJoinedScript(text)) {
      final idleFade = _groupFade(idleStyle, text);
      final idle = Text(text, style: idleFade.style);
      return Stack(
        children: [
          if (idleFade.alpha < 1.0)
            Opacity(opacity: idleFade.alpha, child: idle)
          else
            idle,
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: isRtl ? Alignment.centerRight : Alignment.centerLeft,
                end: isRtl ? Alignment.centerLeft : Alignment.centerRight,
                colors: [
                  activeColor,
                  activeColor,
                  const Color(0x00000000),
                  const Color(0x00000000),
                ],
                stops: [0.0, stop1, stop2, 1.0],
              ).createShader(bounds);
            },
            child: Text(text, style: activeStyle),
          ),
        ],
      );
    }

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: isRtl ? Alignment.centerRight : Alignment.centerLeft,
          end: isRtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            activeColor,
            activeColor,
            idleColor,
            idleColor,
          ],
          stops: [0.0, stop1, stop2, 1.0],
        ).createShader(bounds);
      },
      child: Text(text, style: activeStyle),
    );
  }
}



/// Top toolbar with timing controls, transliteration toggle, and close button.
/// Lyrics source switcher (Now Playing toolbar): Auto + every provider
/// with the effective pick checked, plus `Try another source` which
/// re-runs the race excluding the current provider.
class _SourceMenu extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;

  const _SourceMenu({required this.track, required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueKey = track.queueKey;
    final override = ref.watch(lyricsProviderOverrideProvider(queueKey));
    final defaultId =
        ref.watch(prefsProvider.select((p) => p.lyricsProviderId));
    final effective = override ?? defaultId;
    final currentId = lyricsSourceToProviderId(result.source);

    void apply(String? pickedId) {
      if (pickedId == null) {
        ref
            .read(lyricsExcludedProvidersProvider(queueKey).notifier)
            .state = retryLyricsExcludingCurrent(
          currentId: currentId,
          excludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
      } else {
        final next = nextLyricsSelection(
          pickedId: pickedId,
          currentId: currentId,
          currentExcludes:
              ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
        ref.read(lyricsProviderOverrideProvider(queueKey).notifier).state =
            next.override;
        ref.read(lyricsExcludedProvidersProvider(queueKey).notifier).state =
            next.excludes;
      }
      ref.invalidate(waveLyricsProvider(queueKey));
    }

    return LWTooltip(
      message: result.source.isNotEmpty
          ? 'Source: ${result.source} · Change'
          : 'Change lyrics source',
      child: DropDownButton(
        placement: FlyoutPlacementMode.bottomRight,
        transitionBuilder: fastFlyoutTransition,
        items: [
          for (final provider in LyricsProviderId.values)
            MenuFlyoutItem(
              leading: effective == provider.id
                  ? const Icon(FluentIcons.check_mark, size: 13)
                  : const SizedBox(width: 13),
              text: Text(provider.title),
              onPressed: () => apply(provider.id),
            ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.refresh, size: 13),
            text: const Text('Try another source'),
            onPressed: () => apply(null),
          ),
        ],
        buttonBuilder: (context, onOpen) => _MiniIconButton(
          icon: WaveIcons.lyrics,
          onTap: () => onOpen?.call(),
        ),
      ),
    );
  }
}

class _KaraokeToolbar extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;
  final int offsetMs;
  final bool showTransliteration;
  final bool following;
  final bool compact;
  final bool wordByWord;
  final VoidCallback? onClose;
  final VoidCallback onToggleFollowing;

  const _KaraokeToolbar({
    required this.track,
    required this.result,
    required this.offsetMs,
    required this.showTransliteration,
    required this.following,
    required this.compact,
    this.wordByWord = true,
    this.onClose,
    required this.onToggleFollowing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final offsetNotifier =
        ref.read(lyricsOffsetProvider(track.queueKey).notifier);
    final transliterationNotifier =
        ref.read(lyricsTransliterationProvider.notifier);

    final offsetDisplay = formatOffsetDisplay(offsetMs);
    // Offset / transliteration / follow all act on lyric content. With
    // no lyrics (empty or instrumental) they are dead controls, but the
    // source switcher must stay: a miss is exactly when it is needed.
    final hasLyrics = !result.isEmpty && !result.isInstrumental;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 8 : 4,
        4,
        compact ? 8 : 4,
        8,
      ),
      child: WaveGlass(
        blur: false,
        borderRadius: WaveRadius.floatingRadius,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: 6,
        ),
        child: Row(
        children: [
          Expanded(
            child: Text(
              wordByWord
                  ? (result.isWordSynced
                      ? 'Karaoke · Syllable Synced'
                      : result.isSynced
                          ? 'Synced Lyrics'
                          : result.source.isNotEmpty
                              ? result.source
                              : 'Lyrics')
                  : result.isSynced
                      ? 'Apple Music · Line Synced'
                      : result.source.isNotEmpty
                          ? result.source
                          : 'Lyrics',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontWeight: FontWeight.w600,
                color: waveTextPrimary(context),
              ),
            ),
          ),
          // Lyrics source switcher: pick a provider (tried first, the
          // current one excluded from fallback) or retry with the best
          // provider excluding the current one.
          _SourceMenu(
            track: track,
            result: result,
          ),
          const SizedBox(width: 8),
          // Timing Offset Controls: [-] offset [+] [Reset]
          if (hasLyrics) Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
              border: Border.all(
                color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LWTooltip(
                  message: 'Lyrics earlier (-0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.remove,
                    onTap: () => offsetNotifier.adjust(-500),
                  ),
                ),
                LWTooltip(
                  message: 'Timing offset for this track',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      offsetDisplay,
                      style: WaveType.meta.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        color: offsetMs != 0
                            ? accent
                            : waveTextPrimary(context),
                      ),
                    ),
                  ),
                ),
                LWTooltip(
                  message: 'Lyrics later (+0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.add,
                    onTap: () => offsetNotifier.adjust(500),
                  ),
                ),
                if (offsetMs != 0)
                  LWTooltip(
                    message: 'Reset offset to 0.0s',
                    child: _MiniIconButton(
                      icon: FluentIcons.reset,
                      onTap: offsetNotifier.reset,
                    ),
                  ),
              ],
            ),
          ),
          if (hasLyrics) const SizedBox(width: 8),
          // Transliteration / Romaji Toggle
          if (hasLyrics) LWTooltip(
            message: showTransliteration
                ? 'Transliteration enabled'
                : 'Enable transliteration',
            child: _MiniIconButton(
              icon: FluentIcons.globe,
              active: showTransliteration,
              onTap: transliterationNotifier.toggle,
            ),
          ),
          if (hasLyrics) const SizedBox(width: 4),
          if (hasLyrics) LWTooltip(
            message: following
                ? 'Pause automatic scrolling'
                : 'Return to the line being sung',
            child: _MiniIconButton(
              icon: following ? FluentIcons.pin : FluentIcons.unpin,
              active: following,
              onTap: onToggleFollowing,
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: 6),
            LWTooltip(
              message: 'Close panel',
              child: _MiniIconButton(
                icon: WaveIcons.close,
                onTap: onClose!,
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }
}

class _MiniIconButton extends StatefulWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _MiniIconButton({
    required this.icon,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_MiniIconButton> createState() => _MiniIconButtonState();
}

class _MiniIconButtonState extends State<_MiniIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final color = widget.active
        ? accent
        : _hover
            ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            : (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
                .withValues(alpha: 0.88);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}

/// Floating "Return to current" pill when manual scrolling is engaged.
class _ReturnToCurrentPill extends StatelessWidget {
  final VoidCallback onTap;
  const _ReturnToCurrentPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);

    return WaveHaze(
      level: LwHazeLevel.l2,
      base: waveSurfaceRaised(context)
          .withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: waveDivider(context)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.down, size: 12, color: accent),
                const SizedBox(width: 6),
                Text(
                  'Return to current',
                  style: WaveType.label.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple Music default lyrics: the whole current line is sharp and
/// fully lit. Past and upcoming lines stay dim with a slight blur.
class _AppleLineLyricsView extends StatefulWidget {
  final LyricsResult result;
  final ValueNotifier<int> positionListenable;
  final bool compact;
  final double? fontSize;
  final bool showTransliteration;
  final bool following;
  final bool wordByWord;
  final LyricsKineticStyle kineticStyle;
  final VoidCallback onUserScroll;
  final VoidCallback onResume;
  final ValueChanged<int> onSeekLineMs;

  const _AppleLineLyricsView({
    required this.result,
    required this.positionListenable,
    required this.compact,
    required this.fontSize,
    required this.showTransliteration,
    required this.following,
    required this.wordByWord,
    required this.kineticStyle,
    required this.onUserScroll,
    required this.onResume,
    required this.onSeekLineMs,
  });

  @override
  State<_AppleLineLyricsView> createState() => _AppleLineLyricsViewState();
}

/// One scrollable unit: either a lead line with its nested accompaniment,
/// or the 3-dot countdown that fills a >= 3.5s instrumental break.
class _LyricsRow {
  final LyricLineGroup? group;
  final int startMs;
  final int endMs;

  const _LyricsRow.group(this.group, {required this.startMs, required this.endMs});

  const _LyricsRow.interlude({required this.startMs, required this.endMs})
      : group = null;

  bool get isInterlude => group == null;
  int get timeMs => startMs;
}

class _AppleLineLyricsViewState extends State<_AppleLineLyricsView> {
  final ItemScrollController _scroll = ItemScrollController();
  int _lastIndex = -1;
  bool _pinnedOpening = false;
  // Row output depends only on (active, following, untimed, style) — the
  // per-tick position just selects the active row; the active row paints
  // itself from the position listenable.
  Widget? _listCache;
  int _listCacheActive = -2;
  bool _listCacheFollowing = true;
  bool _listCacheUntimed = false;

  List<_LyricsRow>? _rowsCache;
  LyricsResult? _rowsSource;

  List<_LyricsRow> _rows() {
    if (_rowsSource == widget.result && _rowsCache != null) {
      return _rowsCache!;
    }
    final groups = <LyricLineGroup>[
      for (final stanza in assembleStanzas(widget.result.lines)) ...stanza.groups,
    ];
    final rows = <_LyricsRow>[];
    int? prevEnd;
    for (final group in groups) {
      final int start = group.timeMs;
      final int end = start + math.max<int>(group.durationMs, 1);
      if (prevEnd != null &&
          start - prevEnd >=
              DesktopLyricsTokens.instrumentalCountdownThresholdMs) {
        rows.add(_LyricsRow.interlude(startMs: prevEnd, endMs: start));
      }
      rows.add(_LyricsRow.group(group, startMs: start, endMs: end));
      prevEnd = start + math.max<int>(group.durationMs, 1000);
    }
    _rowsSource = widget.result;
    _rowsCache = rows;
    return rows;
  }

  int _activeRow(List<_LyricsRow> rows, int posMs) {
    var lo = 0;
    var hi = rows.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].startMs <= posMs) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  int _activeIndex(int posMs) => _activeRow(_rows(), posMs);

  void _scrollTo(int index, {bool animate = true}) {
    if (!_scroll.isAttached) return;
    if (index < 0) index = 0;
    final alignment = lyricFollowAlignment(
      index,
      compact: widget.compact,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Guarded: a stale index (lyrics swapped mid-flight) throws
      // RangeError here, which aborts the process via fail-fast.
      runGuarded('karaoke.scroll', () {
        if (!_scroll.isAttached || !mounted) return;
        if (animate) {
          _scroll.scrollTo(
            index: index,
            alignment: alignment,
            duration: WaveMotion.normal,
            curve: Curves.easeOutCubic,
          );
        } else {
          _scroll.jumpTo(index: index, alignment: alignment);
        }
      });
    });
  }

  void _pinOpeningToTop() {
    if (_pinnedOpening || !_scroll.isAttached) return;
    _pinnedOpening = true;
    _scrollTo(0, animate: false);
  }

  @override
  void didUpdateWidget(covariant _AppleLineLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _pinnedOpening = false;
      _lastIndex = -1;
      _listCache = null;
      _rowsCache = null;
      _rowsSource = null;
    }
    if (oldWidget.wordByWord != widget.wordByWord ||
        oldWidget.kineticStyle != widget.kineticStyle ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.compact != widget.compact) {
      _listCache = null;
    }
    if (widget.following && !oldWidget.following) {
      final untimed = lyricsAreUntimed(widget.result.lines);
      _scrollTo(
        untimed ? 0 : _activeIndex(widget.positionListenable.value),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final untimed = lyricsAreUntimed(widget.result.lines);
    if (untimed) {
      // Do not rebuild on the playback clock — that remounts the list
      // and hides every line past the first screen.
      return _buildLineList(posMs: 0, active: -1, untimed: true);
    }

    return ValueListenableBuilder<int>(
      valueListenable: widget.positionListenable,
      builder: (context, posMs, _) {
        final active = _activeIndex(posMs);
        if (widget.following && _scroll.isAttached) {
          if (posMs < 400 || active < 0) {
            _pinOpeningToTop();
            _lastIndex = active;
          } else if (active != _lastIndex) {
            final wasUninitialized = _lastIndex < 0;
            _lastIndex = active;
            _scrollTo(
              active,
              animate: !wasUninitialized && active > 0,
            );
          }
        } else if (!widget.following) {
          _lastIndex = active;
        }

        if (_listCache == null ||
            active != _listCacheActive ||
            widget.following != _listCacheFollowing ||
            untimed != _listCacheUntimed) {
          _listCacheActive = active;
          _listCacheFollowing = widget.following;
          _listCacheUntimed = untimed;
          _listCache = _buildLineList(
            posMs: posMs,
            active: active,
            untimed: false,
          );
        }
        return _listCache!;
      },
    );
  }

  Widget _buildLineList({
    required int posMs,
    required int active,
    required bool untimed,
  }) {
    final rows = untimed
        ? <_LyricsRow>[
            for (final line in widget.result.lines)
              _LyricsRow.group(
                LyricLineGroup(leadLine: line, role: VocalRole.leadLeft),
                startMs: line.timeMs,
                endMs: line.timeMs,
              ),
          ]
        : _rows();
    final paneWidth = MediaQuery.sizeOf(context).width;
    final duetMaxWidth =
        widget.compact ? paneWidth : paneWidth * DesktopLyricsTokens.maxDuetWidthRatio;
    final isDark = waveIsDark(context);

    Widget staged(Widget child, VocalRole role) {
      final Alignment alignment = switch (role) {
        VocalRole.duetRight => Alignment.centerRight,
        VocalRole.unisonCenter => Alignment.center,
        _ => Alignment.centerLeft,
      };
      return Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: role == VocalRole.leadLeft ||
                    role == VocalRole.backgroundSubline
                ? paneWidth
                : duetMaxWidth,
          ),
          child: child,
        ),
      );
    }

    Widget lineWidget(
      LyricLine line,
      VocalRole role, {
      required bool activeRow,
      required bool past,
    }) {
      return WaveKaraokeLyricLine(
        line: line,
        positionMs: posMs,
        positionListenable: activeRow ? widget.positionListenable : null,
        isActive: activeRow,
        isPast: past,
        compact: widget.compact,
        fontSize: widget.fontSize,
        showTransliteration: widget.showTransliteration,
        karaoke: false,
        softenIdle: !untimed,
        role: role,
        kineticStyle: widget.kineticStyle,
        wordByWord: widget.wordByWord,
      );
    }

    Widget lineAt(int i) {
      final row = rows[i];
      if (row.isInterlude) {
        return RepaintBoundary(
          child: _InstrumentalCountdown(
            startMs: row.startMs,
            endMs: row.endMs,
            positionListenable: widget.positionListenable,
            compact: widget.compact,
          ),
        );
      }

      final group = row.group!;
      final lead = group.leadLine;
      final activeRow = i == active;
      final past = !untimed && i < active;

      final children = <Widget>[
        lineWidget(lead, group.role, activeRow: activeRow, past: past),
      ];
      for (final bg in group.backgroundSublines) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 2),
          child: lineWidget(
            bg,
            VocalRole.backgroundSubline,
            activeRow: activeRow,
            past: past,
          ),
        ));
      }

      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: switch (group.role) {
          VocalRole.duetRight => CrossAxisAlignment.end,
          VocalRole.unisonCenter => CrossAxisAlignment.center,
          _ => CrossAxisAlignment.start,
        },
        children: children,
      );

      // Isolate each row: without this, the active line's per-tick
      // repaints (canvas sweep + shadow) cascade into sibling rows,
      // re-rasterizing the whole pane ~30×/sec.
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => widget.onSeekLineMs(row.timeMs),
              child: staged(content, group.role),
            ),
          ),
        ),
      );
    }

    final padding = EdgeInsets.fromLTRB(
      widget.compact ? 12 : 28,
      24,
      widget.compact ? 12 : 28,
      80,
    );

    final Widget rawList = untimed
        ? ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: ListView.builder(
              physics: const ClampingScrollPhysics(),
              padding: padding,
              itemCount: rows.length,
              itemBuilder: (context, i) => lineAt(i),
            ),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                widget.onUserScroll();
              }
              return false;
            },
            // The app-wide scrollbar flashes on every programmatic
            // follow-scroll; lyrics are tap/wheel/drag driven, so it
            // carries no information here.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: ScrollablePositionedList.builder(
                itemScrollController: _scroll,
                initialScrollIndex: active > 0 ? active : 0,
                initialAlignment: lyricFollowAlignment(
                  active > 0 ? active : 0,
                  compact: widget.compact,
                ),
                itemCount: rows.length,
                padding: padding,
                itemBuilder: (context, i) => lineAt(i),
              ),
            ),
          );

    // Static edge feather: the list composites through one static mask so
    // lines dissolve under the toolbar instead of being hard-clipped.
    // No ticker, no per-frame shader rebuild.
    final list = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0.0, isDark ? 0.09 : 0.07, 0.90, 1.0],
      ).createShader(rect),
      child: rawList,
    );

    return Stack(
      children: [
        list,
        if (!untimed && !widget.following)
          Positioned(
            right: 16,
            bottom: 16,
            child: _ReturnToCurrentPill(onTap: widget.onResume),
          ),
      ],
    );
  }
}

/// 3-dot pulsating indicator used for instrumental breaks of 3.5s or
/// longer. Driven entirely by the position listenable, so it costs one
/// tiny CustomPaint-free rebuild per tick and nothing while idle.
class _InstrumentalCountdown extends StatelessWidget {
  final int startMs;
  final int endMs;
  final ValueListenable<int> positionListenable;
  final bool compact;

  const _InstrumentalCountdown({
    required this.startMs,
    required this.endMs,
    required this.positionListenable,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = WaveMotion.respectReduce(context);
    final accent = waveAccent(context);
    final idle = (waveIsDark(context) ? Colors.white : Colors.black)
        .withValues(alpha: 0.20);

    return SizedBox(
      key: const ValueKey('lyrics-instrumental-countdown'),
      height: compact ? 44 : 60,
      child: ValueListenableBuilder<int>(
        valueListenable: positionListenable,
        builder: (context, posMs, _) {
          final total = math.max(1, endMs - startMs);
          final progress =
              ((posMs - startMs) / total).clamp(0.0, 1.0);
          // 3 dots across the break: dot i owns the middle third of its
          // own slot, so the pulse reads left-to-right instead of
          // blinking the whole row.
          final beat = (progress * 3).floor();
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !reduceMotion && i == beat ? accent : idle,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Active-line canvas host. Owns one [ParagraphLayoutCache] for the one
/// line it paints; the cache is disposed when the row stops being active,
/// so paragraph memory never outlives the visible line.
class _DesktopKaraokeLine extends StatefulWidget {
  final LyricLine line;
  final ValueListenable<int> position;
  final LyricsKineticStyle style;
  final TextStyle activeStyle;
  final TextStyle idleStyle;
  final bool isRtl;
  final bool wordByWord;
  final String signature;

  const _DesktopKaraokeLine({
    required this.line,
    required this.position,
    required this.style,
    required this.activeStyle,
    required this.idleStyle,
    required this.isRtl,
    required this.wordByWord,
    required this.signature,
  });

  @override
  State<_DesktopKaraokeLine> createState() => _DesktopKaraokeLineState();
}

class _DesktopKaraokeLineState extends State<_DesktopKaraokeLine> {
  final ParagraphLayoutCache _cache = ParagraphLayoutCache(maxEntries: 4);

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : 640.0;
        final activeColor = widget.activeStyle.color;
        final layout = _cache.getOrCreate(
          line: widget.line,
          maxWidth: maxWidth,
          activeStyle: widget.activeStyle,
          idleStyle: widget.idleStyle,
          softStyle: widget.activeStyle.copyWith(
            color: activeColor?.withValues(alpha: 0.72),
          ),
          faintStyle: widget.activeStyle.copyWith(
            color: activeColor?.withValues(alpha: 0.42),
          ),
          signature: '${widget.signature}_${maxWidth.round()}',
          isRtl: widget.isRtl,
        );
        return SizedBox(
          width: math.min(layout.width, maxWidth),
          height: layout.height,
          child: CustomPaint(
            painter: DesktopKaraokeLinePainter(
              positionListenable: widget.position,
              line: widget.line,
              layout: layout,
              style: widget.style,
              isRtl: widget.isRtl,
              wordByWord: widget.wordByWord,
            ),
          ),
        );
      },
    );
  }
}

class _KaraokePlainLyrics extends StatelessWidget {
  final String text;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;

  const _KaraokePlainLyrics({
    required this.text,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeaderControls)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 24,
              vertical: 8,
            ),
            child: Row(
              children: [
                Text(
                  'PLAIN LYRICS',
                  style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveAccent(context),
                  ),
                ),
                const Spacer(),
                if (onClose != null)
                  _MiniIconButton(
                    icon: WaveIcons.close,
                    onTap: onClose!,
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.all(compact ? 14 : 28),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: WaveDensity.lyricMax,
                  ),
                  child: SelectableText(
                    text,
                    style: WaveType.body.copyWith(
                      height: 1.75,
                      fontSize: compact ? 18 : 22,
                      color: dark
                          ? WaveColors.textPrimary
                          : WaveColors.lightTextPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
