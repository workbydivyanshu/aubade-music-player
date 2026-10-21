import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/updater/update_models.dart';
import '../../features/updater/update_service.dart';
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
          Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }

    final isDownloading = state.status == UpdateStatus.downloading;
    final isReady = state.status == UpdateStatus.readyToInstall;
    final isError = state.status == UpdateStatus.error;

    return ContentDialog(
      title: Row(
        children: [
          const Icon(FluentIcons.sync_occurence, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isReady
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
            if (release?.notes.isNotEmpty ?? false) ...[
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
                  child: Text(
                    release!.notes,
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
            ],
          ],
        ),
      ),
      actions: [
        if (!isDownloading) ...[
          Button(
            onPressed: () {
              updater.dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Later'),
          ),
          Button(
            onPressed: () => updater.openReleaseInBrowser(),
            child: const Text('View release'),
          ),
          if (isReady)
            FilledButton(
              onPressed: () => updater.applyUpdate(),
              child: const Text('Install & Relaunch'),
            )
          else
            FilledButton(
              onPressed: () => updater.downloadUpdate(),
              child: const Text('Download & Update'),
            ),
        ] else ...[
          Button(
            onPressed: () => updater.openReleaseInBrowser(),
            child: const Text('Download Manually'),
          ),
        ],
      ],
    );
  }
}
