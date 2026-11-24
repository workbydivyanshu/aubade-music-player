import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'lyrics_models.dart';

/// Selectable kinetic typography for the desktop karaoke line.
///
/// Every style shares the same glyph layout and sweep math; they differ
/// only in decoration (glow), lift amplitude, and edge softness, so
/// switching styles never re-measures text mid-line.
enum LyricsKineticStyle {
  classic('Classic'),
  glow('Glow'),
  dynamic('Dynamic'),
  smooth('Smooth'),
  minimal('Minimal');

  const LyricsKineticStyle(this.label);

  final String label;

  static LyricsKineticStyle fromId(String? id) {
    for (final s in values) {
      if (s.name == id) return s;
    }
    return LyricsKineticStyle.classic;
  }

  /// Vertical spring lift at the syllable midpoint, in logical pixels.
  double get lift {
    switch (this) {
      case LyricsKineticStyle.dynamic:
        return 3.5;
      case LyricsKineticStyle.glow:
        return 1.5;
      case LyricsKineticStyle.classic:
      case LyricsKineticStyle.smooth:
      case LyricsKineticStyle.minimal:
        return 0;
    }
  }

  bool get hasGlow => this == LyricsKineticStyle.glow;

  /// Soft trailing edge after the sweep. Drawn as two narrow translucent
  /// bands instead of a saveLayer mask, so the line stays one layer.
  bool get hasSoftEdge => this == LyricsKineticStyle.smooth;

  bool get showsShadow =>
      this == LyricsKineticStyle.glow || this == LyricsKineticStyle.dynamic;
}

/// Visual tokens adapted from the Apple Music karaoke proportions.
class DesktopLyricsTokens {
  const DesktopLyricsTokens._();

  static const double fontSizeBase = 36.0;
  static const double lineHeight = 1.35;
  static const double inactiveScale = 0.96;
  static const double inactiveOpacity = 0.35;

  /// Background vocals / sub-paragraphs.
  static const double backgroundVocalFontScale = 0.65;
  static const double backgroundVocalSpacing = 15.0;
  static const double backgroundVocalScale = 0.90;

  /// Viewport & layout.
  static const double scrollPaddingTopRatio = 0.18;
  static const double maxDuetWidthRatio = 0.72;
  static const double inlinePadding = 36.0;

  /// An instrumental gap at or above this length earns the 3-dot
  /// countdown indicator.
  static const int instrumentalCountdownThresholdMs = 3500;

  /// Feather width for [LyricsKineticStyle.smooth].
  static const double softEdgeWidth = 14.0;
}

/// Pre-computed text layout and syllable metrics for one lyric line.
///
/// Paragraphs are expensive to build (shaping + line breaking) and cheap
/// to paint, so they are built once per (line, width, style) and reused
/// for every frame of the sweep. The cache owns the native objects and
/// disposes them; never share one cache across differently-styled views.
class CachedLineLayout {
  CachedLineLayout({
    required this.idleParagraph,
    required this.activeParagraph,
    required this.softParagraph,
    required this.faintParagraph,
    required this.width,
    required this.height,
    required this.boxWidth,
    required this.syllableOffsetsX,
  });

  final ui.Paragraph idleParagraph;
  final ui.Paragraph activeParagraph;
  final ui.Paragraph softParagraph;
  final ui.Paragraph faintParagraph;
  final double width;
  final double height;

  /// Layout width the paragraph was built against (matters for RTL,
  /// where the text hugs the right edge of this box).
  final double boxWidth;
  final List<double> syllableOffsetsX;

  void dispose() {
    idleParagraph.dispose();
    activeParagraph.dispose();
    softParagraph.dispose();
    faintParagraph.dispose();
  }
}

/// Per-view layout cache. Keyed by line start plus a layout signature, so
/// a width or theme change invalidates cleanly instead of painting with
/// stale metrics.
class ParagraphLayoutCache {
  ParagraphLayoutCache({this.maxEntries = 160});

  final int maxEntries;
  final Map<int, CachedLineLayout> _cache = {};
  String _signature = '';
  final List<int> _order = [];

  CachedLineLayout getOrCreate({
    required LyricLine line,
    required double maxWidth,
    required TextStyle activeStyle,
    required TextStyle idleStyle,
    required TextStyle softStyle,
    required TextStyle faintStyle,
    String signature = '',
    bool isRtl = false,
  }) {
    if (_signature != signature) {
      clear();
      _signature = signature;
    }
    final hit = _cache[line.timeMs];
    if (hit != null) return hit;

    final textAlign = isRtl ? TextAlign.right : TextAlign.left;
    final direction = isRtl ? TextDirection.rtl : TextDirection.ltr;

    ui.Paragraph build(TextStyle style) {
      final builder = ui.ParagraphBuilder(
        style.getParagraphStyle(textAlign: textAlign, textDirection: direction),
      )..pushStyle(style.getTextStyle());
      builder.addText(line.text);
      return builder.build()
        ..layout(ui.ParagraphConstraints(width: maxWidth));
    }

    final idlePara = build(idleStyle);
    final activePara = build(activeStyle);
    final softPara = build(softStyle);
    final faintPara = build(faintStyle);

    // Syllable boundaries in the ACTIVE paragraph: boxes, not guessed
    // advances, so kerning and joined scripts stay aligned.
    final offsetsX = <double>[0.0];
    if (line.hasSyllables) {
      var searchStart = 0;
      for (final syl in line.syllables) {
        final needle = syl.text.trim();
        var startIdx = needle.isEmpty
            ? -1
            : line.text.indexOf(needle, searchStart);
        if (startIdx == -1 && syl.text.isNotEmpty) {
          startIdx = line.text.indexOf(syl.text, searchStart);
        }
        if (startIdx != -1) {
          final endIdx = math.min(startIdx + syl.text.length, line.text.length);
          searchStart = endIdx;
          final boxes = activePara.getBoxesForRange(startIdx, endIdx);
          if (boxes.isNotEmpty) {
            offsetsX.add(boxes.last.right);
            continue;
          }
        }
        offsetsX.add(offsetsX.isEmpty ? 30.0 : offsetsX.last + 30.0);
      }
    } else {
      offsetsX.add(math.max(
        idlePara.maxIntrinsicWidth,
        activePara.maxIntrinsicWidth,
      ));
    }

    final layout = CachedLineLayout(
      idleParagraph: idlePara,
      activeParagraph: activePara,
      softParagraph: softPara,
      faintParagraph: faintPara,
      width: math.max(idlePara.maxIntrinsicWidth, activePara.maxIntrinsicWidth),
      height: math.max(idlePara.height, activePara.height),
      boxWidth: maxWidth,
      syllableOffsetsX: offsetsX,
    );

    _cache[line.timeMs] = layout;
    _order.add(line.timeMs);
    if (_order.length > maxEntries) {
      final oldest = _order.removeAt(0);
      _cache.remove(oldest)?.dispose();
    }
    return layout;
  }

  void clear() {
    for (final layout in _cache.values) {
      layout.dispose();
    }
    _cache.clear();
    _order.clear();
  }

  void dispose() => clear();
}

/// Single-pass GPU canvas painter for the active lyric line.
///
/// Paints the idle paragraph once, then the active paragraph clipped to
/// the current sweep. No widget rebuilds, no `saveLayer`, no per-syllable
/// `ShaderMask`: one `CustomPaint` repaints from a [ValueListenable].
class DesktopKaraokeLinePainter extends CustomPainter {
  DesktopKaraokeLinePainter({
    required this.positionListenable,
    required this.line,
    required this.layout,
    required this.style,
    this.isRtl = false,
    this.wordByWord = true,
  }) : super(repaint: positionListenable);

  final ValueListenable<int> positionListenable;
  final LyricLine line;
  final CachedLineLayout layout;
  final LyricsKineticStyle style;
  final bool isRtl;
  final bool wordByWord;

  @override
  void paint(Canvas canvas, Size size) {
    final posMs = positionListenable.value;

    canvas.drawParagraph(layout.idleParagraph, Offset.zero);
    if (posMs < line.timeMs) return;

    // Sweep position, in one pass over the syllables. No list copies and
    // no closures are allocated per frame.
    var sweepX = 0.0;
    var liftY = 0.0;
    final endMs = line.timeMs + math.max(1, line.durationMs);

    if (posMs >= endMs) {
      sweepX = layout.width;
    } else if (wordByWord && line.hasSyllables && layout.syllableOffsetsX.length > 1) {
      final syllables = line.syllables;
      final offsets = layout.syllableOffsetsX;
      for (var i = 0; i < syllables.length; i++) {
        final syl = syllables[i];
        final sylStart = syl.timeMs;
        final sylEnd = sylStart + math.max(1, syl.durationMs);
        if (posMs >= sylEnd) {
          sweepX = i + 1 < offsets.length ? offsets[i + 1] : layout.width;
          continue;
        }
        if (posMs >= sylStart) {
          final startX = i < offsets.length ? offsets[i] : 0.0;
          final finishX =
              i + 1 < offsets.length ? offsets[i + 1] : layout.width;
          final progress = (posMs - sylStart) / (sylEnd - sylStart);
          sweepX = startX + progress * (finishX - startX);
          if (style.lift != 0) {
            liftY = -style.lift * math.sin(math.pi * progress);
          }
        }
        break;
      }
    } else {
      final progress = (posMs - line.timeMs) / math.max(1, line.durationMs);
      sweepX = progress * layout.width;
      if (style.lift != 0 && progress > 0 && progress < 1) {
        liftY = -style.lift * math.sin(math.pi * progress);
      }
    }

    if (sweepX <= 0) return;

    final clipLeft =
        isRtl ? layout.boxWidth - sweepX : 0.0;
    final clipWidth = math.min(sweepX, layout.width);
    final clipRect = Rect.fromLTWH(clipLeft, -12, clipWidth, layout.height + 24);

    canvas.save();
    canvas.clipRect(clipRect);
    if (liftY != 0) canvas.translate(0, liftY);
    canvas.drawParagraph(layout.activeParagraph, Offset.zero);
    canvas.restore();

    if (style.hasSoftEdge && sweepX < layout.width) {
      // Two narrow bands past the sweep edge approximate a gradient
      // feather without an offscreen layer.
      final band = DesktopLyricsTokens.softEdgeWidth;
      final first = isRtl
          ? Rect.fromLTWH(layout.boxWidth - sweepX - band, -12, band,
              layout.height + 24)
          : Rect.fromLTWH(sweepX, -12, band, layout.height + 24);
      final second = isRtl
          ? Rect.fromLTWH(layout.boxWidth - sweepX - band * 2, -12, band,
              layout.height + 24)
          : Rect.fromLTWH(sweepX + band, -12, band, layout.height + 24);

      canvas.save();
      canvas.clipRect(first);
      canvas.drawParagraph(layout.softParagraph, Offset.zero);
      canvas.restore();

      canvas.save();
      canvas.clipRect(second);
      canvas.drawParagraph(layout.faintParagraph, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant DesktopKaraokeLinePainter oldDelegate) =>
      oldDelegate.line != line ||
      oldDelegate.layout != layout ||
      oldDelegate.style != style ||
      oldDelegate.isRtl != isRtl;
}
