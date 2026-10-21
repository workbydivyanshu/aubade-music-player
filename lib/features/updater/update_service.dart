import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
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
const kFallbackAppVersion = '1.0.2';

/// Minimum interval between automatic background update checks.
const kBackgroundCheckInterval = Duration(hours: 12);

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

  /// Launches or executes the downloaded installer / package.
  Future<void> applyUpdate() async {
    final filePath = state.downloadedFilePath;
    if (filePath == null || !File(filePath).existsSync()) {
      await openReleaseInBrowser();
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
      } else if (Platform.isLinux) {
        if (filePath.endsWith('.rpm')) {
          // Try pkexec rpm -Uvh or launch file with default installer
          try {
            await Process.start(
              'pkexec',
              ['rpm', '-Uvh', filePath],
              mode: ProcessStartMode.detached,
            );
            return;
          } catch (_) {
            // Fall back to opening with xdg-open (GNOME Software)
            await Process.start('xdg-open', [filePath], mode: ProcessStartMode.detached);
          }
        } else if (filePath.endsWith('.AppImage')) {
          // Make executable and launch
          await Process.run('chmod', ['+x', filePath]);
          await Process.start(filePath, [], mode: ProcessStartMode.detached);
          exit(0);
        } else {
          await Process.start('xdg-open', [filePath], mode: ProcessStartMode.detached);
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
