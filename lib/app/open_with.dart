import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/audio/stream_models.dart';
import '../features/library/supported_audio.dart';
import '../features/player/playback_service.dart';
import 'open_with_windows_stub.dart'
    if (dart.library.io) 'open_with_windows_io.dart' as windows;

/// Desktop identity used for both the D-Bus name and the object path
/// (`/com/aubade/desktop`). Matches the app id in linux/CMakeLists.txt.
const String openWithBusName = 'com.aubade.desktop';
const String openWithObjectPath = '/com/aubade/desktop';
const String openWithInterface = 'org.freedesktop.Application';

/// Queue label shown for files opened from the OS.
const String openWithSourceLabel = 'Local files';

/// Fixed launch-services contract shared with the macOS native side:
/// one method, `files`, whose arguments are raw absolute paths (no
/// `file://` scheme, already URL-decoded).
const String openWithChannelName = 'aubade/open_with';
const String openWithChannelMethod = 'files';

/// The macOS launch-services channel. Registration happens in `main`
/// before any prefs or database work so the native flush at launch end
/// is never missed.
const MethodChannel openWithChannel = MethodChannel(openWithChannelName);

/// What a cold start should do with the paths it was launched with.
sealed class RunModeDecision {
  final List<String> paths;
  const RunModeDecision(this.paths);
}

/// Boot normally; [paths] (possibly empty) are queued once the player is
/// ready.
class Proceed extends RunModeDecision {
  const Proceed(super.paths);
}

/// Another instance owns the app; it accepted the paths and this process
/// should exit without showing a window.
class Handoff extends RunModeDecision {
  const Handoff(super.paths);
}

/// Platform seam for the single-instance probe, so launcher tests can
/// fake ownership without a bus or a pipe.
abstract interface class OpenWithPlatform {
  /// Returns true when a running instance accepted [paths] (or a focus
  /// request when [paths] is empty).
  Future<bool> tryHandOff(List<String> paths);

  /// Starts the listener that owns the app's single-instance identity.
  Future<void> startOwner({
    required void Function(List<String> paths) onOpen,
    required void Function() onFocus,
  });
}

/// Picks the real platform implementation. Everything is lazy: no D-Bus
/// connection and no kernel32 lookup happens until an entry point runs.
OpenWithPlatform defaultOpenWithPlatform() {
  if (Platform.isWindows) return const _WindowsOpenWithPlatform();
  return const _LinuxOpenWithPlatform();
}

/// Early launcher decision, called from main before any prefs or window
/// work. Parses [args], hands them to an existing instance when one owns
/// the platform identity, otherwise starts the owner listener.
Future<RunModeDecision> decideRunMode(
  List<String> args, {
  String? cwd,
  OpenWithPlatform? platform,
}) async {
  final paths = parseOpenPaths(args, cwd: cwd);
  // macOS has no bus or pipe: argv is the shell-launch path only, and
  // Finder opens arrive on [openWithChannel]. Keep this a plain boot
  // with the parsed argv files.
  if (Platform.isLinux || Platform.isWindows) {
    final target = platform ?? defaultOpenWithPlatform();
    try {
      if (await target.tryHandOff(paths)) return Handoff(paths);
    } catch (_) {
      // A broken bus or a half-open pipe falls through to a normal boot.
    }
    try {
      await target.startOwner(
        onOpen: enqueueOpenPaths,
        onFocus: raiseAubadeWindow,
      );
    } catch (_) {
      // Serving is best-effort; playback still works this session.
    }
  }
  return Proceed(paths);
}

/// Parses OS-launched arguments into existing, supported absolute paths.
///
/// - strips one layer of surrounding quotes;
/// - ignores switches (`-psn_0_123`, `--foo`, `/R`);
/// - resolves relative paths against [cwd] (defaults to the process
///   working directory);
/// - keeps only supported extensions and files that exist;
/// - removes exact duplicates while preserving order.
List<String> parseOpenPaths(List<String> args, {String? cwd}) {
  final base = cwd ?? Directory.current.path;
  final paths = <String>[];
  final seen = <String>{};
  for (final raw in args) {
    final arg = stripSurroundingQuotes(raw.trim());
    if (arg.isEmpty || _looksLikeSwitch(arg)) continue;
    final resolved =
        p.normalize(p.isAbsolute(arg) ? arg : p.join(base, arg));
    if (!isSupportedAudioPath(resolved)) continue;
    final dedupeKey =
        Platform.isWindows ? resolved.toLowerCase() : resolved;
    if (!seen.add(dedupeKey)) continue;
    if (!File(resolved).existsSync()) continue;
    paths.add(resolved);
  }
  return paths;
}

bool _looksLikeSwitch(String arg) {
  if (arg.startsWith('-')) return true;
  // Windows launchers pass short slash switches such as /R. Do not treat
  // ordinary absolute POSIX paths (/home/...) as switches.
  return RegExp(r'^/[A-Za-z]{1,3}$').hasMatch(arg);
}

/// `file://` URI for a local path, as expected by
/// org.freedesktop.Application.Open.
String pathToFileUri(String path) => Uri.file(path).toString();

/// Decodes one `file://` URI back to a raw absolute path. Returns null
/// for other schemes or malformed URIs.
String? fileUriToPath(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme != 'file') return null;
  try {
    return parsed.toFilePath();
  } catch (_) {
    return null;
  }
}

/// Decodes an incoming URI list to raw paths, in order.
List<String> decodeOpenUris(Iterable<String> uris) {
  final paths = <String>[];
  for (final uri in uris) {
    final path = fileUriToPath(uri);
    if (path == null || path.isEmpty) continue;
    paths.add(path);
  }
  return paths;
}

/// Registers the macOS launch-services receiver. Called once from
/// `main`, immediately after the binding exists and before prefs or the
/// database are opened.
void registerOpenWithChannel() {
  openWithChannel.setMethodCallHandler(handleOpenWithChannelCall);
}

/// Decodes one `aubade/open_with` call. Contract: method `files` with a
/// `List<String>` of raw absolute paths. Paths are whitelisted by
/// [enqueueOpenPaths]; anything that arrives before the player is warm
/// waits in the same pending hook as argv files.
@visibleForTesting
Future<void> handleOpenWithChannelCall(MethodCall call) async {
  if (call.method != openWithChannelMethod) return;
  final arguments = call.arguments;
  if (arguments is! List) return;
  final paths = <String>[
    for (final value in arguments)
      if (value is String && value.isNotEmpty) value,
  ];
  if (paths.isEmpty) return;
  await enqueueOpenPaths(paths);
}

// ---------------------------------------------------------------------------
// Process-wide intent hook
// ---------------------------------------------------------------------------

final List<String> _pendingPaths = <String>[];
WidgetRef? _activeRef;

/// Test seam mirroring PlaybackService.playQueue. When set, delivery
/// goes here instead of through a live provider container.
@visibleForTesting
typedef OpenWithQueueSink = Future<void> Function(
    List<PlayableTrack> tracks, int startIndex, String sourceLabel);

/// Overrides playback delivery in tests. Never set in the app.
@visibleForTesting
OpenWithQueueSink? debugOpenWithQueueSink;

/// Appends paths (used at boot, after the channel is live, so paths
/// that arrived during startup are never clobbered).
void addPendingOpenPaths(Iterable<String> paths) {
  for (final path in paths) {
    if (!isSupportedAudioPath(path)) continue;
    if (_pendingPaths.contains(path)) continue;
    _pendingPaths.add(path);
  }
}

/// Replaces pending paths (tests and explicit reset).
void setPendingOpenPaths(Iterable<String> paths) {
  _pendingPaths.clear();
  addPendingOpenPaths(paths);
}

/// Read-only view for tests and diagnostics.
List<String> get pendingOpenPaths => List<String>.unmodifiable(_pendingPaths);

/// Converts raw paths into local queue entries. The title comes from the
/// basename; the artist is the established local-file label.
List<PlayableTrack> tracksFromOpenPaths(Iterable<String> paths) {
  final tracks = <PlayableTrack>[];
  for (final path in paths) {
    if (!isSupportedAudioPath(path)) continue;
    tracks.add(PlayableTrack(
      title: p.basenameWithoutExtension(path),
      artist: 'Local file',
      playbackUrl: path,
    ));
  }
  return tracks;
}

/// Drains paths that arrived before playback was ready. Wired right
/// after `ensurePlayer()` in the app root, so this is also the point
/// where late handoffs gain a provider container.
Future<void> flushOpenWithIntent(WidgetRef? ref) async {
  if (ref != null) _activeRef = ref;
  final pending = List<String>.of(_pendingPaths);
  _pendingPaths.clear();
  final tracks = tracksFromOpenPaths(pending);
  if (tracks.isEmpty) return;
  await _deliverTracks(tracks, ref);
}

/// Accepts a handoff from a running instance: queues immediately when
/// playback is warm, otherwise parks the paths for the boot flush, then
/// raises the window.
Future<void> enqueueOpenPaths(List<String> paths) async {
  final accepted = paths.where(isSupportedAudioPath).toList();
  if (accepted.isEmpty) return;
  final ref = _activeRef;
  if (ref == null && debugOpenWithQueueSink == null) {
    addPendingOpenPaths(accepted);
    return;
  }
  await _deliverTracks(tracksFromOpenPaths(accepted), ref);
  await raiseAubadeWindow();
}

Future<void> _deliverTracks(List<PlayableTrack> tracks, WidgetRef? ref) async {
  if (tracks.isEmpty) return;
  final sink = debugOpenWithQueueSink;
  if (sink != null) {
    await sink(tracks, 0, openWithSourceLabel);
    return;
  }
  final target = ref ?? _activeRef;
  if (target == null) return;
  _activeRef = target;
  await target
      .read(playbackServiceProvider.notifier)
      .playQueue(tracks, 0, sourceLabel: openWithSourceLabel);
}

/// Best-effort raise/focus for a second launch. Wayland compositors may
/// refuse focus; failures are ignored.
Future<void> raiseAubadeWindow() async {
  try {
    await windowManager.show();
  } catch (_) {}
  try {
    await windowManager.focus();
  } catch (_) {}
}

/// Clears the process-wide intent state between tests.
@visibleForTesting
void resetOpenWithState() {
  _pendingPaths.clear();
  _activeRef = null;
  debugOpenWithQueueSink = null;
}

// ---------------------------------------------------------------------------
// Linux: org.freedesktop.Application over the session bus
// ---------------------------------------------------------------------------

class _LinuxOpenWithPlatform implements OpenWithPlatform {
  const _LinuxOpenWithPlatform();

  @override
  Future<bool> tryHandOff(List<String> paths) async {
    if (paths.isEmpty) return false;
    DBusClient? client;
    try {
      client = DBusClient.session();
      if (!await client.nameHasOwner(openWithBusName)) return false;
      await client
          .callMethod(
            destination: openWithBusName,
            path: DBusObjectPath(openWithObjectPath),
            interface: openWithInterface,
            name: 'Open',
            values: <DBusValue>[
              DBusArray.string(paths.map(pathToFileUri)),
              DBusDict.stringVariant(const <String, DBusValue>{}),
            ],
          )
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await client?.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> startOwner({
    required void Function(List<String> paths) onOpen,
    required void Function() onFocus,
  }) async {
    if (_busClient != null) return;
    DBusClient? client;
    try {
      client = DBusClient.session();
      final object =
          _ApplicationObject(onOpen: onOpen, onFocus: onFocus);
      await client.registerObject(object);
      final reply = await client
          .requestName(
            openWithBusName,
            flags: const <DBusRequestNameFlag>{
              DBusRequestNameFlag.doNotQueue,
            },
          )
          .timeout(const Duration(seconds: 2));
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        await client.close();
        return;
      }
      _busClient = client;
    } catch (_) {
      try {
        await client?.close();
      } catch (_) {}
    }
  }
}

DBusClient? _busClient;

/// Drops the owned bus name (tests and orderly shutdown).
Future<void> shutdownOpenWithOwner() async {
  final client = _busClient;
  _busClient = null;
  try {
    await client?.close();
  } catch (_) {}
}

class _ApplicationObject extends DBusObject {
  final void Function(List<String> paths) onOpen;
  final void Function() onFocus;

  _ApplicationObject({
    required this.onOpen,
    required this.onFocus,
  }) : super(DBusObjectPath(openWithObjectPath));

  @override
  List<DBusIntrospectInterface> introspect() => <DBusIntrospectInterface>[
        DBusIntrospectInterface(
          openWithInterface,
          methods: <DBusIntrospectMethod>[
            DBusIntrospectMethod('Activate', args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                DBusSignature('a{sv}'),
                DBusArgumentDirection.in_,
                name: 'platform_data',
              ),
            ]),
            DBusIntrospectMethod('Open', args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                DBusSignature('as'),
                DBusArgumentDirection.in_,
                name: 'uris',
              ),
              DBusIntrospectArgument(
                DBusSignature('a{sv}'),
                DBusArgumentDirection.in_,
                name: 'platform_data',
              ),
            ]),
            DBusIntrospectMethod('ActivateAction',
                args: <DBusIntrospectArgument>[
                  DBusIntrospectArgument(
                    DBusSignature('s'),
                    DBusArgumentDirection.in_,
                    name: 'action_name',
                  ),
                  DBusIntrospectArgument(
                    DBusSignature('a{sv}'),
                    DBusArgumentDirection.in_,
                    name: 'platform_data',
                  ),
                  DBusIntrospectArgument(
                    DBusSignature('as'),
                    DBusArgumentDirection.in_,
                    name: 'parameters',
                  ),
                ]),
          ],
        ),
      ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != null && call.interface != openWithInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Open':
        final uris = call.values.isEmpty
            ? const <String>[]
            : _stringArray(call.values.first);
        final paths = decodeOpenUris(uris);
        if (paths.isNotEmpty) onOpen(paths);
        return DBusMethodSuccessResponse();
      case 'Activate':
        onFocus();
        return DBusMethodSuccessResponse();
      case 'ActivateAction':
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  List<String> _stringArray(DBusValue value) {
    if (value is! DBusArray) return const <String>[];
    return <String>[
      for (final child in value.children)
        if (child is DBusString) child.value,
    ];
  }
}

class _WindowsOpenWithPlatform implements OpenWithPlatform {
  const _WindowsOpenWithPlatform();

  @override
  Future<bool> tryHandOff(List<String> paths) =>
      windows.windowsOpenHandoff(paths);

  @override
  Future<void> startOwner({
    required void Function(List<String> paths) onOpen,
    required void Function() onFocus,
  }) =>
      windows.windowsOpenServe(onOpen: onOpen, onFocus: onFocus);
}
