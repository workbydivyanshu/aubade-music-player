import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Keyboard citizenship wrapper for glyph controls.
///
/// Lifted from the side-rail row recipe (`side_rail.dart`): owns a focus
/// node, activates on Enter / NumpadEnter / Space, paints the 1px accent
/// focus ring, and requests focus on pointer-down so mouse and Tab users
/// share the same visible state. The child keeps its own hover / press
/// visuals; this widget only adds focus + activation.
///
/// The dock uses one per glyph; default Flutter traversal order follows
/// the widget tree, which is the dock's visual left→right order.
class FocusGlyph extends StatefulWidget {
  final Widget child;

  /// Enter / Space action. Null (with [enabled] false) removes the glyph
  /// from the Tab order — disabled transport controls stay unreachable.
  final VoidCallback? onActivate;

  final bool enabled;
  final BorderRadius borderRadius;
  final FocusNode? focusNode;
  final bool autofocus;

  const FocusGlyph({
    super.key,
    required this.child,
    this.onActivate,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<FocusGlyph> createState() => _FocusGlyphState();
}

class _FocusGlyphState extends State<FocusGlyph> {
  FocusNode? _ownedNode;

  FocusNode get _node => widget.focusNode ?? (_ownedNode ??= FocusNode());

  @override
  void dispose() {
    _ownedNode?.dispose();
    super.dispose();
  }

  bool get _actionable => widget.enabled && widget.onActivate != null;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    // Read the node directly (the side-rail exemplar does the same): the
    // Focus callback is only a rebuild trigger, so the ring can never lag
    // behind the real focus owner.
    final focused = _node.hasFocus;
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: _actionable,
      skipTraversal: !_actionable,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (!_actionable) return KeyEventResult.ignored;
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onActivate!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _actionable ? (_) => _node.requestFocus() : null,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          // Foreground ring: painting it as a background `border` would
          // inflate the hit target by 2px and nudge the dock row on focus.
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: focused
                  ? accent.withValues(alpha: 0.6)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
