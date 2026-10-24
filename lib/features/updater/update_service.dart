import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_links.dart';
import '../../core/network/dio_factory.dart';
import 'update_models.dart';

/// The active repository providing official Aubade releases.
const kUpdateRepoOwner = 'workbydivyanshu';
const kUpdateRepoName = 'aubade-music-player';
/// Only used when the runtime version can't be read; source of truth is
/// pubspec.yaml.
const kFallbackAppVersion = '1.0.6';

/// Minimum interval between automatic background update checks.
const kBackgroundCheckInterval = Duration(hours: 12);

/// Releases the automatic prompt already fired for during this session.
/// One prompt per release per session keeps the nudge quiet, while a
/// new release version re-arms it.
final Set<String> _autoPromptedReleases = <String>{};

/// True when the automatic prompt may fire for [releaseVersion].
bool shouldAutoPromptForRelease(String? releaseVersion) {
  if (releaseVersion == null || releaseVersion.isEmpty) return false;
  return !_autoPromptedReleases.contains(releaseVersion);
}

/// Records that the automatic prompt fired for [releaseVersion].
void markReleaseAutoPrompted(String releaseVersion) {
  _autoPromptedReleases.add(releaseVersion);
}

/// Clears the automatic-prompt history between tests.
@visibleForTesting
void resetAutoPromptHistory() => _autoPromptedReleases.clear();

/// A process invocation used to install a downloaded Linux package.
class InstallCommand {
  final String executable;
  final List<String> arguments;

  const InstallCommand(this.executable, this.arguments);
}

/// Builds the privileged install command for an RPM or DEB package.
///
/// Returns null for AppImages (installed without pkexec) and unknown types.
InstallCommand? linuxInstallCommand(String filePath) {
  final path = filePath.trim();
  if (path.isEmpty) return null;

  final lower = path.toLowerCase();
  if (lower.endsWith('.rpm')) {
    return InstallCommand('pkexec', ['rpm', '-Uvh', '--replacepkgs', path]);
  }
  if (lower.endsWith('.deb')) {
    return InstallCommand('pkexec', ['dpkg', '-i', path]);
  }
  return null;
}

/// A process invocation used to relaunch the freshly installed app.
class RelaunchCommand {
  final String executable;
  final List<String> arguments;

  const RelaunchCommand(this.executable, this.arguments);
}

/// Builds the restart command from `Platform.resolvedExecutable`.
///
/// [preferredExecutable] lets AppImage installs relaunch the downloaded file.
/// Falls back to [resolvedExecutable] when the preferred path is unusable and
/// returns null when neither looks like a real app binary (for example a test
/// runner), so callers can degrade to "Restart later" instead of spawning one.
RelaunchCommand? buildRelaunchCommand({
  required String resolvedExecutable,
  String? preferredExecutable,
}) {
  RelaunchCommand? commandFor(String? path) {
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty) return null;

    final name = trimmed.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (name.isEmpty ||
        name == 'flutter_tester' ||
        name == 'dart' ||
        name == 'dartaotruntime') {
      return null;
    }
    return RelaunchCommand(trimmed, const []);
  }

  return commandFor(preferredExecutable) ?? commandFor(resolvedExecutable);
}

/// Last useful line of a package-manager failure, or its exit code.
String? _processDetail(ProcessResult result) {
  final stderr = result.stderr.toString().trim();
  if (stderr.isNotEmpty) return stderr.split('\n').last.trim();

  final stdout = result.stdout.toString().trim();
  if (stdout.isNotEmpty) return stdout.split('\n').last.trim();

  return 'exit code ${result.exitCode}';
}

final updateServiceProvider =
    StateNotifierProvider<UpdateService, UpdateState>((ref) {
  return UpdateService();
});

class UpdateService extends StateNotifier<UpdateState> {
  final Dio _dio;

  UpdateService({Dio? dio})
      : _dio = dio ?? DioFactory.create(),
        super(const UpdateState());

  /// Compares two SemVer strings (e.g. "1.0.2" vs "1.0.1").
  /// Returns true if [remote] is strictly higher than [current].
  static bool isNewerVersion(String remote, String current) {
    List<int> parse(String v) {
      final clean = v.trim().replaceAll(RegExp(r'^v'), '').split('+').first;
      return clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    }

    final rParts = parse(remote);
    final cParts = parse(current);
    final len = math.max(rParts.length, cParts.length);

    for (var i = 0; i < len; i++) {
      final r = i < rParts.length ? rParts[i] : 0;
      final c = i < cParts.length ? cParts[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }

  /// Reads the installed app version at runtime.
  ///
  /// Falls back to [kFallbackAppVersion] when the platform plugin is
  /// unavailable (tests or unsupported hosts).
  Future<String> _readCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      if (version.isNotEmpty) return version;
    } catch (_) {}
    return kFallbackAppVersion;
  }

  /// Raw contents of `/etc/os-release`, or null when it cannot be read.
  Future<String?> _readOsRelease() async {
    try {
      return await File('/etc/os-release').readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Checks the release feed for the latest version.
  /// If [force] is false and we checked recently, skips the network call.
  Future<void> checkForUpdates({bool force = false}) async {
    final now = DateTime.now();
    if (!force && state.lastChecked != null) {
      if (now.difference(state.lastChecked!) < kBackgroundCheckInterval) {
        return;
      }
    }

    state = state.copyWith(status: UpdateStatus.checking, errorMessage: null);

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$kUpdateRepoOwner/$kUpdateRepoName/releases/latest',
        options: Options(
          headers: {'Accept': 'application/json'},
        ),
      );

      final data = response.data;
      if (data == null) {
        state = state.copyWith(
          status: UpdateStatus.upToDate,
          lastChecked: now,
        );
        return;
      }

      final release = AppReleaseInfo.fromJson(
        data,
        osRelease: Platform.isLinux ? await _readOsRelease() : null,
      );
      final currentVersion = await _readCurrentVersion();
      final hasUpdate = isNewerVersion(release.version, currentVersion);

      if (hasUpdate) {
        state = state.copyWith(
          status: UpdateStatus.available,
          release: release,
          lastChecked: now,
        );
      } else {
        state = state.copyWith(
          status: UpdateStatus.upToDate,
          release: release,
          lastChecked: now,
        );
      }
    } catch (e) {
      // Offline / network failure / 404 (if no releases published yet)
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Unable to check for updates: $e',
        lastChecked: now,
      );
    }
  }

  /// Downloads the matched platform asset for the available release.
  Future<void> downloadUpdate() async {
    final release = state.release;
    final downloadUrl = release?.assetDownloadUrl;

    if (release == null || downloadUrl == null || downloadUrl.isEmpty) {
      // Fallback: open release page in browser
      await openReleaseInBrowser();
      return;
    }

    state = state.copyWith(
      status: UpdateStatus.downloading,
      progress: 0.0,
      downloadedBytes: 0,
      totalBytes: release.assetSizeBytes ?? 0,
      errorMessage: null,
    );

    try {
      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }

      final fileName = release.assetName ?? 'aubade_update';
      final savePath = p.join(tempDir.path, fileName);

      // Remove any stale file
      final file = File(savePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      await _dio.download(
        downloadUrl,
        savePath,
        onReceiveProgress: (received, total) {
          final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          state = state.copyWith(
            progress: progress,
            downloadedBytes: received,
            totalBytes: total > 0 ? total : state.totalBytes,
          );
        },
      );

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        downloadedFilePath: savePath,
        progress: 1.0,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Download failed: $e',
      );
    }
  }

  /// Installs the downloaded update and reports the outcome in [state].
  ///
  /// Linux RPM/DEB installs go through pkexec so the user sees the system
  /// permission prompt; AppImages are made executable in place. Windows and
  /// macOS keep their existing installer launch behaviour.
  Future<void> applyUpdate() async {
    final filePath = state.downloadedFilePath;
    if (filePath == null || !File(filePath).existsSync()) {
      await openDownloadFolder();
      return;
    }

    if (Platform.isLinux) {
      state = state.copyWith(status: UpdateStatus.installing);
      await _applyLinuxUpdate(filePath);
      return;
    }

    try {
      if (Platform.isWindows) {
        if (filePath.endsWith('.exe')) {
          // Launch Inno Setup installer silently or with UI
          await Process.start(
            filePath,
            ['/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
            runInShell: true,
            mode: ProcessStartMode.detached,
          );
          exit(0);
        }
      } else if (Platform.isMacOS) {
        if (filePath.endsWith('.dmg')) {
          await Process.run('open', [filePath]);
        }
      }
    } catch (e) {
      // If launching fails, open download folder or browser
      await openReleaseInBrowser();
    }
  }

  Future<void> _applyLinuxUpdate(String filePath) async {
    if (filePath.toLowerCase().endsWith('.appimage')) {
      try {
        final result = await Process.run('chmod', ['+x', filePath]);
        state = result.exitCode == 0
            ? state.finishInstall(InstallOutcome.installed)
            : state.finishInstall(
                InstallOutcome.failed,
                detail: _processDetail(result),
              );
      } catch (e) {
        state = state.finishInstall(InstallOutcome.failed, detail: '$e');
      }
      return;
    }

    final command = linuxInstallCommand(filePath);
    if (command == null) {
      state = state.finishInstall(
        InstallOutcome.failed,
        detail: 'unsupported package type',
      );
      return;
    }

    try {
      final result = await Process.run(command.executable, command.arguments);
      state = state.finishInstall(
        installOutcomeForExitCode(result.exitCode),
        detail: _processDetail(result),
      );
    } on ProcessException catch (e) {
      state = state.finishInstall(
        InstallOutcome.failed,
        detail: e.message.isEmpty ? 'pkexec unavailable' : e.message,
      );
    } catch (e) {
      state = state.finishInstall(InstallOutcome.failed, detail: '$e');
    }
  }

  /// Relaunches the freshly installed binary, then exits this process.
  Future<void> relaunch() async {
    final filePath = state.downloadedFilePath;
    final isAppImage =
        filePath != null && filePath.toLowerCase().endsWith('.appimage');
    final command = buildRelaunchCommand(
      resolvedExecutable: Platform.resolvedExecutable,
      preferredExecutable: isAppImage ? filePath : null,
    );

    if (command == null) {
      state = state.copyWith(
        errorMessage: 'Restart Aubade manually to finish the update.',
      );
      return;
    }

    try {
      await Process.start(
        command.executable,
        command.arguments,
        mode: ProcessStartMode.detached,
      );
      exit(0);
    } catch (e) {
      state = state.copyWith(errorMessage: 'Could not restart Aubade: $e');
    }
  }

  /// Opens the folder containing the downloaded installer.
  Future<void> openDownloadFolder() async {
    final filePath = state.downloadedFilePath;
    if (filePath == null || filePath.isEmpty) {
      await openReleaseInBrowser();
      return;
    }

    final folder = p.dirname(filePath);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [folder]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [folder]);
      } else {
        await Process.run('xdg-open', [folder]);
      }
    } catch (_) {
      await openReleaseInBrowser();
    }
  }

  /// Opens the download page in the default web browser.
  Future<void> openReleaseInBrowser() async {
    final uri = Uri.parse(kLandingDownloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Clears the current update state back to idle.
  void dismiss() {
    state = state.copyWith(status: UpdateStatus.idle);
  }
}
