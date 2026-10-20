import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/network_monitor.dart';
import '../../core/storage/prefs.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/lastfm/auth_repository.dart';
import '../theme/tokens.dart';

/// Global Fluent InfoBar host — non-blocking feedback docked above content.
///
/// Shows (highest priority first):
/// - offline network
/// - Last.fm disconnected (only while scrobbling is enabled)
/// - latest download done/error
///
/// Dismissible per-bar, auto-collapses when clear. Rendered by [WaveShell]
/// directly under the title bar so it never blocks playback.
/// One-shot "running in the tray" hint, set on first hide-to-tray.
/// Session-scoped (resets on relaunch) — the pref itself lives in Prefs.
final trayHintProvider = StateProvider<bool>((_) => false);

class WaveInfoBarHost extends ConsumerStatefulWidget {
  const WaveInfoBarHost({super.key});
  @override
  ConsumerState<WaveInfoBarHost> createState() => _WaveInfoBarHostState();
}

class _WaveInfoBarHostState extends ConsumerState<WaveInfoBarHost> {
  bool _dismissedOffline = false;
  bool _dismissedAuth = false;
  String? _dismissedDownloadKey;

  @override
  Widget build(BuildContext context) {
    final online = ref.watch(networkMonitorProvider);
    final auth = ref.watch(authRepositoryProvider);
    final prefs = ref.watch(prefsProvider);
    final downloads = ref.watch(downloadManagerProvider);

    final bars = <Widget>[];
    if (ref.watch(trayHintProvider)) {
      bars.add(InfoBar(
        title: const Text('Playing in the tray'),
        content: const Text(
            'Closing hides Aubade — Quit from the tray menu to exit.'),
        severity: InfoBarSeverity.info,
        isLong: false,
        onClose: () =>
            ref.read(trayHintProvider.notifier).state = false,
      ));
    }
    if (!online && !_dismissedOffline) {
      bars.add(InfoBar(
        title: const Text('You are offline'),
        content: const Text(
            'Online lyrics (LRCLIB) and metadata lookup may be unavailable.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        onClose: () => setState(() => _dismissedOffline = true),
      ));
    }
    // Scrobbling opted in, but the Last.fm session dropped: point back
    // at Services. Guests chose keyless entry — never nag them.
    if (prefs.scrobblerEnabled &&
        auth.status != AuthStatus.signedIn &&
        auth.status != AuthStatus.guest &&
        !_dismissedAuth) {
      bars.add(InfoBar(
        title: const Text('Last.fm disconnected'),
        content: const Text('Connect to scrobble your local playback.'),
        severity: InfoBarSeverity.warning,
        isLong: false,
        action: HyperlinkButton(
          onPressed: () => context.go('/settings?section=lastfm'),
          child: const Text('Connect'),
        ),
        onClose: () => setState(() => _dismissedAuth = true),
      ));
    }
    DownloadEntry? latest;
    for (final d in downloads) {
      if (d.status == DownloadStatus.done ||
          d.status == DownloadStatus.error) {
        latest = d;
      }
    }
    // Restored-at-boot rows are history (see DownloadManager._muted) —
    // only entries that finished this session may announce.
    final announcer = ref.read(downloadManagerProvider.notifier);
    if (latest != null &&
        _dismissedDownloadKey != latest.key &&
        announcer.shouldAnnounce(latest.key)) {
      final entry = latest;
      bars.add(InfoBar(
        title: Text(entry.status == DownloadStatus.done
            ? 'Download complete'
            : 'Download failed'),
        content: Text('${entry.title} — ${entry.artist}'),
        severity: entry.status == DownloadStatus.done
            ? InfoBarSeverity.success
            : InfoBarSeverity.error,
        isLong: false,
        action: HyperlinkButton(
          onPressed: () => context.go('/downloads'),
          child: const Text('Open'),
        ),
        onClose: () {
          announcer.muteAnnouncement(entry.key);
          setState(() => _dismissedDownloadKey = entry.key);
        },
      ));
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: waveDivider(context)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: WaveDensity.contentMax),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < bars.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              bars[i],
            ],
          ],
        ),
      ),
    );
  }
}
