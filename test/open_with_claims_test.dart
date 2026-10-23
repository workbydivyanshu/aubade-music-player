import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/app/open_with_claims.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/features/library/supported_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registerable mime types', () {
    test('covers the packaging list in one place', () {
      expect(registerableAudioMimeTypes, hasLength(19));
      expect(registerableAudioMimeTypes.first, 'audio/mpeg');
      expect(registerableAudioMimeTypes.last, 'audio/x-flac');
      for (final mime in const [
        'audio/mpeg',
        'audio/flac',
        'audio/ogg',
        'audio/opus',
        'audio/x-opus+ogg',
        'audio/mp4',
        'audio/x-m4a',
        'audio/wav',
        'audio/x-wav',
        'audio/vnd.wave',
        'audio/aiff',
        'audio/x-aiff',
        'audio/x-ape',
        'audio/x-wavpack',
        'audio/x-ms-wma',
        'audio/x-musepack',
        'audio/x-matroska',
        'audio/aac',
        'audio/x-flac',
      ]) {
        expect(registerableAudioMimeTypes, contains(mime));
      }
    });
  });

  group('Linux user-level claims', () {
    late Directory root;
    late Directory home;
    late Directory systemDir;
    late List<({String exe, List<String> args})> commands;

    setUp(() {
      root = Directory.systemTemp.createTempSync('aubade_claims_');
      home = Directory('${root.path}/home')..createSync(recursive: true);
      systemDir = Directory('${root.path}/system-applications')
        ..createSync(recursive: true);
      commands = <({String exe, List<String> args})>[];
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    LinuxOpenWithClaims store({
      String executable = '/opt/aubade/aubade',
      bool systemInstalled = false,
    }) {
      final systemDesktop =
          File('${systemDir.path}${Platform.pathSeparator}aubade.desktop');
      if (systemInstalled) {
        systemDesktop.writeAsStringSync('[Desktop Entry]\nName=Aubade\n');
      } else if (systemDesktop.existsSync()) {
        systemDesktop.deleteSync();
      }
      return LinuxOpenWithClaims(
        homeDir: home.path,
        executable: executable,
        systemDesktopFile: systemDesktop.path,
        run: (exe, args) async => commands.add((exe: exe, args: args)),
      );
    }

    File desktopFile() => File(
        '${home.path}/.local/share/applications/aubade.desktop');
    File serviceMenuFile() => File(
        '${home.path}/.local/share/kio/servicemenus/aubade-servicemenu.desktop');

    test('probe, claim and unclaim round trip in a temp home', () async {
      final claims = store();
      expect(await claims.probeClaimed(), isFalse);

      await claims.claimAll();

      expect(await claims.probeClaimed(), isTrue);
      expect(desktopFile().existsSync(), isTrue);
      expect(serviceMenuFile().existsSync(), isTrue);

      final desktop = desktopFile().readAsStringSync();
      expect(desktop, contains('Name=Aubade'));
      expect(desktop, contains('Exec="/opt/aubade/aubade" %F'));
      expect(desktop, contains('Icon=aubade'));
      expect(desktop, contains('Terminal=false'));
      expect(desktop, contains(
          'Categories=AudioVideo;Audio;Player;Music;'));
      expect(desktop, contains('Type=Application'));
      expect(desktop, contains('StartupWMClass=com.aubade.desktop'));
      for (final mime in registerableAudioMimeTypes) {
        expect(desktop, contains('$mime;'), reason: mime);
      }

      final menu = serviceMenuFile().readAsStringSync();
      expect(menu, contains('Type=Service'));
      expect(menu, contains('Actions=openInAubade'));
      expect(menu, contains('[Desktop Action openInAubade]'));
      expect(menu, contains('Exec="/opt/aubade/aubade" %F'));
      for (final mime in registerableAudioMimeTypes) {
        expect(menu, contains('$mime;'), reason: mime);
      }

      final appsDir = '${home.path}/.local/share/applications';
      expect(
        commands.any((call) =>
            call.exe == 'chmod' &&
            call.args.length == 2 &&
            call.args[0] == '755' &&
            call.args[1] == serviceMenuFile().path),
        isTrue,
      );
      expect(
        commands.any((call) =>
            call.exe == 'update-desktop-database' &&
            call.args.length == 1 &&
            call.args[0] == appsDir),
        isTrue,
      );

      await claims.unclaimAll();

      expect(await claims.probeClaimed(), isFalse);
      expect(desktopFile().existsSync(), isFalse);
      expect(serviceMenuFile().existsSync(), isFalse);
    });

    test('quotes an executable path with spaces', () async {
      final claims = store(executable: '/home/me/My Apps/aubade');
      await claims.claimAll();
      expect(
        desktopFile().readAsStringSync(),
        contains('Exec="/home/me/My Apps/aubade" %F'),
      );
    });

    test('a package install wins and receives no user-level shadow', () async {
      final claims = store(systemInstalled: true);
      expect(await claims.probeClaimed(), isTrue);

      await claims.claimAll();

      expect(desktopFile().existsSync(), isFalse);
      expect(serviceMenuFile().existsSync(), isFalse);
      expect(await claims.probeClaimed(), isTrue);
    });

    test('unclaim never touches a desktop file owned by another install',
        () async {
      desktopFile().parent.createSync(recursive: true);
      desktopFile().writeAsStringSync(
          buildLinuxDesktopEntry('/somewhere/else/aubade'));
      final claims = store();

      await claims.unclaimAll();

      expect(desktopFile().existsSync(), isTrue);
    });

    test('the default factory uses the injected home only', () async {
      final claims = defaultOpenWithClaims(homeDir: home.path);
      expect(claims, isA<LinuxOpenWithClaims>());
      // Probe reads the injected home only; no file is written here.
      expect(await claims.probeClaimed(), isFalse);
      expect(desktopFile().existsSync(), isFalse);
    });
  });

  group('windows helpers', () {
    test('registry paths mirror the installer', () {
      if (Platform.isWindows) return;
      expect(windowsAudioProgId, 'Aubade.AudioFile');
      expect(windowsAudioProgIdKey, r'Software\Classes\Aubade.AudioFile');
      expect(windowsApplicationsKey,
          r'Software\Classes\Applications\aubade.exe');
      expect(
        windowsSupportedTypesKey,
        r'Software\Classes\Applications\aubade.exe\SupportedTypes',
      );
      expect(
        windowsOpenWithProgIdsKey('mp3'),
        r'Software\Classes\.mp3\OpenWithProgids',
      );
      expect(
        windowsOpenCommand(r'C:\Program Files\Aubade\aubade.exe'),
        r'"C:\Program Files\Aubade\aubade.exe" "%1"',
      );
      expect(registerableAudioExtensions, hasLength(15));
    });

    test('registry calls are inert outside Windows', () async {
      if (Platform.isWindows) return;
      final claims = WindowsOpenWithClaims(executable: 'C:\\aubade.exe');
      expect(await claims.probeClaimed(), isFalse);
      await claims.claimAll();
      await claims.unclaimAll();
      expect(await claims.probeClaimed(), isFalse);
    });
  });

  group('prefs flag', () {
    test('defaults off and round trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await Prefs.load();
      expect(prefs.openWithAudioFilesClaimed, isFalse);

      await prefs.setOpenWithAudioFilesClaimed(true);
      final reloaded = await Prefs.load();
      expect(reloaded.openWithAudioFilesClaimed, isTrue);

      await reloaded.setOpenWithAudioFilesClaimed(false);
      expect((await Prefs.load()).openWithAudioFilesClaimed, isFalse);
    });

    test('stores the aubade_ key, never a legacy lw_ key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await Prefs.load();
      await prefs.setOpenWithAudioFilesClaimed(true);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('aubade_open_with_audio_files_claimed'), isTrue);
      expect(
        sp.getKeys().where((key) => key.startsWith('lw_')),
        isEmpty,
      );
    });
  });

  group('inert platforms', () {
    test('macOS reports unsupported and does nothing', () async {
      const claims = InertOpenWithClaims();
      expect(claims.isSupported, isFalse);
      expect(await claims.probeClaimed(), isFalse);
      await claims.claimAll();
      await claims.unclaimAll();
    });
  });
}
