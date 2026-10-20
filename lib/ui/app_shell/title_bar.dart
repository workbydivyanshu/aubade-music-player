import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart' show fastFlyoutTransition;
import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Compact 44px title / nav / Spotlight bar.
///
/// Left: back · forward
/// Centre-left: Apple Spotlight anchor pill (opens the unified Spotlight
/// modal — duplicate search inputs are gone; /search owns its own field).
/// Right: profile · app menu · window controls
///
/// `searchController` / `searchFocus` / `onSearchSubmit` stay on the
/// signature so app_shell.dart keeps calling the same constructor; the
/// Spotlight owns the search text UI now, and Ctrl+K / Ctrl+F routing is
/// re-owned by wave_hotkeys → app_shell (see showWaveSpotlight).
class WaveTitleBar extends ConsumerWidget {
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchSubmit;
  final VoidCallback onPalette;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  const WaveTitleBar({
    super.key,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchSubmit,
    required this.onPalette,
    required this.canGoBack,
    this.canGoForward = false,
    this.onBack,
    this.onForward,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final auth = ref.watch(authRepositoryProvider);
    return WaveHaze(
      level: LwHazeLevel.l1,
      base: dark
          ? WaveColors.background.withValues(alpha: 0.85)
          : WaveColors.lightBackground.withValues(alpha: 0.9),
      border: Border(
        bottom: BorderSide(color: waveDivider(context)),
      ),
      child: SizedBox(
        height: WaveDensity.titleBar,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final compact = maxW < 700;
            // Spotlight pill budget: wider than the old TextBox (the
            // placeholder copy needs room) but still a minority of the
            // bar so DragToMoveArea keeps winning the middle.
            final pillWidth =
                (maxW * 0.30).clamp(190.0, 340.0).toDouble();
            return Row(
              children: [
                const SizedBox(width: 8),
                _BarBtn(
                  tooltip: 'Back',
                  icon: WaveIcons.back,
                  onTap: canGoBack ? onBack : null,
                ),
                _BarBtn(
                  tooltip: 'Forward',
                  icon: WaveIcons.forward,
                  onTap: canGoForward ? onForward : null,
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: pillWidth,
                  child: _SpotlightPill(
                    onTap: onPalette,
                    showHint: !compact,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DragToMoveArea(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // WinUI: double-click title bar toggles maximize.
                      onDoubleTap: () async {
                        try {
                          if (await windowManager.isMaximized()) {
                            await windowManager.unmaximize();
                          } else {
                            await windowManager.maximize();
                          }
                        } catch (_) {}
                      },
                      child: const SizedBox(
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                ),
                // Profile / account — tiny, no giant buttons.
                GestureDetector(
                  onTap: () {
                    // Your avatar always means your profile: drop any
                    // stale friend view, otherwise /profile would show
                    // whoever you last checked out.
                    ref.read(viewingProfileProvider.notifier).clear();
                    context.go(
                      auth.status == AuthStatus.signedIn
                          ? '/profile'
                          : '/settings?section=lastfm',
                    );
                  },
                  child: LWTooltip(
                    message: auth.status == AuthStatus.signedIn
                        ? auth.username
                        : 'Connect Last.fm',
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dark
                            ? WaveColors.surfaceRaised
                            : WaveColors.lightOverlay,
                        border:
                            Border.all(color: waveDivider(context)),
                      ),
                      child: Center(
                        child: Text(
                          auth.status == AuthStatus.signedIn &&
                                  auth.username.isNotEmpty
                              ? auth.username[0].toUpperCase()
                              : '?',
                          style: WaveType.label
                              .copyWith(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _AppMenu(),
                const SizedBox(width: 6),
                const _WindowButtons(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Apple Spotlight anchor pill: 32px button, borderRadius 8, translucent
/// surface matched to the title-bar chrome, 1px hairline border, search
/// glyph + placeholder copy + bare `Ctrl K` kbd hint.
///
/// Click → [onPalette], which routes to `showWaveSpotlight` (the old
/// command-palette entry point aliases it), so the pill, the app menu
/// and the global Ctrl+K hotkey all land in the same Spotlight.
class _SpotlightPill extends StatefulWidget {
  final VoidCallback onTap;
  final bool showHint;

  const _SpotlightPill({required this.onTap, required this.showHint});
  @override
  State<_SpotlightPill> createState() => _SpotlightPillState();
}

class _SpotlightPillState extends State<_SpotlightPill> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final tint = dark ? Colors.white : Colors.black;
    final hint = widget.showHint;
    // Hover/press washes follow WaveState deltas; the resting background
    // is a quiet 6% (dark) / 4.5% (light) translucent surface so the
    // pill reads as chrome, not as a form field.
    final alpha = _pressed
        ? (dark ? 0.14 : 0.12)
        : _hover
            ? (dark ? 0.10 : 0.07)
            : (dark ? 0.06 : 0.045);
    return LWTooltip(
      message: 'Search (Ctrl+K)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            curve: WaveMotion.standard,
            height: 32,
            padding:
                EdgeInsets.only(left: 10, right: hint ? 10 : 12),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(8),
              // 1px hairline — 0x14FFFFFF equivalent for the dark bar.
              border: Border.all(
                color: dark
                    ? const Color(0x14FFFFFF)
                    : Colors.black.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  WaveIcons.search,
                  size: 14,
                  color: waveTextTertiary(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Search tracks, albums, artists, commands…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.label.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ),
                if (hint) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Ctrl K',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                      color: waveTextTertiary(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarBtn extends StatefulWidget {
  final String tooltip;
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onTap;
  const _BarBtn(
      {required this.tooltip, this.icon, this.iconWidget, this.onTap})
      : assert(icon != null || iconWidget != null,
            'Provide icon or iconWidget');
  @override
  State<_BarBtn> createState() => _BarBtnState();
}

class _BarBtnState extends State<_BarBtn> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            width: WaveDensity.hitArea,
            height: WaveDensity.hitArea,
            decoration: BoxDecoration(
              color: _pressed
                  ? (dark ? Colors.white : Colors.black)
                      .withValues(alpha: WaveState.pressedAlpha)
                  : _hover
                      ? (dark ? Colors.white : Colors.black)
                          .withValues(alpha: WaveState.hoverAlpha)
                      : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(WaveRadius.controls),
            ),
            child: Builder(
              builder: (context) {
                final fg = widget.onTap == null
                    ? (dark
                            ? WaveColors.textTertiary
                            : WaveColors.lightTextTertiary)
                        .withValues(alpha: 0.4)
                    : (dark
                        ? WaveColors.textSecondary
                        : WaveColors.lightTextSecondary);
                if (widget.iconWidget != null) {
                  return IconTheme(
                    data: IconThemeData(color: fg, size: 15),
                    child: Center(child: widget.iconWidget!),
                  );
                }
                return Icon(
                  widget.icon,
                  size: 15,
                  color: fg,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AppMenu extends StatelessWidget {
  const _AppMenu();
  @override
  Widget build(BuildContext context) {
    return DropDownButton(
      placement: FlyoutPlacementMode.bottomRight,
      transitionBuilder: fastFlyoutTransition,
      items: [
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.search, size: 15),
          text: const Text('Search  (Ctrl+K)'),
          onPressed: () => context.go('/search'),
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.lyrics, size: 15),
          text: const Text('Lyrics  (Ctrl+L)'),
          onPressed: () => context.go('/lyrics'),
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.history, size: 15),
          text: const Text('History'),
          onPressed: () => context.go('/history'),
        ),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.mixes, size: 15),
          text: const Text('Mix Lab'),
          onPressed: () => context.go('/mixes'),
        ),
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: const Icon(WaveIcons.settings, size: 15),
          text: const Text('Settings'),
          onPressed: () => context.go('/settings'),
        ),
      ],
      buttonBuilder: (context, onOpen) => _BarBtn(
        tooltip: 'Menu',
        icon: WaveIcons.more,
        onTap: onOpen,
      ),
    );
  }
}


class _WindowButtons extends StatelessWidget {
  const _WindowButtons();
  @override
  Widget build(BuildContext context) {
    Future<void> guard(Future<void> Function() fn) async {
      try {
        await fn();
      } catch (_) {}
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WinBtn(
          tooltip: 'Minimize',
          icon: FluentIcons.chrome_minimize,
          onTap: () => guard(() => windowManager.minimize()),
        ),
        _WinBtn(
          tooltip: 'Maximize',
          icon: FluentIcons.checkbox,
          onTap: () async {
            try {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            } catch (_) {}
          },
        ),
        _WinBtn(
          tooltip: 'Close',
          icon: FluentIcons.chrome_close,
          danger: true,
          onTap: () => guard(() => windowManager.close()),
        ),
      ],
    );
  }
}

class _WinBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  const _WinBtn({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            width: 44,
            height: WaveDensity.titleBar,
            color: _hover
                ? (widget.danger
                    ? WaveColors.danger
                    : (dark
                        ? Colors.white.withValues(
                            alpha: WaveState.hoverAlpha)
                        : Colors.black.withValues(
                            alpha: WaveState.hoverAlpha)))
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 12,
              color: _hover && widget.danger
                  ? Colors.white
                  : (dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
