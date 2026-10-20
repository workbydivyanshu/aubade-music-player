import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Single-line marquee that only moves when the text actually overflows.
///
/// Long track titles were truncated to an ellipsis on the dock, Now Playing
/// hero and mini player (C3). This widget measures the real laid-out width
/// on every layout pass, so short titles never animate, and long titles
/// scroll once — returning to rest between passes — instead of being cut.
///
/// Reduced motion: [WaveMotion.respectReduce] pins the text to a static
/// ellipsis (same waiver as the karaoke verse). Motion is never decorative
/// information.
///
/// Restart-on-track-change is the caller's job: pass a `ValueKey(trackId)`
/// so the state (and therefore the scroll position) is rebuilt per track.
class WaveMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Overflow threshold. A title that fits within this many lines stays
  /// static; one that exceeds it scrolls on a single line.
  final int maxLines;
  final TextAlign textAlign;

  /// Pause before the first movement and between passes.
  final Duration rest;

  /// Scroll speed for the overflow distance.
  final double pixelsPerSecond;

  const WaveMarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
    this.rest = const Duration(milliseconds: 1400),
    this.pixelsPerSecond = 38,
  });

  @override
  State<WaveMarqueeText> createState() => _WaveMarqueeTextState();
}

class _WaveMarqueeTextState extends State<WaveMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this);
  double _distance = 0;

  @override
  void didUpdateWidget(covariant WaveMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 0 → rest → travel → rest, then the repeat restarts at 0. Both ends are
  /// held so the eye can read the start and the tail.
  double _offsetFor(double t) {
    const restStart = 0.16;
    const travelEnd = 0.88;
    if (t <= restStart) return 0;
    if (t >= travelEnd) return -_distance;
    final p = (t - restStart) / (travelEnd - restStart);
    return -_distance * Curves.easeInOutCubic.transform(p);
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final reduceMotion = WaveMotion.respectReduce(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite || maxWidth <= 0) {
          return Text(widget.text,
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
              textAlign: widget.textAlign);
        }

        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.maxLines,
          textAlign: widget.textAlign,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: maxWidth);
        final overflows = painter.didExceedMaxLines;
        final height = painter.height;

        // Full single-line width, used to know how far the marquee travels.
        painter.layout();
        final travel = math.max(0.0, painter.width - maxWidth + 12);
        _distance = travel;

        final animate = overflows && !reduceMotion && travel > 0;
        if (!animate) {
          _controller.stop();
          _controller.value = 0;
          return Text(widget.text,
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
              textAlign: widget.textAlign);
        }

        final travelMs =
            (travel / math.max(12, widget.pixelsPerSecond) * 1000).round();
        final duration = widget.rest * 2 +
            Duration(milliseconds: travelMs.clamp(900, 8000).toInt());
        if (_controller.duration != duration) {
          _controller.duration = duration;
        }
        if (!_controller.isAnimating) {
          _controller.repeat();
        }

        return ClipRect(
          child: SizedBox(
            width: maxWidth,
            height: height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(_offsetFor(_controller.value), 0),
                child: child,
              ),
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: style,
                  textAlign: widget.textAlign,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
