import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import '../features/library/supported_audio.dart';

/// Reversible, per-user registration of Aubade as an "Open with" handler.
///
/// This is the installer-less counterpart to the package claims: nothing
/// here runs at boot. The Settings toggle calls [claimAll] or
/// [unclaimAll], and [probeClaimed] only reports what is already on disk
/// (or in the registry) so the row stays honest after a package install
/// owned the same association.
abstract interface class OpenWithClaims {
  /// False on platforms where the OS owns the association (macOS) and
  /// the toggle has nothing to change. The settings row is hidden then.
  bool get isSupported;

  /// True when this user already has an Aubade "Open with" claim.
  Future<bool> probeClaimed();

  /// Writes the per-user claims for every registerable audio extension.
  Future<void> claimAll();

  /// Removes only the claims written by this app, never a package's.
  Future<void> unclaimAll();

  /// Opt-in: asks the OS to make Aubade the default player for the
  /// claimed types. Never writes a Windows UserChoice key; on Windows
  /// it only opens the system page where the user decides.
  Future<void> makeDefault();
}

/// Test seam: lets settings widget tests use a fake claim store.
@visibleForTesting
OpenWithClaims? debugOpenWithClaims;

/// The claim store the settings page uses.
OpenWithClaims appOpenWithClaims() =>
    debugOpenWithClaims ?? defaultOpenWithClaims();

/// Picks the real platform implementation. [homeDir] is a test seam for
/// the Linux branch; the app always passes null and uses `$HOME`.
OpenWithClaims defaultOpenWithClaims({String? homeDir}) {
  if (Platform.isWindows) return WindowsOpenWithClaims();
  if (Platform.isLinux) return LinuxOpenWithClaims(homeDir: homeDir);
  return const InertOpenWithClaims();
}

/// macOS and anything else: the bundle declares the types, so there is
/// nothing to toggle and no files to write.
class InertOpenWithClaims implements OpenWithClaims {
  const InertOpenWithClaims();

  @override
  bool get isSupported => false;

  @override
  Future<bool> probeClaimed() async => false;

  @override
  Future<void> claimAll() async {}

  @override
  Future<void> unclaimAll() async {}

  @override
  Future<void> makeDefault() async {}
}

// ---------------------------------------------------------------------------
// Linux: user-level desktop entry + KDE service menu
// ---------------------------------------------------------------------------

/// Runs one best-effort helper (`update-desktop-database`, `chmod`, ...).
typedef ClaimCommandRunner = Future<void> Function(
  String executable,
  List<String> arguments,
);

Future<void> _runQuietly(String executable, List<String> arguments) async {
  try {
    await Process.run(executable, arguments);
  } catch (_) {
    // Missing helpers are fine: the desktop file still works.
  }
}

/// Desktop entry written when the user turns the toggle on.
String buildLinuxDesktopEntry(String executable) => '''[Desktop Entry]
Type=Application
Name=Aubade
Exec=${_quoteDesktopExec(executable)} %F
Icon=aubade
Terminal=false
Categories=AudioVideo;Audio;Player;Music;
StartupWMClass=com.aubade.desktop
MimeType=$_mimeList
''';

/// KDE service menu mirroring linux/packaging/aubade-servicemenu.desktop.
String buildLinuxServiceMenuEntry(String executable) => '''[Desktop Entry]
Type=Service
MimeType=$_mimeList
Actions=openInAubade
X-KDE-Priority=TopLevel
X-KDE-StartupNotify=false
Icon=aubade

[Desktop Action openInAubade]
Name=Open in Aubade
Icon=aubade
Exec=${_quoteDesktopExec(executable)} %F
''';

final String _mimeList = registerableAudioMimeTypes.map((m) => '$m;').join();

/// Quotes one Exec argument with the escapes the desktop-entry spec
/// requires. Always quoted so paths with spaces work.
String _quoteDesktopExec(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$');
  return '"$escaped"';
}

class LinuxOpenWithClaims implements OpenWithClaims {
  LinuxOpenWithClaims({
    String? homeDir,
    String? executable,
    String? systemDesktopFile,
    ClaimCommandRunner? run,
  })  : _home = homeDir ?? Platform.environment['HOME'] ?? '',
        _executable = executable ?? _defaultExecutable(),
        _systemDesktopFile = systemDesktopFile ??
            '/usr/share/applications/aubade.desktop',
        _run = run ?? _runQuietly;

  final String _home;
  final String _executable;
  final String _systemDesktopFile;
  final ClaimCommandRunner _run;

  static String _defaultExecutable() {
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    return Platform.resolvedExecutable;
  }

  String get _applicationsDir =>
      '$_home/.local/share/applications';
  String get _serviceMenuDir => '$_home/.local/share/kio/servicemenus';
  String get _desktopFile => '$_applicationsDir/aubade.desktop';
  String get _serviceMenuFile => '$_serviceMenuDir/aubade-servicemenu.desktop';

  @override
  bool get isSupported => true;

  @override
  Future<bool> probeClaimed() async {
    if (!Platform.isLinux) return false;
    // A package install already claimed the types system-wide.
    if (await File(_systemDesktopFile).exists()) return true;
    return File(_desktopFile).exists();
  }

  @override
  Future<void> claimAll() async {
    if (!Platform.isLinux) return;
    // System claims win; do not shadow them with a user-level file.
    if (await File(_systemDesktopFile).exists()) return;
    try {
      await Directory(_applicationsDir).create(recursive: true);
      await File(_desktopFile)
          .writeAsString(buildLinuxDesktopEntry(_executable));
      await Directory(_serviceMenuDir).create(recursive: true);
      final serviceMenu = File(_serviceMenuFile);
      await serviceMenu.writeAsString(buildLinuxServiceMenuEntry(_executable));
      await _run('chmod', ['755', serviceMenu.path]);
    } catch (_) {
      // Leave whatever was written; the probe reports the real state.
    }
    await _run('update-desktop-database', [_applicationsDir]);
  }

  @override
  Future<void> unclaimAll() async {
    if (!Platform.isLinux) return;
    final appImage = Platform.environment['APPIMAGE'];
    final ownMarkers = <String>{
      _quoteDesktopExec(_executable),
      _quoteDesktopExec(Platform.resolvedExecutable),
      if (appImage != null && appImage.isNotEmpty)
        _quoteDesktopExec(appImage),
    };
    for (final path in <String>[_desktopFile, _serviceMenuFile]) {
      final file = File(path);
      if (!await file.exists()) continue;
      String content;
      try {
        content = await file.readAsString();
      } catch (_) {
        continue;
      }
      // Never delete a file that points at some other Aubade install
      // (for example a package-managed copy in the user's own dir).
      if (!ownMarkers.any(content.contains)) continue;
      try {
        await file.delete();
      } catch (_) {}
    }
    await _run('update-desktop-database', [_applicationsDir]);
  }

  @override
  Future<void> makeDefault() async {
    if (!Platform.isLinux) return;
    // The packaged and user-level entries share the same desktop id.
    for (final mime in registerableAudioMimeTypes) {
      await _run('xdg-mime', ['default', 'aubade.desktop', mime]);
    }
  }
}

// ---------------------------------------------------------------------------
// Windows: per-user registry claims (HKCU only)
// ---------------------------------------------------------------------------

const String windowsAudioProgId = 'Aubade.AudioFile';
const String windowsAudioProgIdKey =
    r'Software\Classes\Aubade.AudioFile';
const String windowsApplicationsKey =
    r'Software\Classes\Applications\aubade.exe';
const String windowsSupportedTypesKey =
    r'Software\Classes\Applications\aubade.exe\SupportedTypes';

/// Progid list key for one extension. Only this value is ever written;
/// the extension's default handler is left alone.
String windowsOpenWithProgIdsKey(String extension) =>
    'Software\\Classes\\.$extension\\OpenWithProgids';

/// Shell open command line, quoting both the exe and `%1`.
String windowsOpenCommand(String executable) => '"$executable" "%1"';

const int _shcneAssocChanged = 0x08000000;
const int _shcnfIdList = 0x00000000;

typedef _ShChangeNotifyNative = Void Function(
  Int32 eventId,
  Uint32 flags,
  Pointer<Void> item1,
  Pointer<Void> item2,
);
typedef _ShChangeNotifyDart = void Function(
  int eventId,
  int flags,
  Pointer<Void> item1,
  Pointer<Void> item2,
);

final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

final _shChangeNotify = _shell32.lookupFunction<_ShChangeNotifyNative,
    _ShChangeNotifyDart>('SHChangeNotify');

void _notifyShellAssociations() {
  try {
    _shChangeNotify(_shcneAssocChanged, _shcnfIdList, nullptr, nullptr);
  } catch (_) {
    // The registry entries work without the refresh; Explorer picks
    // them up on the next sign-in at the latest.
  }
}

HKEY? _createRegistryKey(String subKey) {
  final name = subKey.toNativeUtf16();
  final out = calloc<Pointer>();
  try {
    final result = RegCreateKeyEx(
      HKEY_CURRENT_USER,
      PCWSTR(name),
      null,
      REG_OPTION_NON_VOLATILE,
      KEY_ALL_ACCESS,
      null,
      out,
      nullptr,
    );
    if (result.isError) return null;
    return HKEY(out.value);
  } finally {
    calloc.free(out);
    malloc.free(name);
  }
}

HKEY? _openRegistryKey(String subKey, REG_SAM_FLAGS access) {
  final name = subKey.toNativeUtf16();
  final out = calloc<Pointer>();
  try {
    final result = RegOpenKeyEx(
      HKEY_CURRENT_USER,
      PCWSTR(name),
      0,
      access,
      out,
    );
    if (result.isError) return null;
    return HKEY(out.value);
  } finally {
    calloc.free(out);
    malloc.free(name);
  }
}

bool _setRegistryString(HKEY key, String? valueName, String data) {
  final name = valueName?.toNativeUtf16();
  final value = data.toNativeUtf16();
  try {
    final result = RegSetValueEx(
      key,
      name == null ? null : PCWSTR(name),
      REG_SZ,
      value.cast<Uint8>(),
      (data.length + 1) * 2,
    );
    return result.isOk;
  } finally {
    if (name != null) malloc.free(name);
    malloc.free(value);
  }
}

bool _createKeyWithString(String subKey, String? valueName, String data) {
  final key = _createRegistryKey(subKey);
  if (key == null) return false;
  try {
    return _setRegistryString(key, valueName, data);
  } finally {
    key.close();
  }
}

void _deleteRegistryTree(String subKey) {
  final name = subKey.toNativeUtf16();
  try {
    RegDeleteTree(HKEY_CURRENT_USER, PCWSTR(name));
  } finally {
    malloc.free(name);
  }
}

bool _hasRegistryValue(HKEY key, String valueName) {
  final name = valueName.toNativeUtf16();
  final size = calloc<Uint32>();
  try {
    final result = RegQueryValueEx(
      key,
      PCWSTR(name),
      nullptr,
      nullptr,
      size,
    );
    return result.isOk;
  } finally {
    calloc.free(size);
    malloc.free(name);
  }
}

class WindowsOpenWithClaims implements OpenWithClaims {
  WindowsOpenWithClaims({String? executable, ClaimCommandRunner? run})
      : _executableOverride = executable,
        _run = run ?? _runQuietly;

  final String? _executableOverride;
  final ClaimCommandRunner _run;

  String get _executable => _executableOverride ?? Platform.resolvedExecutable;

  @override
  bool get isSupported => true;

  @override
  Future<bool> probeClaimed() async {
    if (!Platform.isWindows) return false;
    final key = _openRegistryKey(
      windowsOpenWithProgIdsKey('mp3'),
      KEY_READ,
    );
    if (key == null) return false;
    try {
      return _hasRegistryValue(key, windowsAudioProgId);
    } finally {
      key.close();
    }
  }

  @override
  Future<void> claimAll() async {
    if (!Platform.isWindows) return;
    final exe = _executable;
    final progId = _createRegistryKey(windowsAudioProgIdKey);
    if (progId != null) {
      try {
        _setRegistryString(progId, null, 'Aubade audio file');
        _setRegistryString(progId, 'FriendlyTypeName', 'Aubade audio file');
        _setRegistryString(progId, 'DefaultIcon', '$exe,0');
      } finally {
        progId.close();
      }
    }
    _createKeyWithString(
      '$windowsAudioProgIdKey\\shell\\open',
      null,
      'Open with Aubade',
    );
    _createKeyWithString(
      '$windowsAudioProgIdKey\\shell\\open\\command',
      null,
      windowsOpenCommand(exe),
    );
    for (final extension in registerableAudioExtensions) {
      _createKeyWithString(
        windowsOpenWithProgIdsKey(extension),
        windowsAudioProgId,
        '',
      );
    }
    _createKeyWithString(
      windowsApplicationsKey,
      'FriendlyAppName',
      'Aubade',
    );
    final types = _createRegistryKey(windowsSupportedTypesKey);
    if (types != null) {
      try {
        for (final extension in registerableAudioExtensions) {
          _setRegistryString(types, '.$extension', '');
        }
      } finally {
        types.close();
      }
    }
    _notifyShellAssociations();
  }

  @override
  Future<void> unclaimAll() async {
    if (!Platform.isWindows) return;
    _deleteRegistryTree(windowsAudioProgIdKey);
    _deleteRegistryTree(windowsApplicationsKey);
    for (final extension in registerableAudioExtensions) {
      final key = _openRegistryKey(
        windowsOpenWithProgIdsKey(extension),
        KEY_ALL_ACCESS,
      );
      if (key == null) continue;
      try {
        // Remove our value only; the extension's own default stays.
        final valueName = windowsAudioProgId.toNativeUtf16();
        try {
          RegDeleteValue(key, PCWSTR(valueName));
        } finally {
          malloc.free(valueName);
        }
      } finally {
        key.close();
      }
    }
    _notifyShellAssociations();
  }

  @override
  Future<void> makeDefault() async {
    // Apps may not set defaults on Windows 10+; the system page is the
    // sanctioned surface. No UserChoice key is ever written here.
    await _run('explorer.exe', ['ms-settings:defaultapps']);
  }
}
