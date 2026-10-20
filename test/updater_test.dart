import 'package:aubade/features/updater/update_models.dart';
import 'package:aubade/features/updater/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateService.isNewerVersion', () {
    test('detects patch bump as newer', () {
      expect(UpdateService.isNewerVersion('1.3.1', '1.3.0'), isTrue);
    });

    test('detects minor bump as newer', () {
      expect(UpdateService.isNewerVersion('1.4.0', '1.3.0'), isTrue);
    });

    test('detects major bump as newer', () {
      expect(UpdateService.isNewerVersion('2.0.0', '1.3.0'), isTrue);
    });

    test('treats same version as not newer', () {
      expect(UpdateService.isNewerVersion('1.3.0', '1.3.0'), isFalse);
    });

    test('treats older version as not newer', () {
      expect(UpdateService.isNewerVersion('1.2.9', '1.3.0'), isFalse);
      expect(UpdateService.isNewerVersion('0.9.9', '1.3.0'), isFalse);
    });

    test('handles leading v prefix on release tag', () {
      expect(UpdateService.isNewerVersion('v1.3.1', '1.3.0'), isTrue);
      expect(UpdateService.isNewerVersion('v1.3.0', '1.3.0'), isFalse);
    });

    test('handles build number suffix', () {
      expect(UpdateService.isNewerVersion('1.3.1+1', '1.3.0+5'), isTrue);
      expect(UpdateService.isNewerVersion('1.3.0+2', '1.3.0+1'), isFalse);
    });
  });

  group('AppReleaseInfo', () {
    test('parses GitHub release payload and matches platform asset', () {
      final json = {
        'tag_name': 'v1.3.1',
        'name': 'Aubade v1.3.1 Release',
        'body': '### Features\n- In-app update support\n- Performance improvements',
        'published_at': '2026-10-21T12:00:00Z',
        'html_url': 'https://github.com/workbydivyanshu/aubade-music-player/releases/tag/v1.3.1',
        'assets': [
          {
            'name': 'aubade-1.3.1-1.fc44.x86_64.rpm',
            'browser_download_url': 'https://github.com/workbydivyanshu/aubade-music-player/releases/download/v1.3.1/aubade-1.3.1-1.fc44.x86_64.rpm',
            'size': 14680064,
          },
          {
            'name': 'aubade_1.3.1_x86_64.AppImage',
            'browser_download_url': 'https://github.com/workbydivyanshu/aubade-music-player/releases/download/v1.3.1/aubade_1.3.1_x86_64.AppImage',
            'size': 65000000,
          },
          {
            'name': 'aubade_1.3.1_windows-x86_64-setup.exe',
            'browser_download_url': 'https://github.com/workbydivyanshu/aubade-music-player/releases/download/v1.3.1/aubade_1.3.1_windows-x86_64-setup.exe',
            'size': 25000000,
          },
        ],
      };

      final info = AppReleaseInfo.fromJson(json);

      expect(info.tagName, equals('v1.3.1'));
      expect(info.version, equals('1.3.1'));
      expect(info.title, equals('Aubade v1.3.1 Release'));
      expect(info.notes, contains('In-app update support'));
      expect(info.htmlUrl, contains('/releases/tag/v1.3.1'));
      expect(info.assetName, isNotNull);
      expect(info.assetDownloadUrl, isNotNull);
      expect(info.formattedSize, isNotEmpty);
    });

    test('formats asset size accurately', () {
      final now = DateTime(2026, 10, 20);
      final mega = AppReleaseInfo(
        tagName: 'v1.3.1',
        version: '1.3.1',
        title: 'Release',
        notes: '',
        publishedAt: now,
        htmlUrl: '',
        assetSizeBytes: 15 * 1024 * 1024,
      );
      expect(mega.formattedSize, equals('15.0 MB'));

      final kilo = AppReleaseInfo(
        tagName: 'v1.3.1',
        version: '1.3.1',
        title: 'Release',
        notes: '',
        publishedAt: now,
        htmlUrl: '',
        assetSizeBytes: 512 * 1024,
      );
      expect(kilo.formattedSize, equals('512 KB'));
    });
  });

  group('UpdateState', () {
    test('copyWith updates fields correctly', () {
      const initial = UpdateState(status: UpdateStatus.idle);
      final checking = initial.copyWith(status: UpdateStatus.checking);
      expect(checking.status, equals(UpdateStatus.checking));

      final downloading = checking.copyWith(
        status: UpdateStatus.downloading,
        progress: 0.5,
        downloadedBytes: 50,
        totalBytes: 100,
      );
      expect(downloading.status, equals(UpdateStatus.downloading));
      expect(downloading.progress, equals(0.5));
      expect(downloading.downloadedBytes, equals(50));
      expect(downloading.totalBytes, equals(100));

      final ready = downloading.copyWith(
        status: UpdateStatus.readyToInstall,
        downloadedFilePath: '/tmp/aubade.rpm',
      );
      expect(ready.status, equals(UpdateStatus.readyToInstall));
      expect(ready.downloadedFilePath, equals('/tmp/aubade.rpm'));
    });
  });
}
