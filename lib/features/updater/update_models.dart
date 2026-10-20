import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// Status of the in-app update lifecycle.
enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  readyToInstall,
  error,
}

/// Metadata describing a release published on GitHub.
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

  factory AppReleaseInfo.fromJson(Map<String, dynamic> json, {TargetPlatform? platform}) {
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
    for (final a in assets) {
      if (a is! Map<String, dynamic>) continue;
      final aName = (a['name'] as String? ?? '').toLowerCase();
      final aUrl = a['browser_download_url'] as String? ?? '';
      final aSize = a['size'] as int?;

      if (isLinux) {
        if (aName.endsWith('.rpm') || aName.endsWith('.appimage')) {
          matchedAssetName = a['name'] as String?;
          matchedAssetUrl = aUrl;
          matchedSize = aSize;
          if (aName.endsWith('.rpm')) break; // Prefer RPM on Fedora
        }
      } else if (isWindows) {
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
}
