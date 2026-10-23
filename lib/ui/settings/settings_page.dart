import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/window.dart';
import '../../app/auth_gate.dart';
import '../../app/open_with_claims.dart';
import '../../core/constants/app_links.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../features/addons/addon_api.dart';
import '../../features/home/home_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/library/local_library_providers.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/audio_output/output_path_sheet.dart';
import '../../features/lyrics/lyrics_providers.dart';
import '../../features/player/playback_service.dart';
import '../theme/tokens.dart';
import '../components/ambient.dart' show ambientGlowEnabledProvider;
import '../components/glass_panel.dart';
import '../components/buttons.dart';
import '../../features/presence/discord_presence_service.dart';
import '../../features/updater/update_models.dart';
import '../../features/updater/update_service.dart';
import '../components/update_dialog.dart';

/// Installed app metadata, used by About to show the real runtime version.
final packageInfoProvider =
    FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

const _waveSettingsSections = [
  ('library', 'Library', FluentIcons.music_note),
  ('audio', 'Audio', FluentIcons.speakers),
  ('playback', 'Playback', FluentIcons.play),
  ('appearance', 'Appearance', FluentIcons.brush),
  ('lyrics', 'Lyrics', FluentIcons.microphone),
  ('lastfm', 'Last.fm', FluentIcons.radio_bullet),
  ('general', 'General', FluentIcons.settings),
  ('experimental', 'Experimental', FluentIcons.bug),
  ('about', 'About', FluentIcons.info),
];

/// Canonical section id. Legacy deep links ('services', 'integrations')
/// land on the Last.fm pane.
String _canonSection(String s) =>
    (s == 'services' || s == 'integrations') ? 'lastfm' : s;

/// Fluent settings: left nav list + right form.
///
/// Reuses theme_controller + prefs logic; presentation is Fluent
/// (ToggleSwitch, Slider, ComboBox, ContentDialog) — no old ledger
/// switches or boxed groups.
class WaveSettingsPage extends ConsumerStatefulWidget {
  /// Deep-link into a section rail entry (e.g. 'lastfm' from the
  /// profile empty state). Falls back to 'library' when unknown.
  final String? initialSection;
  const WaveSettingsPage({super.key, this.initialSection});

  @override
  ConsumerState<WaveSettingsPage> createState() => _WaveSettingsPageState();
}

class _WaveSettingsPageState extends ConsumerState<WaveSettingsPage> {
  late String _section;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSection;
    final canon = initial == null ? null : _canonSection(initial);
    _section =
        canon != null && _waveSettingsSections.any((s) => s.$1 == canon)
            ? canon
            : 'library';
  }

  Future<void> _update(Future<void> Function(Prefs) fn) async {
    await fn(ref.read(prefsProvider));
    ref.read(themeControllerProvider.notifier).refresh();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Content-aware (rail-aware): LayoutBuilder sees real content
        // width, unlike MediaQuery window width (+200 rail error).
        final narrow = constraints.maxWidth < 900;
        if (narrow) {
          return ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                'SYSTEM',
                style: WaveType.overline.copyWith(color: waveAccent(context)),
              ),
              const Text('Settings', style: WaveType.pageTitle),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _waveSettingsSections)
                    ToggleButton(
                      checked: _section == s.$1,
                      onChanged: (_) => setState(() => _section = s.$1),
                      child: Text(s.$2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _SectionSwap(
                child: RepaintBoundary(
                  key: ValueKey(_section),
                  child: _SectionBody(section: _section, onUpdate: _update),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'SYSTEM',
                      style: WaveType.overline.copyWith(
                        color: waveAccent(context),
                      ),
                    ),
                    const Text('Settings', style: WaveType.pageTitle),
                    const SizedBox(height: 12),
                    for (final s in _waveSettingsSections)
                      ListTile.selectable(
                        selected: _section == s.$1,
                        selectionMode: ListTileSelectionMode.single,
                        leading: Icon(s.$3, size: 15),
                        title: Text(s.$2),
                        onPressed: () => setState(() => _section = s.$1),
                      ),
                  ],
                ),
              ),
            ),
            Container(width: 1, color: waveDivider(context)),
            Expanded(
              child: ListView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _SectionSwap(
                      child: RepaintBoundary(
                        key: ValueKey(_section),
                        child: _SectionBody(
                          section: _section,
                          onUpdate: _update,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionBody extends ConsumerWidget {
  final String section;
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _SectionBody({required this.section, required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (section) {
      case 'general':
        return _General(onUpdate: onUpdate);
      case 'playback':
        return _Playback(onUpdate: onUpdate);
      case 'library':
        return _LibrarySettings();
      case 'audio':
        return _Audio(onUpdate: onUpdate);
      case 'downloads':
        return _Downloads(onUpdate: onUpdate);
      case 'appearance':
        return _Appearance(onUpdate: onUpdate);
      case 'lyrics':
        return _Lyrics(onUpdate: onUpdate);
      case 'services':
      case 'lastfm':
      case 'integrations':
        return _LastFm(onUpdate: onUpdate);
      case 'sources':
        return _Sources(onUpdate: onUpdate);
      case 'experimental':
        return _Experimental(onUpdate: onUpdate);
      default:
        return const _About();
    }
  }
}

/// Section swap: fade only, size from the incoming pane, outgoing overlaid
/// at the top so it cannot re-center or relayout the list mid-transition.
class _SectionSwap extends StatelessWidget {
  final Widget child;
  const _SectionSwap({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: WaveMotion.normal,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: WaveMotion.fast,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topLeft,
            children: [
              for (final previous in previousChildren)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    child: ExcludeSemantics(child: previous),
                  ),
                ),
              ?currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: child,
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _Group({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          tint: waveAmoled(context)
              ? Colors.black
              : theme.resources.cardBackgroundFillColorDefault,
          border: Border.all(color: stroke),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.sectionTitle),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: GlassPanel(
            padding: const EdgeInsets.all(16),
            tint: waveAmoled(context)
                ? Colors.black
                : theme.resources.cardBackgroundFillColorSecondary,
            border: Border(
              left: BorderSide(color: stroke),
              right: BorderSide(color: stroke),
              bottom: BorderSide(color: stroke),
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(6),
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _Account extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Account({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    final prefs = ref.watch(prefsProvider);
    final signedIn = auth.username.isNotEmpty;
    final guest = auth.status == AuthStatus.guest || prefs.isGuest;
    return _Group(
      title: 'Last.fm connection',
      subtitle: 'Scrobbling and discovery need a session',
      child: Column(
        children: [
          Row(
            children: [
              const Icon(FluentIcons.contact, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      signedIn
                          ? auth.username
                          : (guest ? 'Guest mode' : 'Not connected'),
                      style: WaveType.trackTitle,
                    ),
                    Text(
                      signedIn
                          ? 'Last.fm connected'
                          : (guest
                              ? 'Last.fm disabled — save keys below, then connect'
                              : 'Connect to scrobble and personalize'),
                      style: WaveType.meta,
                    ),
                  ],
                ),
              ),
              signedIn
                  ? WaveButton(
                      onPressed: () => signOutEverywhere(ref),
                      child: const Text('Sign out'),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
          if (!signedIn) ...[
            const SizedBox(height: 10),
            const _InShellConnect(),
          ],
        ],
      ),
    );
  }
}

/// Web-auth connect that runs inside Settings (no /welcome round-trip),
/// so guests can attach Last.fm after saving keys. Mirrors the welcome
/// approval flow: open the browser, approve, finish here.
class _InShellConnect extends ConsumerStatefulWidget {
  const _InShellConnect();
  @override
  ConsumerState<_InShellConnect> createState() => _InShellConnectState();
}

class _InShellConnectState extends ConsumerState<_InShellConnect> {
  WebAuthHandshake? _handshake;
  bool _busy = false;
  String? _error;

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final handshake = await ref
          .read(authRepositoryProvider.notifier)
          .beginWebAuth();
      if (!mounted) return;
      setState(() => _handshake = handshake);
      final uri = Uri.parse(handshake.url);
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Could not reach Last.fm. Check your connection and retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final handshake = _handshake;
    if (handshake == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider.notifier)
          .completeWebAuth(handshake.token);
      ref.invalidate(feedProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Not approved yet — approve Aubade in the browser, then retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(prefsProvider).isLastFmConfigured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: WaveType.meta.copyWith(color: Colors.red),
          ),
          const SizedBox(height: 8),
        ],
        WaveFilledButton(
          onPressed: _busy || !configured ? null : _begin,
          child: _busy && _handshake == null
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Contacting Last.fm…'),
                  ],
                )
              : Text(_handshake == null
                  ? 'Connect with Last.fm'
                  : 'Restart approval'),
        ),
        if (!configured) ...[
          const SizedBox(height: 6),
          Text(
            'Save your API keys below first.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        ],
        if (_handshake != null) ...[
          const SizedBox(height: 8),
          WaveButton(
            onPressed: _busy ? null : _finish,
            child: _busy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Confirming…'),
                    ],
                  )
                : const Text("I've approved — finish sign-in"),
          ),
        ],
      ],
    );
  }
}

/// Re-applies ReplayGain + resampling prefs to the live mpv engine
/// after a Settings change. No-op before the first playback — the same
/// chain runs at ensurePlayer.
Future<void> _applyAudioQualityPrefs(WidgetRef ref) async {
  try {
    await ref.read(playbackServiceProvider.notifier).applyAudioQualityPrefs();
  } catch (_) {}
}

/// One-decimal dB label: '+3.5 dB' / '-12.0 dB'.
String _dbLabel(double v) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB';

class _Audio extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Audio({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final preamp = prefs.replayGainPreamp.clamp(-12.0, 12.0);
    return Column(
      children: [
        const SizedBox(height: 8),
        _Group(
          title: 'Audio output',
          subtitle: Platform.isWindows
              ? 'WASAPI Exclusive bypasses the Windows mixer'
              : 'System audio output',
          child: _WasapiOutputSettings(onUpdate: onUpdate),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Loudness & Dynamics',
          subtitle:
              'ReplayGain and volume normalization for the local library',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ReplayGain mode', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              ComboBox<String>(
                value: prefs.replayGainMode,
                items: const [
                  ComboBoxItem(value: 'off', child: Text('Disabled')),
                  ComboBoxItem(value: 'track', child: Text('Track Gain')),
                  ComboBoxItem(value: 'album', child: Text('Album Gain')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await onUpdate((p) => p.setReplayGainMode(v));
                  await _applyAudioQualityPrefs(ref);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text('Pre-amp', style: WaveType.trackTitle),
                  ),
                  Text(
                    _dbLabel(preamp),
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Slider(
                value: preamp,
                min: -12,
                max: 12,
                divisions: 48, // 0.5 dB per step
                label: _dbLabel(preamp),
                onChanged: (v) async {
                  await onUpdate((p) => p.setReplayGainPreamp(v));
                  await _applyAudioQualityPrefs(ref);
                },
              ),
              const SizedBox(height: 6),
              _SwitchRow(
                value: prefs.replayGainPreventClipping,
                onChanged: (v) async {
                  await onUpdate((p) => p.setReplayGainPreventClipping(v));
                  await _applyAudioQualityPrefs(ref);
                },
                title: 'Prevent clipping (true-peak limiter)',
                subtitle: 'Caps peaks after gain instead of hard clipping',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Resampling & DAC',
          subtitle: 'Output sample-rate handling',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Resampling mode', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              ComboBox<String>(
                value: prefs.audioResampleMode,
                items: const [
                  ComboBoxItem(
                    value: 'native',
                    child: Text('Bit-Perfect Native (No Resampling)'),
                  ),
                  ComboBoxItem(
                    value: 'sox96',
                    child: Text('SoX High Quality (96 kHz)'),
                  ),
                  ComboBoxItem(
                    value: 'sox192',
                    child: Text('SoX High Quality (192 kHz)'),
                  ),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await onUpdate((p) => p.setAudioResampleMode(v));
                  await _applyAudioQualityPrefs(ref);
                },
              ),
              const SizedBox(height: 6),
              Text(
                'Native plays files untouched at their source rate. '
                'SoX modes resample through the OS audio graph '
                '(engine maps to audio-samplerate).',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Appearance extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Appearance({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return Column(
      children: [
        _Group(
          title: 'Theme',
          subtitle: 'Midnight charcoal or pearl light',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ToggleButton(
                      checked: !theme.isLight,
                      onChanged: (_) async {
                        await ref
                            .read(themeControllerProvider.notifier)
                            .setThemeMode(false);
                        await applyWindowMaterial(isLight: false);
                      },
                      child: const Text('Midnight'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ToggleButton(
                      checked: theme.isLight,
                      onChanged: (_) async {
                        await ref
                            .read(themeControllerProvider.notifier)
                            .setThemeMode(true);
                        await applyWindowMaterial(
                            isLight: !theme.amoled);
                      },
                      child: const Text('Pearl'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('Accent source', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              ComboBox<String>(
                value: theme.accentSource,
                items: const [
                  ComboBoxItem(value: 'custom', child: Text('Custom colour')),
                  ComboBoxItem(
                    value: 'aubade',
                    child: Text('Aubade neutral'),
                  ),
                  ComboBoxItem(value: 'system', child: Text('System accent')),
                  ComboBoxItem(value: 'artwork', child: Text('Artwork tint')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    onUpdate((p) async {
                      await p.setAccentSource(v);
                      // Keep the artwork toggle and the source dropdown
                      // describing the same truth: choosing "Artwork tint"
                      // is the dynamic-artwork mode.
                      await p.setDynamicNowPlaying(v == 'artwork');
                    });
                  }
                },
              ),
              const SizedBox(height: 10),
              const Text('Accent colour', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in [
                    const Color(0xFFF5F4F0),
                    const Color(0xFF4CC2FF),
                    const Color(0xFFE03030),
                    const Color(0xFF7C4DFF),
                    const Color(0xFF2196C6),
                    const Color(0xFF6B9E6B),
                    const Color(0xFFE0A030),
                    const Color(0xFFE0507A),
                  ])
                    GestureDetector(
                      onTap: () =>
                          onUpdate((p) => p.setAccentColor(c.toARGB32())),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: Border.all(
                            color: theme.accent.toARGB32() == c.toARGB32()
                                ? waveAccent(context)
                                : waveDivider(context),
                            width: 2,
                          ),
                        ),
                        child: theme.accent.toARGB32() == c.toARGB32()
                            ? Icon(
                                FluentIcons.check_mark,
                                size: 14,
                                color: c.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Haze material',
          subtitle:
              'Automatic uses Haze L1–L3 as designed · Solid disables blur',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ComboBox<String>(
                value: theme.hazeMaterial,
                items: const [
                  ComboBoxItem(value: 'automatic', child: Text('Automatic')),
                  ComboBoxItem(value: 'haze', child: Text('Haze')),
                  ComboBoxItem(value: 'solid', child: Text('Solid')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    onUpdate((p) => p.setHazeMaterial(v));
                  }
                },
              ),
              const SizedBox(height: 10),
              const Text('Haze intensity', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final opt in ['low', 'medium', 'high'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ToggleButton(
                        checked: theme.hazeIntensity == opt,
                        onChanged: (_) =>
                            onUpdate((p) => p.setHazeIntensity(opt)),
                        child: Text(
                          '${opt[0].toUpperCase()}${opt.substring(1)}',
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Surfaces',
          subtitle: 'Contrast and artwork tinting',
          child: Column(
            children: [
              _SwitchRow(
                value: theme.amoled,
                onChanged: (v) => onUpdate((p) => p.setAmoled(v)),
                title: 'AMOLED black',
                subtitle: 'True black surfaces in Pearl and Midnight',
              ),
              _SwitchRow(
                value: theme.dynamicArtwork,
                onChanged: (v) => onUpdate((p) async {
                  await p.setDynamicNowPlaying(v);
                  // Mirror the source so ON means artwork and OFF returns
                  // to the user's swatch instead of leaving a hidden
                  // artwork source in force.
                  if (v) {
                    await p.setAccentSource('artwork');
                  } else if (p.accentSource == 'artwork') {
                    await p.setAccentSource('custom');
                  }
                }),
                title: 'Dynamic artwork theme',
                subtitle: 'Derive the app accent from the current cover',
              ),
              // Pillar 2 shell glow. Notifier-backed on purpose: the same
              // provider the shell watches is the single live source (it
              // also persists the pref), so flipping this repaints the
              // canvas immediately — no invalidation round-trip needed.
              _SwitchRow(
                value: ref.watch(ambientGlowEnabledProvider),
                onChanged: (v) =>
                    ref.read(ambientGlowEnabledProvider.notifier).setEnabled(v),
                title: 'Ambient Artwork Glow',
                subtitle:
                    'Artwork-driven glow behind the library. Turn off for a flat, focused finish.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Lyrics extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Lyrics({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Timing',
      subtitle: 'Synced lyrics providers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            value: prefs.wordByWord,
            onChanged: (v) => onUpdate((p) => p.setWordByWord(v)),
            title: 'Word-by-word lyrics',
            subtitle: 'Karaoke word highlight. Off uses Apple Music line lyrics.',
          ),
          const SizedBox(height: 10),
          const Text('Primary provider', style: WaveType.trackTitle),
          const SizedBox(height: 6),
          ComboBox<String>(
            value: LyricsProviderId.fromId(prefs.lyricsProviderId).id,
            items: [
              for (final provider in LyricsProviderId.values)
                ComboBoxItem(
                  value: provider.id,
                  child: Text(provider.title),
                ),
            ],
            onChanged: (v) {
              if (v != null) {
                onUpdate((p) => p.setLyricsProviderId(v));
              }
            },
          ),
          const SizedBox(height: 4),
          Text(
            LyricsProviderId.fromId(prefs.lyricsProviderId).subtitle,
            style: WaveType.meta,
          ),
        ],
      ),
    );
  }
}

class _Scrobbler extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Scrobbler({required this.onUpdate});

  @override
  ConsumerState<_Scrobbler> createState() => _ScrobblerState();
}

class _ScrobblerState extends ConsumerState<_Scrobbler> {
  double? _dragPercent;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final percent = (_dragPercent ?? prefs.scrobblePercent.toDouble())
        .clamp(25, 90)
        .toDouble();
    return _Group(
      title: 'Last.fm scrobbling',
      subtitle: 'Thresholds mirror Last.fm rules',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.scrobblerEnabled,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(enabled: v)),
            title: 'Enable scrobbling',
            subtitle: 'Requires a write-capable session',
          ),
          _SwitchRow(
            value: prefs.scrobbleNowPlaying,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(nowPlaying: v)),
            title: 'Now playing updates',
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Scrobble at ${percent.round()}% of track',
                    style: WaveType.trackTitle,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: Slider(
                    value: percent,
                    min: 25,
                    max: 90,
                    onChanged: (v) => setState(() => _dragPercent = v),
                    onChangeEnd: (v) {
                      setState(() => _dragPercent = null);
                      widget.onUpdate(
                        (p) => p.setScrobbler(percent: v.round()),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Addon sources: personal addon URLs replace the built-in lossless
/// backend as the lossless tier (see [AddonApi]). Quota meters fill
/// in after playback; unknown until the first stream attempt.
class _Sources extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Sources({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = ref.watch(prefsProvider).addonUrls;
    final src = ref.watch(losslessApiProvider);
    final quotas = src is AddonApi
        ? src.quotaByBase
        : const <String, AddonQuota>{};
    return _Group(
      title: 'Addon sources',
      subtitle: urls.isEmpty
          ? 'No addon configured — using the built-in lossless backend'
          : 'Addons serve the lossless tier instead of the built-in backend',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (AppEnv.addonClientSecret.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'This build has no addon app key — addon calls will fail. '
                'Rebuild with ADDON_CLIENT_SECRET set.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          for (final u in urls)
            _AddonRow(
              url: u,
              quota: quotas[u],
              onRemove: () async {
                await onUpdate(
                  (p) => p.setAddonUrls(urls.where((e) => e != u).toList()),
                );
                ref.invalidate(losslessApiProvider);
              },
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: WaveFilledButton(
              onPressed: () => _addAddonDialog(context, ref, urls, onUpdate),
              child: const Text('Add addon'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Paste the full addon URL from your dashboard. Anyone holding '
            'it plays on your quota — keep the dashboard backup safe.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _addAddonDialog(
    BuildContext context,
    WidgetRef ref,
    List<String> urls,
    Future<void> Function(Future<void> Function(Prefs)) onUpdate,
  ) async {
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Add addon'),
        content: TextBox(
          controller: controller,
          placeholder: 'https://…/a/<token>/',
          maxLines: 2,
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          WaveFilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final raw = pasted ?? '';
    controller.dispose();
    if (raw.isEmpty || !context.mounted) return;
    final parsed = AddonApi.parseAddonUrl(raw);
    if (parsed == null) {
      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (dialogContext) => ContentDialog(
            title: const Text('Not an addon URL'),
            content: const Text(
              'Expected something like https://host/a/<token>/.',
            ),
            actions: [
              WaveFilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }
    AddonManifest? manifest;
    try {
      manifest = await AddonApi([parsed.root]).manifestFor(parsed.root);
    } catch (_) {
      manifest = null;
    }
    if (!context.mounted) return;
    if (manifest == null) {
      await showDialog(
        context: context,
        builder: (dialogContext) => ContentDialog(
          title: const Text('Addon unreachable'),
          content: const Text(
            'No usable addon answered there — revoked, offline, '
            'or wrong URL. Nothing was saved.',
          ),
          actions: [
            WaveFilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final root = parsed.root;
    final next = [...urls.where((e) => e != root), root];
    await onUpdate((p) => p.setAddonUrls(next));
    ref.invalidate(losslessApiProvider);
    ref.invalidate(addonManifestProvider);
  }
}

class _AddonRow extends ConsumerWidget {
  final String url;
  final AddonQuota? quota;
  final Future<void> Function() onRemove;
  const _AddonRow({
    required this.url,
    required this.quota,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(addonManifestProvider(url)).valueOrNull;
    final host = Uri.tryParse(url)?.host ?? url;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(FluentIcons.cloud, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  manifest?.name ?? host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle,
                ),
                Text(
                  manifest == null ? '$host · unreachable' : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          WaveButton(onPressed: () => onRemove(), child: const Text('Remove')),
        ],
      ),
    );
  }
}

/// `PRETTY_NAME` from /etc/os-release — the live distro string.
/// Falls back to 'Linux' when the file is missing or unreadable.
String _osPrettyName() {
  try {
    for (final line in File('/etc/os-release').readAsLinesSync()) {
      if (!line.startsWith('PRETTY_NAME=')) continue;
      final value = line
          .substring('PRETTY_NAME='.length)
          .replaceAll('"', '')
          .trim();
      if (value.isNotEmpty) return value;
    }
  } catch (_) {}
  return 'Linux';
}

/// `uname -r` with the machine arch (`uname -m`) when available.
/// '—' when the kernel cannot be queried.
String _kernelVersion() {
  try {
    final kernel = Process.runSync('uname', ['-r']).stdout.toString().trim();
    if (kernel.isEmpty) return '—';
    try {
      final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
      return arch.isEmpty ? kernel : '$kernel ($arch)';
    } catch (_) {
      return kernel;
    }
  } catch (_) {
    return '—';
  }
}

class _About extends ConsumerWidget {
  const _About();

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(packageInfoProvider).asData?.value.version;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: WaveSpacing.x4),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                child: Image.asset(
                  'assets/icons/app_icon.png',
                  width: 72,
                  height: 72,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(height: WaveSpacing.x4),
              const Text('Aubade Desktop', style: WaveType.pageTitle),
              const SizedBox(height: WaveSpacing.x2),
              Text(
                'from an audiophile to an audiophile. a local first music player',
                textAlign: TextAlign.center,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              const SizedBox(height: WaveSpacing.x8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: WaveSpacing.x4,
                runSpacing: WaveSpacing.x4,
                children: [
                  WaveButton(
                    onPressed: () => _open(kLandingUrl),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.open_in_new_window, size: 14),
                        SizedBox(width: 6),
                        Text('Website'),
                      ],
                    ),
                  ),
                  WaveButton(
                    onPressed: () => _open(kLandingUrl),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.error, size: 14),
                        SizedBox(width: 6),
                        Text('Report an issue'),
                      ],
                    ),
                  ),
                  WaveButton(
                    onPressed: () => _open(kLandingUrl),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.page, size: 14),
                        SizedBox(width: 6),
                        Text('View License'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: WaveSpacing.x8),
              Text(
                version == null || version.isEmpty
                    ? 'Aubade Desktop'
                    : 'Aubade Desktop · v$version',
                style: WaveType.meta.copyWith(
                  color: waveTextTertiary(context),
                ),
              ),
              const SizedBox(height: WaveSpacing.x4),
              const _UpdateCheckSection(),
            ],
          ),
        ),
        if (Platform.isLinux) ...[
          const SizedBox(height: 8),
          _Group(
            title: 'System & Audio Telemetry',
            subtitle: 'Read live from this machine',
            child: Column(
              children: [
                _TelemetryRow(label: 'OS', value: _osPrettyName()),
                const SizedBox(height: 6),
                _TelemetryRow(label: 'Kernel', value: _kernelVersion()),
                const SizedBox(height: 6),
                const _TelemetryRow(
                  label: 'Audio Engine',
                  value: 'libmpv (Hardware PCM / PipeWire)',
                ),
                const SizedBox(height: 6),
                const _TelemetryRow(
                  label: 'Framework',
                  value: 'Flutter & Dart',
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _UpdateCheckSection extends ConsumerWidget {
  const _UpdateCheckSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateServiceProvider);
    final updater = ref.read(updateServiceProvider.notifier);

    if (state.status == UpdateStatus.checking) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: ProgressRing(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Checking for updates...', style: WaveType.meta),
        ],
      );
    }

    if (state.status == UpdateStatus.available ||
        state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.readyToInstall) {
      return WaveFilledButton(
        onPressed: () => showUpdateDialog(context, ref),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(FluentIcons.sync_occurence, size: 14),
            const SizedBox(width: 6),
            Text(
              state.status == UpdateStatus.readyToInstall
                  ? 'Update Ready: v${state.release?.version ?? ''} · Install'
                  : 'Update Available: v${state.release?.version ?? ''} · Install',
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WaveButton(
          onPressed: () => updater.checkForUpdates(force: true),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.sync, size: 14),
              SizedBox(width: 6),
              Text('Check for updates'),
            ],
          ),
        ),
        if (state.status == UpdateStatus.upToDate) ...[
          const SizedBox(width: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.check_mark, size: 14, color: WaveColors.success),
              const SizedBox(width: 4),
              Text('Up to date', style: WaveType.meta.copyWith(color: WaveColors.success)),
            ],
          ),
        ],
      ],
    );
  }
}

/// Label:value row used by the About telemetry card.
class _TelemetryRow extends StatelessWidget {
  final String label;
  final String value;
  const _TelemetryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: WaveType.label.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: WaveType.meta),
        ),
      ],
    );
  }
}

class _General extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _General({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          title: 'Behaviour',
          subtitle: 'Startup and window defaults',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.closeToTray,
                onChanged: (v) => onUpdate((p) => p.setCloseToTray(v)),
                title: 'Close button minimize to tray.',
                subtitle:
                    'Keep the player running in the background when closed.',
              ),
              const SizedBox(height: 8),
              _SwitchRow(
                value: prefs.discordRichPresence,
                onChanged: (v) async {
                  await onUpdate((p) => p.setDiscordRichPresence(v));
                  try {
                    ref.read(discordPresenceProvider).refresh();
                  } catch (_) {}
                },
                title: 'Discord Rich Presence',
                subtitle:
                    'Show the current track in your Discord status.',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Member list shows',
                          style: WaveType.trackTitle,
                        ),
                        Text(
                          'Which line Discord shows under your name.',
                          style: WaveType.meta.copyWith(
                            color: waveTextSecondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  ComboBox<String>(
                    value: prefs.discordMemberListDisplay,
                    items: const [
                      ComboBoxItem(value: 'title', child: Text('Title')),
                      ComboBoxItem(value: 'album', child: Text('Album')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await onUpdate(
                          (p) => p.setDiscordMemberListDisplay(v));
                      try {
                        ref.read(discordPresenceProvider).refresh();
                      } catch (_) {}
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _OpenWith(onUpdate: onUpdate),
      ],
    );
  }
}

/// Reversible "Open with" claims. Hidden on macOS, where the bundle
/// owns the association and there is nothing to toggle.
class _OpenWith extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _OpenWith({required this.onUpdate});

  @override
  ConsumerState<_OpenWith> createState() => _OpenWithState();
}

class _OpenWithState extends ConsumerState<_OpenWith> {
  bool? _claimed;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final claimed = await appOpenWithClaims().probeClaimed();
    if (!mounted) return;
    setState(() => _claimed = claimed);
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final claims = appOpenWithClaims();
      if (value) {
        await claims.claimAll();
      } else {
        await claims.unclaimAll();
      }
      await widget.onUpdate((p) => p.setOpenWithAudioFilesClaimed(value));
    } catch (_) {
      // Silent: re-probe below and show what actually changed.
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final claims = appOpenWithClaims();
    if (!claims.isSupported) return const SizedBox.shrink();
    final opensSystemPage = Platform.isWindows;
    return _Group(
      title: 'Open with',
      subtitle: 'Audio files in the system player menu',
      child: Column(
        children: [
          _SwitchRow(
            value: _claimed ?? false,
            onChanged: _toggle,
            title: 'Audio files in the Open with menu',
            subtitle: 'Reversible. Never changes your default player.',
          ),
          if (_claimed == true)
            _ActionRow(
              title: 'Set Aubade as the default player',
              subtitle: opensSystemPage
                  ? 'You choose Aubade under Default apps.'
                  : 'Applies to the audio types Aubade claims.',
              buttonLabel: opensSystemPage ? 'Open settings' : 'Set default',
              onPressed: _makeDefault,
            ),
        ],
      ),
    );
  }

  Future<void> _makeDefault() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await appOpenWithClaims().makeDefault();
    } catch (_) {
      // Best effort: the system settings remain the fallback.
    }
    if (mounted) setState(() => _busy = false);
  }
}

class _Playback extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Playback({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Playback',
      subtitle: 'Gapless, crossfade and output behaviour',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.autoplaySimilar,
            onChanged: (v) => onUpdate((p) => p.setAutoplaySimilar(v)),
            title: 'Autoplay similar',
            subtitle: 'Keep playing related tracks after a queue ends',
          ),
          const SizedBox(height: 8),
          _SwitchRow(
            value: prefs.crossfadeEnabled,
            onChanged: (v) async {
              await onUpdate((p) => p.setCrossfade(v));
              ref.read(audioOutputProvider.notifier).refreshPath();
            },
            title: 'Crossfade',
            subtitle: '${prefs.crossfadeSeconds}s · gapless otherwise',
          ),
        ],
      ),
    );
  }
}

/// Local library: watched music folders and library scan controls.
class _LibrarySettings extends ConsumerWidget {
  const _LibrarySettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(musicFoldersProvider);
    final scanning = ref.watch(isScanningProvider);
    final trackCount =
        ref.watch(localLibraryNotifierProvider).value?.length ?? 0;
    return Column(
      children: [
        _Group(
          title: 'Music folders',
          subtitle: 'Folders scanned for local tracks',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (folders.isEmpty)
                Text(
                  'No folders yet — add one to scan your music.',
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              for (final folder in folders)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      const Icon(
                          FluentIcons.open_folder_horizontal, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(FluentIcons.delete, size: 14),
                        onPressed: () => ref
                            .read(musicFoldersProvider.notifier)
                            .removeFolder(folder),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: WaveButton(
                  onPressed: () => _pickFolder(context, ref),
                  child: const Text('Add Folder'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Library indexing',
          subtitle: 'Scan watched folders into the local library',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$trackCount tracks indexed',
                style: WaveType.trackTitle,
              ),
              if (scanning) ...[
                const SizedBox(height: 8),
                Text(
                  'Scanning music library...',
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
                const SizedBox(height: 6),
                const ProgressBar(),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: WaveButton(
                  onPressed: scanning
                      ? null
                      : () => ref
                          .read(localLibraryNotifierProvider.notifier)
                          .scan(fullRescan: true),
                  child: Text(scanning ? 'Indexing...' : 'Rescan Library'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose music folder',
      );
      if (picked == null || picked.trim().isEmpty) return;
      await ref.read(musicFoldersProvider.notifier).addFolder(picked);
    } catch (_) {}
  }
}

class _Downloads extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Downloads({required this.onUpdate});

  Future<void> _pickDir(WidgetRef ref) async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder',
      );
      if (path == null || path.trim().isEmpty) return;
      await onUpdate((p) => p.setDownloadDir(path));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final custom = prefs.downloadDir;
    return _Group(
      title: 'Offline',
      subtitle: 'Download behaviour and lyrics sidecars',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.downloadLyrics,
            onChanged: (v) => onUpdate((p) => p.setDownloadLyrics(v)),
            title: 'Download lyrics',
            subtitle: 'Save synced .lrc sidecars with downloads',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                  FluentIcons.open_folder_horizontal, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Save location',
                        style: WaveType.trackTitle),
                    Text(
                      custom.isEmpty
                          ? 'Default location'
                          : custom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta,
                    ),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () => _pickDir(ref),
                child: const Text('Change'),
              ),
              if (custom.isNotEmpty) ...[
                const SizedBox(width: 8),
                WaveButton(
                  onPressed: () =>
                      onUpdate((p) => p.resetDownloadDir()),
                  child: const Text('Reset'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LastFm extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _LastFm({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Account(onUpdate: onUpdate),
        const SizedBox(height: 8),
        const _ApiKeys(),
        const SizedBox(height: 8),
        _Scrobbler(onUpdate: onUpdate),
      ],
    );
  }
}

/// Last.fm BYOK editor: the user's own API key + shared secret.
///
/// Validated with a signed `auth.getToken` call before persisting;
/// saving *different* keys signs the session out (sessions belong to
/// their API key). Key values are never logged — only presence.
class _ApiKeys extends ConsumerStatefulWidget {
  const _ApiKeys();
  @override
  ConsumerState<_ApiKeys> createState() => _ApiKeysState();
}

class _ApiKeysState extends ConsumerState<_ApiKeys> {
  TextEditingController? _key;
  TextEditingController? _secret;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key?.dispose();
    _secret?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).saveCustomKeys(
            _key?.text ?? '',
            _secret?.text ?? '',
          );
    } catch (e) {
      if (mounted) {
        setState(() => _error = _shortError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).clearCustomKeys();
      _key?.clear();
      _secret?.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _error = _shortError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _shortError(Object e) =>
      e.toString().replaceFirst('LastFmException(null): ', '');

  @override
  Widget build(BuildContext context) {
    // Subscribe to auth transitions so the status line below flips
    // right after save/clear: Prefs itself never notifies (see
    // welcome _AuthPanel — same pattern).
    ref.watch(authRepositoryProvider.select((s) => s.status));
    final prefs = ref.watch(prefsProvider);
    _key ??= TextEditingController(text: prefs.lastFmApiKey);
    _secret ??= TextEditingController(text: prefs.lastFmApiSecret);
    final configured = prefs.isLastFmConfigured;
    return _Group(
      title: 'API keys',
      subtitle: 'Your own keys from last.fm/api/account/create',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                configured
                    ? FluentIcons.check_mark
                    : FluentIcons.warning,
                size: 14,
                color: configured ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  configured
                      ? 'Keys saved — values never shown here'
                      : 'Not configured — Last.fm is disabled',
                  style: WaveType.meta,
                ),
              ),
              if (configured)
                WaveButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('API key', style: WaveType.label),
          const SizedBox(height: 4),
          TextBox(
            controller: _key,
            placeholder: '32-character hex key',
          ),
          const SizedBox(height: 8),
          const Text('Shared secret', style: WaveType.label),
          const SizedBox(height: 4),
          TextBox(
            controller: _secret,
            placeholder: 'Shared secret',
            obscureText: true,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: WaveType.meta.copyWith(color: Colors.red),
            ),
          ],
          const SizedBox(height: 10),
          WaveFilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Validating…'),
                    ],
                  )
                : const Text('Save & validate'),
          ),
          const SizedBox(height: 6),
          Text(
            'Saving different keys signs you out — sessions belong '
            'to their API key. Reconnect afterwards.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _Experimental extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Experimental({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return _Group(
      title: 'Experimental',
      subtitle: 'Opt-in desktop prototypes',
      child: Column(
        children: [
          _SwitchRow(
            value: theme.liquidGlass,
            onChanged: (v) => onUpdate((p) => p.setLiquidGlass(v)),
            title: 'Extra translucency',
            subtitle: 'Stronger Haze on panels (may cost FPS)',
          ),
          _SwitchRow(
            value: theme.wavySeekbar,
            onChanged: (v) => onUpdate((p) => p.setWavySeekbar(v)),
            title: 'Wavy seekbar',
            subtitle: 'Experimental timeline treatment',
          ),
        ],
      ),
    );
  }
}

class _WasapiOutputSettings extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _WasapiOutputSettings({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(audioOutputProvider);
    final notifier = ref.read(audioOutputProvider.notifier);
    final devices = output.devices;
    final selected = output.selectedId.isEmpty ? '' : output.selectedId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Device', style: WaveType.trackTitle),
        const SizedBox(height: 6),
        ComboBox<String>(
          isExpanded: true,
          value: devices.any((d) => d.id == selected) ? selected : '',
          items: [
            const ComboBoxItem(value: '', child: Text('System Default')),
            for (final d in devices)
              ComboBoxItem(
                value: d.id,
                child: Text(
                  d.isDefault ? '${d.displayName} (default)' : d.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) async {
            if (v == null) return;
            await notifier.selectDevice(v);
            await onUpdate((_) async {});
          },
        ),
        const SizedBox(height: 10),
        if (Platform.isWindows)
          _SwitchRow(
            value: output.exclusiveRequested,
            onChanged: (v) async {
              await notifier.setExclusive(v);
              await onUpdate((_) async {});
            },
            title: 'WASAPI Exclusive',
            subtitle: output.path.bitPerfect
                ? 'Mixer bypassed · bit-perfect when the DAC matches the source'
                : (output.exclusiveRequested
                      ? output.path.reason.label
                      : 'Shared mode — mixer may resample'),
          ),
        const SizedBox(height: 8),
        Text(
          output.selected == null
              ? 'Probe the DAC after connecting it to see exclusive PCM rates.'
              : output.selected!.supportedSummary,
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 12),
        WaveStreamPathPanel(path: output.path),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  const _SwitchRow({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ToggleSwitch(checked: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// One settings action: label on the right, behaves like a button row.
class _ActionRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonLabel;
  final Future<void> Function() onPressed;
  const _ActionRow({
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                Text(
                  subtitle,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          WaveButton(onPressed: onPressed, child: Text(buttonLabel)),
        ],
      ),
    );
  }
}
