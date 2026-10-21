import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// Linux package extensions in preference order for the distro described by
/// the raw contents of `/etc/os-release`.
///
/// Fedora-family distros get RPM first, Debian/Ubuntu-family get DEB first,
/// and unknown distros get AppImage only — it runs everywhere, so we never
/// steer an unknown distro towards a foreign package format up front.
List<String> preferAssetOrder(String? osRelease) {
  final ids = <String>{};
  for (final line in (osRelease ?? '').toLowerCase().split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('id=') && !trimmed.startsWith('id_like=')) {
      continue;
    }
    final value = trimmed
        .substring(trimmed.indexOf('=') + 1)
        .replaceAll('"', '')
        .replaceAll("'", '');
    ids.addAll(value.split(RegExp(r'\s+')));
  }

  bool mentions(Set<String> family) =>
      ids.any((id) => family.any(id.contains));

  if (mentions(const {'fedora', 'rhel', 'centos', 'suse', 'rocky', 'alma'})) {
    return const ['.rpm', '.appimage'];
  }
  if (mentions(const {'ubuntu', 'debian', 'mint', 'elementary', 'pop', 'bodhi'})) {
    return const ['.deb', '.appimage'];
  }
  return const ['.appimage'];
}

/// Status of the in-app update lifecycle.
enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  readyToInstall,
  installing,
  readyToRelaunch,
  error,
}

/// Result of asking the OS package manager to install a downloaded update.
enum InstallOutcome { installed, cancelled, failed }

/// Maps a package-manager exit code to a dialog-friendly outcome.
///
/// `pkexec` uses 126 when the authentication dialog is dismissed and 127 when
/// authorisation fails, so both are reported as a cancellation rather than a
/// package-manager error.
InstallOutcome installOutcomeForExitCode(int exitCode) {
  if (exitCode == 0) return InstallOutcome.installed;
  if (exitCode == 126 || exitCode == 127) return InstallOutcome.cancelled;
  return InstallOutcome.failed;
}

/// Failure text rendered in the update dialog.
String installFailureMessage(InstallOutcome outcome, {String? detail}) {
  final cleaned = detail?.trim() ?? '';
  final reason = outcome == InstallOutcome.cancelled
      ? 'cancelled'
      : cleaned.isNotEmpty
      ? cleaned
      : 'unknown error';
  return "Update couldn't be installed — $reason";
}

/// Metadata describing a published release.
@immutable
class AppReleaseInfo {
  final String tagName;
  final String version;
  final String title;
  final String notes;
  final DateTime publishedAt;
  final String htmlUrl;
  final String? assetName;
  final String? assetDownloadUrl;
  final int? assetSizeBytes;

  const AppReleaseInfo({
    required this.tagName,
    required this.version,
    required this.title,
    required this.notes,
    required this.publishedAt,
    required this.htmlUrl,
    this.assetName,
    this.assetDownloadUrl,
    this.assetSizeBytes,
  });

  factory AppReleaseInfo.fromJson(
    Map<String, dynamic> json, {
    TargetPlatform? platform,
    String? osRelease,
  }) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    final cleanVer = tag.startsWith('v') ? tag.substring(1) : tag;
    final name = (json['name'] as String? ?? tag).trim();
    final body = (json['body'] as String? ?? '').trim();
    final html = (json['html_url'] as String? ?? '').trim();
    final dateStr = json['published_at'] as String? ?? '';
    final date = DateTime.tryParse(dateStr) ?? DateTime.now();

    // Match release assets
    String? matchedAssetName;
    String? matchedAssetUrl;
    int? matchedSize;

    final bool isLinux;
    final bool isWindows;
    final bool isMac;
    if (platform != null) {
      isLinux = platform == TargetPlatform.linux;
      isWindows = platform == TargetPlatform.windows;
      isMac = platform == TargetPlatform.macOS;
    } else {
      isLinux = defaultTargetPlatform == TargetPlatform.linux || (!kIsWeb && Platform.isLinux);
      isWindows = defaultTargetPlatform == TargetPlatform.windows || (!kIsWeb && Platform.isWindows);
      isMac = defaultTargetPlatform == TargetPlatform.macOS || (!kIsWeb && Platform.isMacOS);
    }

    final assets = json['assets'] as List<dynamic>? ?? const [];
    if (isLinux) {
      // Walk the distro's preference order, so the first matching extension
      // wins regardless of the order assets appear in the API payload.
      final preference = preferAssetOrder(osRelease);
      for (final ext in preference) {
        for (final a in assets) {
          if (a is! Map<String, dynamic>) continue;
          final aName = (a['name'] as String? ?? '').toLowerCase();
          if (!aName.endsWith(ext)) continue;
          matchedAssetName = a['name'] as String?;
          matchedAssetUrl = a['browser_download_url'] as String? ?? '';
          matchedSize = a['size'] as int?;
          break;
        }
        if (matchedAssetName != null) break;
      }
      // Unknown distro: AppImage is universal, but if the release ships none,
      // fall back to a native package rather than leaving no download at all.
      if (matchedAssetName == null && preference.length == 1) {
        for (final a in assets) {
          if (a is! Map<String, dynamic>) continue;
          final aName = (a['name'] as String? ?? '').toLowerCase();
          if (!aName.endsWith('.rpm') && !aName.endsWith('.deb')) continue;
          matchedAssetName = a['name'] as String?;
          matchedAssetUrl = a['browser_download_url'] as String? ?? '';
          matchedSize = a['size'] as int?;
          break;
        }
      }
    } else {
      for (final a in assets) {
        if (a is! Map<String, dynamic>) continue;
        final aName = (a['name'] as String? ?? '').toLowerCase();
        final aUrl = a['browser_download_url'] as String? ?? '';
        final aSize = a['size'] as int?;

        if (isWindows) {
          if (aName.endsWith('.exe')) {
            matchedAssetName = a['name'] as String?;
            matchedAssetUrl = aUrl;
            matchedSize = aSize;
            break;
          }
        } else if (isMac) {
          if (aName.endsWith('.dmg') || aName.endsWith('.zip')) {
            matchedAssetName = a['name'] as String?;
            matchedAssetUrl = aUrl;
            matchedSize = aSize;
            if (aName.endsWith('.dmg')) break; // Prefer DMG on macOS
          }
        }
      }
    }

    return AppReleaseInfo(
      tagName: tag,
      version: cleanVer,
      title: name,
      notes: body,
      publishedAt: date,
      htmlUrl: html,
      assetName: matchedAssetName,
      assetDownloadUrl: matchedAssetUrl,
      assetSizeBytes: matchedSize,
    );
  }

  String get formattedSize {
    final bytes = assetSizeBytes;
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// State representation of the in-app update service.
@immutable
class UpdateState {
  final UpdateStatus status;
  final AppReleaseInfo? release;
  final double progress; // 0.0 to 1.0
  final int downloadedBytes;
  final int totalBytes;
  final String? downloadedFilePath;
  final String? errorMessage;
  final DateTime? lastChecked;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.release,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadedFilePath,
    this.errorMessage,
    this.lastChecked,
  });

  UpdateState copyWith({
    UpdateStatus? status,
    AppReleaseInfo? release,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? downloadedFilePath,
    String? errorMessage,
    DateTime? lastChecked,
  }) {
    return UpdateState(
      status: status ?? this.status,
      release: release ?? this.release,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedFilePath: downloadedFilePath ?? this.downloadedFilePath,
      errorMessage: errorMessage ?? this.errorMessage,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  /// Moves an installer from [UpdateStatus.installing] to its terminal state.
  ///
  /// Success opens the restart action; any failure keeps the downloaded file
  /// path so the dialog can offer to open its containing folder.
  UpdateState finishInstall(InstallOutcome outcome, {String? detail}) {
    final installed = outcome == InstallOutcome.installed;
    return UpdateState(
      status: installed ? UpdateStatus.readyToRelaunch : UpdateStatus.error,
      release: release,
      progress: progress,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      downloadedFilePath: downloadedFilePath,
      errorMessage: installed
          ? null
          : installFailureMessage(outcome, detail: detail),
      lastChecked: lastChecked,
    );
  }
}
