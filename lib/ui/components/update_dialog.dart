import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/updater/release_notes.dart';
import '../../features/updater/update_models.dart';
import '../../features/updater/update_service.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';

/// Displays an Apple-caliber modal dialog showing update details,
/// real-time download progress, and an in-app install action.
Future<void> showUpdateDialog(BuildContext context, WidgetRef ref) async {
  return showDialog<void>(
    context: context,
    builder: (context) => const _UpdateDialog(),
  );
}

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateServiceProvider);
    final updater = ref.read(updateServiceProvider.notifier);
    final release = state.release;

    if (release == null && state.status != UpdateStatus.checking) {
      return ContentDialog(
        title: const Text('Updates'),
        content: const Text('No update information available.'),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    final isDownloading = state.status == UpdateStatus.downloading;
    final isReady = state.status == UpdateStatus.readyToInstall;
    final isInstalling = state.status == UpdateStatus.installing;
    final isRelaunchReady = state.status == UpdateStatus.readyToRelaunch;
    final isError = state.status == UpdateStatus.error;
    final noteSpans = formatReleaseNotes(release?.notes ?? '');

    return ContentDialog(
      title: Row(
        children: [
          const Icon(FluentIcons.sync_occurence, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isRelaunchReady
                  ? 'Update Installed: Aubade ${release?.version ?? ''}'
                  : isInstalling
                      ? 'Installing Aubade ${release?.version ?? ''}'
                      : isReady
                          ? 'Update Ready: Aubade ${release?.version ?? ''}'
                          : isDownloading
                              ? 'Downloading Aubade ${release?.version ?? ''}'
                              : 'Update Available: Aubade ${release?.version ?? ''}',
              style: WaveType.sectionTitle,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Target asset telemetry pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: waveSurface(context),
                borderRadius: BorderRadius.circular(WaveRadius.controls),
                border: Border.all(color: waveDivider(context)),
              ),
              child: Row(
                children: [
                  Icon(
                    FluentIcons.archive,
                    size: 16,
                    color: waveAccent(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      release?.assetName ?? 'Official Package',
                      style: WaveType.body.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (release?.formattedSize.isNotEmpty ?? false)
                    Text(
                      release!.formattedSize,
                      style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Release notes / Changelog
            if (noteSpans.isNotEmpty) ...[
              const Text('What\'s New:', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: waveSurface(context),
                  borderRadius: BorderRadius.circular(WaveRadius.controls),
                  border: Border.all(color: waveDivider(context)),
                ),
                child: SingleChildScrollView(
                  child: Text.rich(
                    TextSpan(children: noteSpans),
                    style: WaveType.body.copyWith(color: waveTextSecondary(context)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Progress or status feedback
            if (isDownloading) ...[
              ProgressBar(
                value: state.progress > 0
                    ? (state.progress * 100).clamp(0, 100)
                    : null,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(state.downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                    ' / ${(state.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                    style: WaveType.meta,
                  ),
                  Text(
                    '${(state.progress * 100).toInt()}%',
                    style: WaveType.meta.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ] else if (isInstalling) ...[
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Requesting permission…', style: WaveType.body),
                  ),
                ],
              ),
            ] else if (isRelaunchReady) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: WaveColors.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(WaveRadius.controls),
                ),
                child: Row(
                  children: [
                    const Icon(FluentIcons.check_mark, color: WaveColors.success, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Aubade ${release?.version ?? ''} is installed. Restart to finish.',
                        style: WaveType.body.copyWith(color: WaveColors.success),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (isReady) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: WaveColors.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(WaveRadius.controls),
                ),
                child: Row(
                  children: [
                    const Icon(FluentIcons.check_mark, color: WaveColors.success, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Installer downloaded successfully. Click below to install.',
                        style: WaveType.body.copyWith(color: WaveColors.success),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (isError) ...[
              Text(
                state.errorMessage ?? 'An error occurred during update.',
                style: WaveType.meta.copyWith(color: WaveColors.danger),
              ),
              if (state.downloadedFilePath != null) ...[
                const SizedBox(height: 6),
                Text(
                  'You can install the downloaded package manually.',
                  style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (isInstalling)
          const SizedBox.shrink()
        else if (isRelaunchReady) ...[
          WaveButton(
            onPressed: () {
              updater.dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Restart later'),
          ),
          WaveFilledButton(
            onPressed: () => updater.relaunch(),
            child: const Text('Restart now'),
          ),
        ] else if (!isDownloading) ...[
          WaveButton(
            onPressed: () {
              updater.dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Later'),
          ),
          if (isError && state.downloadedFilePath != null)
            WaveButton(
              onPressed: () => updater.openDownloadFolder(),
              child: const Text('Open folder'),
            ),
          WaveButton(
            onPressed: () => updater.openReleaseInBrowser(),
            child: const Text('View release'),
          ),
          if (isReady)
            WaveFilledButton(
              onPressed: () => updater.applyUpdate(),
              child: const Text('Install & Relaunch'),
            )
          else if (!isError || state.downloadedFilePath == null)
            WaveFilledButton(
              onPressed: () => updater.downloadUpdate(),
              child: const Text('Download & Update'),
            ),
        ] else ...[
          WaveButton(
            onPressed: () => updater.openReleaseInBrowser(),
            child: const Text('Download Manually'),
          ),
        ],
      ],
    );
  }
}
