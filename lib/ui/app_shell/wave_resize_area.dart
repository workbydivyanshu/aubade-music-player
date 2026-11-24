import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:window_manager/window_manager.dart';

/// Interactive edge and corner resize overlay for frameless desktop
/// windows (Linux/X11 and Wayland).
///
/// With `TitleBarStyle.hidden` the OS removes the native border and the
/// compositor no longer offers resize grips. This overlays four thin edge
/// handles and four larger corner handles with the matching system
/// cursors, and starts a native resize through
/// [WindowManager.startResizing] on primary-button press.
///
/// The overlay is purely additive: it paints nothing, and every call is
/// best-effort so a missing platform backend degrades to a normal window
/// instead of breaking the shell.
class WaveWindowResizeArea extends StatelessWidget {
  const WaveWindowResizeArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.edgeSize = 4.0,
    this.cornerSize = 14.0,
  });

  final Widget child;

  /// False while maximized/fullscreen, where resize handles are meaningless
  /// and would steal clicks from the title bar and content edges.
  final bool enabled;

  /// Thickness of the four edge grips.
  final double edgeSize;

  /// Side length of the four corner grips.
  final double cornerSize;

  void _startResize(ResizeEdge edge) {
    try {
      windowManager.startResizing(edge);
    } catch (_) {
      // Plugin unavailable (test binding, unsupported platform): the
      // window simply keeps its native behavior.
    }
  }

  Widget _handle({
    required ResizeEdge edge,
    required MouseCursor cursor,
    double? width,
    double? height,
  }) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons == kPrimaryMouseButton) _startResize(edge);
      },
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => _startResize(edge),
          child: SizedBox(width: width, height: height),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // Corners first: they sit above the edge strips at the four
        // meeting points so the diagonal cursor wins there.
        Positioned(
          top: 0,
          left: 0,
          width: cornerSize,
          height: cornerSize,
          child: _handle(
            edge: ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeft,
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          width: cornerSize,
          height: cornerSize,
          child: _handle(
            edge: ResizeEdge.topRight,
            cursor: SystemMouseCursors.resizeUpRight,
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          width: cornerSize,
          height: cornerSize,
          child: _handle(
            edge: ResizeEdge.bottomLeft,
            cursor: SystemMouseCursors.resizeDownLeft,
          ),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          width: cornerSize,
          height: cornerSize,
          child: _handle(
            edge: ResizeEdge.bottomRight,
            cursor: SystemMouseCursors.resizeDownRight,
          ),
        ),
        // Edges span between the corner zones.
        Positioned(
          top: 0,
          left: cornerSize,
          right: cornerSize,
          height: edgeSize,
          child: _handle(
            edge: ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUp,
          ),
        ),
        Positioned(
          bottom: 0,
          left: cornerSize,
          right: cornerSize,
          height: edgeSize,
          child: _handle(
            edge: ResizeEdge.bottom,
            cursor: SystemMouseCursors.resizeDown,
          ),
        ),
        Positioned(
          top: cornerSize,
          bottom: cornerSize,
          left: 0,
          width: edgeSize,
          child: _handle(
            edge: ResizeEdge.left,
            cursor: SystemMouseCursors.resizeLeft,
          ),
        ),
        Positioned(
          top: cornerSize,
          bottom: cornerSize,
          right: 0,
          width: edgeSize,
          child: _handle(
            edge: ResizeEdge.right,
            cursor: SystemMouseCursors.resizeRight,
          ),
        ),
      ],
    );
  }
}
