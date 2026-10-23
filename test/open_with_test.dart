import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/app/open_with.dart';
import 'package:aubade/app/open_with_wire.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/features/library/supported_audio.dart';

class _FakePlatform implements OpenWithPlatform {
  _FakePlatform({this.acceptHandoff = false});

  final bool acceptHandoff;
  final List<List<String>> handoffs = <List<String>>[];
  bool ownerStarted = false;
  void Function(List<String> paths)? onOpen;
  void Function()? onFocus;

  @override
  Future<bool> tryHandOff(List<String> paths) async {
    handoffs.add(paths);
    return acceptHandoff;
  }

  @override
  Future<void> startOwner({
    required void Function(List<String> paths) onOpen,
    required void Function() onFocus,
  }) async {
    ownerStarted = true;
    this.onOpen = onOpen;
    this.onFocus = onFocus;
  }
}

typedef _QueueCall = ({
  List<PlayableTrack> tracks,
  int index,
  String label,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<_QueueCall> calls;

  setUp(() {
    resetOpenWithState();
    dir = Directory.systemTemp.createTempSync('aubade_open_with_');
    calls = <_QueueCall>[];
    debugOpenWithQueueSink = (tracks, index, label) async {
      calls.add((tracks: tracks, index: index, label: label));
    };
  });

  tearDown(() {
    openWithChannel.setMethodCallHandler(null);
    resetOpenWithState();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File makeFile(String name, [String contents = 'x']) =>
      File('${dir.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(contents);

  group('supported audio extensions', () {
    test('accepts the playable formats case-insensitively', () {
      for (final ext in playableAudioExtensions) {
        expect(isSupportedAudioPath('song.$ext'), isTrue, reason: ext);
        expect(
            isSupportedAudioPath('song.${ext.toUpperCase()}'), isTrue,
            reason: ext);
      }
    });

    test('tolerates surrounding quotes', () {
      expect(isSupportedAudioPath('"track.MP3"'), isTrue);
      expect(isSupportedAudioPath("'track.flac'"), isTrue);
      expect(isSupportedAudioPath('"track.MP3\''), isFalse);
    });

    test('rejects unsupported and missing extensions', () {
      expect(isSupportedAudioPath('notes.txt'), isFalse);
      expect(isSupportedAudioPath('song.mp4'), isFalse);
      expect(isSupportedAudioPath('song.webm'), isFalse);
      expect(isSupportedAudioPath('no-extension'), isFalse);
      expect(isSupportedAudioPath(''), isFalse);
      expect(isSupportedAudioPath('trailing.'), isFalse);
    });

    test('drag and drop keeps the video containers', () {
      expect(isSupportedDropPath('song.mp4'), isTrue);
      expect(isSupportedDropPath('song.webm'), isTrue);
      expect(isSupportedDropPath('song.MP3'), isTrue);
      expect(isSupportedDropPath('notes.txt'), isFalse);
    });

    test('registerable list covers the packaging formats', () {
      expect(
          registerableAudioExtensions,
          containsAll(<String>[
            'mp3',
            'flac',
            'opus',
            'oga',
            'm4a',
            'm4b',
            'wav',
            'aiff',
            'aif',
            'aifc',
            'wma',
            'aac',
            'ape',
            'wv',
            'mka',
          ]));
    });
  });

  group('argument parsing', () {
    test('ignores switches and keeps supported files', () {
      final song = makeFile('Song One.MP3');
      expect(
        parseOpenPaths(<String>[
          '-psn_0_12345',
          '--hidden',
          '/R',
          song.path,
        ]),
        <String>[song.path],
      );
    });

    test('resolves relative paths against the working directory', () {
      final song = makeFile('relative.flac');
      expect(
        parseOpenPaths(<String>['relative.flac'], cwd: dir.path),
        <String>[song.path],
      );
    });

    test('strips quotes around absolute paths', () {
      final song = makeFile('quoted.ogg');
      expect(
        parseOpenPaths(<String>['"${song.path}"'], cwd: dir.path),
        <String>[song.path],
      );
    });

    test('deduplicates repeated paths', () {
      final song = makeFile('twice.wav');
      expect(
        parseOpenPaths(<String>[song.path, song.path, song.path]),
        <String>[song.path],
      );
    });

    test('drops missing files and unsupported files', () {
      final notes = makeFile('notes.txt');
      final video = makeFile('clip.mp4');
      expect(
        parseOpenPaths(<String>[
          notes.path,
          video.path,
          '${dir.path}/gone.mp3',
        ]),
        isEmpty,
      );
    });

    test('keeps uppercase extensions', () {
      final song = makeFile('LOUD.FLAC');
      expect(parseOpenPaths(<String>[song.path]), <String>[song.path]);
    });
  });

  group('file URI round trip', () {
    test('encodes and decodes spaces and unicode', () {
      final song = makeFile('Café One.mp3');
      final uri = pathToFileUri(song.path);
      expect(uri.startsWith('file://'), isTrue);
      expect(fileUriToPath(uri), song.path);
    });

    test('decodeOpenUris keeps file URIs and drops others', () {
      final first = makeFile('one.mp3');
      final second = makeFile('two.flac');
      expect(
        decodeOpenUris(<String>[
          pathToFileUri(first.path),
          'https://example.invalid/song.mp3',
          pathToFileUri(second.path),
        ]),
        <String>[first.path, second.path],
      );
    });

    test('malformed file URI yields null', () {
      expect(fileUriToPath('not a uri'), isNull);
      expect(fileUriToPath('https://example.invalid/a.mp3'), isNull);
    });
  });

  group('intent flush', () {
    test('queues pending paths as local files', () async {
      final first = makeFile('First Song.mp3');
      final second = makeFile('Second.flac');
      setPendingOpenPaths(<String>[first.path, second.path, 'ignored.txt']);

      await flushOpenWithIntent(null);

      expect(calls, hasLength(1));
      final call = calls.single;
      expect(call.label, 'Local files');
      expect(call.index, 0);
      expect(call.tracks.map((t) => t.title), <String>['First Song', 'Second']);
      expect(call.tracks.map((t) => t.artist), everyElement('Local file'));
      expect(call.tracks.map((t) => t.playbackUrl),
          <String>[first.path, second.path]);
      expect(pendingOpenPaths, isEmpty);
    });

    test('late handoff queues immediately once flushed', () async {
      await flushOpenWithIntent(null);
      final song = makeFile('Late Night.MP3');

      await enqueueOpenPaths(<String>[song.path]);

      expect(calls, hasLength(1));
      expect(calls.single.tracks.single.title, 'Late Night');
      expect(calls.single.label, 'Local files');
      expect(pendingOpenPaths, isEmpty);
    });

    test('unsupported paths are not queued', () async {
      await enqueueOpenPaths(<String>['${dir.path}/clip.mp4']);
      expect(calls, isEmpty);
    });
  });

  group('run mode', () {
    test('handoff when a running instance accepts', () async {
      if (!Platform.isLinux && !Platform.isWindows) return;
      final song = makeFile('handoff.mp3');
      final platform = _FakePlatform(acceptHandoff: true);

      final decision =
          await decideRunMode(<String>[song.path], platform: platform);

      expect(decision, isA<Handoff>());
      expect(decision.paths, <String>[song.path]);
      expect(platform.handoffs.single, <String>[song.path]);
      expect(platform.ownerStarted, isFalse);
    });

    test('proceed and serve when no instance owns the app', () async {
      if (!Platform.isLinux && !Platform.isWindows) return;
      final song = makeFile('boot.mp3');
      final platform = _FakePlatform();

      final decision =
          await decideRunMode(<String>[song.path], platform: platform);

      expect(decision, isA<Proceed>());
      expect(decision.paths, <String>[song.path]);
      expect(platform.ownerStarted, isTrue);
      expect(platform.onOpen, isNotNull);
      expect(platform.onFocus, isNotNull);
    });
  });

  group('windows pipe payload', () {
    test('round trips absolute paths as CRLF lines', () {
      final paths = <String>[
        r'C:\Music\Artist\One.mp3',
        r'C:\Music\Other\Two.flac',
      ];
      final text = encodeWindowsOpenPipePayload(paths);
      expect(text, '${paths[0]}\r\n${paths[1]}\r\n');
      final decoded = decodeWindowsOpenPipePayload(text);
      expect(decoded.paths, paths);
      expect(decoded.focusRequested, isFalse);
    });

    test('focus request is a lone dot line', () {
      final text = encodeWindowsOpenPipePayload(const <String>[], focus: true);
      expect(text, '.\r\n');
      final decoded = decodeWindowsOpenPipePayload(text);
      expect(decoded.paths, isEmpty);
      expect(decoded.focusRequested, isTrue);
      expect(decoded.isEmpty, isFalse);
    });

    test('paths and focus marker coexist', () {
      final decoded = decodeWindowsOpenPipePayload(
          'C:\\Music\\One.mp3\r\n.\r\n');
      expect(decoded.paths, <String>[r'C:\Music\One.mp3']);
      expect(decoded.focusRequested, isTrue);
    });

    test('wire bytes are UTF-8', () {
      final bytes = encodeWindowsOpenPipeBytes(const <String>[
        r'C:\Música\夜.mp3',
      ]);
      expect(utf8.decode(bytes), r'C:\Música\夜.mp3' '\r\n');
    });

    test('blank and CR-less lines decode the same', () {
      final decoded =
          decodeWindowsOpenPipePayload('\r\nA.mp3\r\n\r\nB.flac\r\n');
      expect(decoded.paths, <String>['A.mp3', 'B.flac']);
      expect(decoded.focusRequested, isFalse);
    });

    test('identifiers match the packaging contract', () {
      expect(windowsMutexName, 'aubade.handoff.mutex');
      expect(windowsPipeName, r'\\.\pipe\aubade.handoff');
      expect(windowsFocusMarker, '.');
    });
  });

  group('launch services channel', () {
    test('files method queues raw paths', () async {
      final song = makeFile('Channel Song.mp3');

      await handleOpenWithChannelCall(
          MethodCall(openWithChannelMethod, <String>[song.path]));

      expect(calls, hasLength(1));
      expect(calls.single.tracks.single.playbackUrl, song.path);
      expect(calls.single.tracks.single.title, 'Channel Song');
      expect(calls.single.label, 'Local files');
    });

    test('paths wait for the boot flush before playback is warm', () async {
      final sink = debugOpenWithQueueSink;
      debugOpenWithQueueSink = null;
      final song = makeFile('Boot Channel.flac');

      await handleOpenWithChannelCall(
          MethodCall(openWithChannelMethod, <String>[song.path]));

      expect(calls, isEmpty);
      expect(pendingOpenPaths, <String>[song.path]);

      debugOpenWithQueueSink = sink;
      await flushOpenWithIntent(null);

      expect(calls, hasLength(1));
      expect(calls.single.tracks.single.playbackUrl, song.path);
      expect(pendingOpenPaths, isEmpty);
    });

    test('ignores unknown methods and malformed arguments', () async {
      final song = makeFile('Ignored.mp3');

      await handleOpenWithChannelCall(
          MethodCall('activate', <String>[song.path]));
      await handleOpenWithChannelCall(MethodCall('files', 'not a list'));
      await handleOpenWithChannelCall(
          MethodCall('files', <Object>[1, true, '']));

      expect(calls, isEmpty);
      expect(pendingOpenPaths, isEmpty);
    });

    test('registered channel decodes a native files call', () async {
      final song = makeFile('Native Flush.mp3');
      registerOpenWithChannel();
      const codec = StandardMethodCodec();

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        openWithChannelName,
        codec.encodeMethodCall(
            MethodCall(openWithChannelMethod, <String>[song.path])),
        null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(calls, hasLength(1));
      expect(calls.single.tracks.single.playbackUrl, song.path);
      expect(calls.single.label, 'Local files');
    });
  });

  final hasSessionBus =
      Platform.environment['DBUS_SESSION_BUS_ADDRESS'] != null;

  group('linux dbus handoff', () {
    test('owner accepts file URIs and decodes them to raw paths', () async {
      if (!Platform.isLinux) return;

      // Never steal the name from a real running Aubade.
      DBusClient? probe;
      try {
        probe = DBusClient.session();
        if (await probe.nameHasOwner(openWithBusName)) return;
      } finally {
        try {
          await probe?.close();
        } catch (_) {}
      }

      addTearDown(shutdownOpenWithOwner);
      final platform = defaultOpenWithPlatform();
      await platform.startOwner(
        onOpen: enqueueOpenPaths,
        onFocus: () {},
      );
      final song = makeFile('dbus one.MP3');

      final accepted = await platform.tryHandOff(<String>[song.path]);
      expect(accepted, isTrue);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (calls.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(calls, hasLength(1));
      expect(calls.single.tracks.single.playbackUrl, song.path);
      expect(calls.single.tracks.single.title, 'dbus one');
      expect(calls.single.label, 'Local files');

      await shutdownOpenWithOwner();
    }, skip: hasSessionBus ? false : 'no session bus in this environment');
  }, skip: hasSessionBus ? false : 'no session bus in this environment');
}
