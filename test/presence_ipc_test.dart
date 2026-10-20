import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/features/player/player_state.dart';
import 'package:aubade/features/presence/discord_ipc.dart';
import 'package:aubade/features/presence/discord_presence_service.dart';

/// Single-subscription frame reader: one listener, buffered takes.
class _Reader {
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<void>> _waiters = [];
  late final StreamSubscription<List<int>> _sub;
  bool _done = false;

  _Reader(Stream<List<int>> stream) {
    _sub = stream.listen((chunk) {
      _buf.add(chunk);
      for (final w in _waiters.toList()) {
        if (!w.isCompleted) w.complete();
      }
      _waiters.clear();
    }, onError: (_) => _finish(), onDone: _finish);
  }

  void _finish() {
    _done = true;
    for (final w in _waiters.toList()) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> read(int n) async {
    final deadline =
        DateTime.now().add(const Duration(seconds: 5));
    while (_buf.length < n) {
      if (_done || DateTime.now().isAfter(deadline)) {
        return Uint8List(0);
      }
      final w = Completer<void>();
      _waiters.add(w);
      try {
        await w.future.timeout(const Duration(seconds: 5));
      } catch (_) {
        return Uint8List(0);
      }
    }
    final all = _buf.toBytes();
    _buf.clear();
    if (all.length > n) _buf.add(all.sublist(n));
    return all.sublist(0, n);
  }

  Future<void> close() async {
    try {
      await _sub.cancel();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

PlayableTrack _track({
  String title = 'Test Song',
  String artist = 'Test Artist',
  String album = 'Test Album',
  String artworkUrl = '',
}) =>
    PlayableTrack(
      title: title,
      artist: artist,
      album: album,
      artworkUrl: artworkUrl,
    );

PlayerSnapshot _snap(PlayableTrack track,
        {bool isPlaying = true,
        Duration position = const Duration(seconds: 10),
        Duration duration = const Duration(seconds: 200)}) =>
    PlayerSnapshot(
      current: track,
      isPlaying: isPlaying,
      position: position,
      duration: duration,
    );

final _now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

// ---------------------------------------------------------------------------
// Frame codec + candidate pins (kept from the original transport probes)
// ---------------------------------------------------------------------------

void main() {
  test('frame codec round-trips', () {
    final payload = <String, Object?>{
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': 1234, 'activity': null},
      'nonce': '1',
    };
    final frame = DiscordIpc.encodeFrame(1, payload);
    final view = ByteData.sublistView(frame);
    expect(view.getInt32(0, Endian.little), 1);
    expect(view.getInt32(4, Endian.little), frame.length - 8);
    final back =
        DiscordIpc.decodeFrame(frame.sublist(8));
    expect(back?['cmd'], 'SET_ACTIVITY');
    expect((back?['args'] as Map)['pid'], 1234);
  });

  test('socket candidates include the runtime dir', () {
    final paths = DiscordIpc.socketCandidates();
    expect(paths, isNotEmpty);
    expect(paths.any((p) => p.endsWith('/discord-ipc-0')), isTrue);
  });

  // ---------------------------------------------------------------------------
  // Activity payload pins: the daemon's activityFor mapping
  // ---------------------------------------------------------------------------

  test('full snapshot maps like the daemon', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(artworkUrl: 'https://cdn.example/cover.jpg'),
      _snap(_track(artworkUrl: 'https://cdn.example/cover.jpg')),
      _now,
    );
    expect(activity?['details'], 'Test Artist - Test Song');
    expect(activity?['state'], 'Test Album');
    expect(activity?['type'], 2);
    final ts = activity?['timestamps'] as Map;
    // Start-only timestamp, seconds since epoch, back-dated by position.
    expect(ts.keys, ['start']);
    expect(ts['start'], _now.millisecondsSinceEpoch ~/ 1000 - 10);
    final assets = activity?['assets'] as Map;
    expect(assets['large_image'], 'https://cdn.example/cover.jpg');
    expect(assets['large_text'], 'Test Album');
    // Daemon shape: no buttons, no small asset, no instance flag.
    expect(activity?.containsKey('buttons'), isFalse);
    expect(assets.containsKey('small_image'), isFalse);
    expect(activity?.containsKey('instance'), isFalse);
  });

  test('missing artist falls back to the bare title', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'Solo', artist: '', album: 'A'),
      _snap(_track(title: 'Solo', artist: '', album: 'A')),
      _now,
    );
    expect(activity?['details'], 'Solo');
  });

  test('missing album omits the state line while playing', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'T', artist: 'A', album: ''),
      _snap(_track(title: 'T', artist: 'A', album: '')),
      _now,
    );
    expect(activity?.containsKey('state'), isFalse);
  });

  test('pause drops timestamps and words the pause', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(),
      _snap(_track(), isPlaying: false),
      _now,
    );
    expect(activity?.containsKey('timestamps'), isFalse);
    expect(activity?['state'], 'Paused - Test Album');
  });

  test('pause without an album still says Paused', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'T', artist: 'A', album: ''),
      _snap(_track(title: 'T', artist: 'A', album: ''), isPlaying: false),
      _now,
    );
    expect(activity?['state'], 'Paused');
  });

  test('blob: and file: art fall back to the logo asset', () {
    for (final art in <String>[
      'blob:http://localhost:5199/abc',
      'file:///home/user/cover.png',
    ]) {
      final activity = DiscordPresenceService.buildActivity(
        _track(artworkUrl: art),
        _snap(_track(artworkUrl: art)),
        _now,
      );
      expect((activity?['assets'] as Map)['large_image'], 'logo',
          reason: art);
    }
  });

  test('oversized fields clip at 128 characters', () {
    final long = 'x' * 200;
    final activity = DiscordPresenceService.buildActivity(
      _track(title: long, artist: 'A', album: 'Al'),
      _snap(_track(title: long, artist: 'A', album: 'Al')),
      _now,
    );
    expect((activity?['details'] as String).length, 128);
    // Playing snapshot keeps its start-only timestamps.
    expect(activity?['timestamps'], isA<Map>());
  });

  test('no title means no activity', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: '', artist: '', album: ''),
      _snap(_track(title: '', artist: '', album: ''), isPlaying: false),
      _now,
    );
    expect(activity, isNull);
  });

  // ---------------------------------------------------------------------------
  // Push gating: throttle, self-heal refresh, rate-limit backoff
  // ---------------------------------------------------------------------------

  test('shouldPush gates pushes like the daemon', () {
    final now = DateTime.now();
    // First ever push goes out.
    expect(
        DiscordPresenceService.shouldPush(
            changed: true, lastPush: null, backoffUntil: null, now: now),
        isTrue);
    // A new track within the 5s throttle waits.
    final fresh = now.subtract(const Duration(seconds: 2));
    expect(
        DiscordPresenceService.shouldPush(
            changed: true, lastPush: fresh, backoffUntil: null, now: now),
        isFalse);
    // Unchanged presence re-pushes only at the 15s self-heal.
    expect(
        DiscordPresenceService.shouldPush(
            changed: false, lastPush: fresh, backoffUntil: null, now: now),
        isFalse);
    expect(
        DiscordPresenceService.shouldPush(
            changed: false,
            lastPush: now.subtract(const Duration(seconds: 16)),
            backoffUntil: null,
            now: now),
        isTrue);
    // Past 5s a track change is allowed; so is an unchanged re-push.
    expect(
        DiscordPresenceService.shouldPush(
            changed: true,
            lastPush: now.subtract(const Duration(seconds: 6)),
            backoffUntil: null,
            now: now),
        isTrue);
    // A rate-limit reply blocks everything until the backoff expires.
    final limited = now.add(const Duration(seconds: 20));
    expect(
        DiscordPresenceService.shouldPush(
            changed: true, lastPush: null, backoffUntil: limited, now: now),
        isFalse);
    expect(
        DiscordPresenceService.shouldPush(
            changed: true,
            lastPush: null,
            backoffUntil: now.subtract(const Duration(seconds: 1)),
            now: now),
        isTrue);
  });

  // ---------------------------------------------------------------------------
  // Rate-limit reply sniffing
  // ---------------------------------------------------------------------------

  test('rate-limit replies are caught, acks are not', () {
    expect(
        DiscordIpc.replyIndicatesRateLimit(
            {'cmd': 'SET_ACTIVITY', 'data': {'code': 429, 'message': 'x!'}, 'evt': null}),
        isTrue);
    expect(
        DiscordIpc.replyIndicatesRateLimit(
            {'cmd': 'SET_ACTIVITY', 'data': {'message': 'Rate limited!'}, 'evt': null}),
        isTrue);
    expect(
        DiscordIpc.replyIndicatesRateLimit(
            {'cmd': 'SET_ACTIVITY', 'data': null, 'evt': null}),
        isFalse);
    expect(DiscordIpc.replyIndicatesRateLimit(null), isFalse);
  });

  // ---------------------------------------------------------------------------
  // Live transport against a fake Discord pipe
  // ---------------------------------------------------------------------------

  test(
    'unix socket handshake loopback',
    () async {
      final dir =
          await Directory.systemTemp.createTemp('discord_ipc_test');
      try {
        final path = '${dir.path}/discord-ipc-9';
        final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        try {
          // Fake Discord: read one handshake frame, reply READY.
          server.listen((client) async {
            final reader = _Reader(client);
            try {
              final header = await reader.read(8);
              expect(header.length, 8);
              final len = ByteData.sublistView(header)
                  .getInt32(4, Endian.little);
              final body = await reader.read(len);
              final req = DiscordIpc.decodeFrame(body);
              expect(req?['client_id'], 'probe-id');
              client.add(DiscordIpc.encodeFrame(
                  1, {'evt': 'READY', 'data': {}}));
            } finally {
              await reader.close();
            }
          });

          final client = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
            timeout: const Duration(seconds: 5),
          );
          final reader = _Reader(client);
          try {
            client.add(DiscordIpc.encodeFrame(
                0, {'v': 1, 'client_id': 'probe-id'}));
            final header = await reader.read(8);
            expect(header.length, 8);
            final len = ByteData.sublistView(header)
                .getInt32(4, Endian.little);
            final body = await reader.read(len);
            expect(
                DiscordIpc.decodeFrame(body)?['evt'], 'READY');
          } finally {
            await reader.close();
            client.destroy();
          }
        } finally {
          await server.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'real transport sends a valid SET_ACTIVITY past a reply flood',
    () async {
      final dir =
          await Directory.systemTemp.createTemp('discord_ipc_flow');
      try {
        final path = '${dir.path}/discord-ipc-8';
        final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        final seen = <Map<String, Object?>>[];
        // Two frames parsed is the handler's finish line; the client's
        // sends complete on pre-flooded acks, so the test must wait on
        // the server side instead of racing it.
        final bothSeen = Completer<void>();
        try {
          server.listen((client) async {
            final reader = _Reader(client);
            try {
              // Handshake in, READY out.
              final head = await reader.read(8);
              await reader.read(
                  ByteData.sublistView(head).getInt32(4, Endian.little));
              client.add(DiscordIpc.encodeFrame(
                  1, {'evt': 'READY', 'data': {}}));
              // Flood replies so a client that never reads them would
              // back up badly.
              for (var i = 0; i < 60; i++) {
                client.add(DiscordIpc.encodeFrame(1,
                    {'cmd': 'SET_ACTIVITY', 'data': null, 'evt': null}));
              }
              // Two SET_ACTIVITY frames, captured + validated inline.
              for (var i = 0; i < 2; i++) {
                final fhead = await reader.read(8);
                expect(fhead.length, 8);
                final flen = ByteData.sublistView(fhead)
                    .getInt32(4, Endian.little);
                final fbody = await reader.read(flen);
                final frame = DiscordIpc.decodeFrame(fbody);
                expect(frame?['cmd'], 'SET_ACTIVITY');
                final args = frame?['args'] as Map;
                expect(args['pid'], isA<int>());
                final activity = args['activity'] as Map;
                expect(activity['details'], 'Test Artist - Test Song');
                seen.add(frame ?? const {});
              }
              if (!bothSeen.isCompleted) bothSeen.complete();
            } catch (e) {
              if (!bothSeen.isCompleted) bothSeen.completeError(e);
            } finally {
              await reader.close();
            }
          });

          final ipc = await DiscordIpc.connectTo(path, 'probe-id');
          expect(ipc, isNotNull);
          final first = await ipc!.setActivity(
              DiscordPresenceService.buildActivity(
                  _track(), _snap(_track()), _now)!);
          expect(first, DiscordSend.ok);
          final second = await ipc.setActivity(
              DiscordPresenceService.buildActivity(
                  _track(), _snap(_track()), _now)!);
          // Pre-flooded acks get consumed; the next send still reads ok.
          expect(second, DiscordSend.ok);
          await bothSeen.future.timeout(const Duration(seconds: 5));
          expect(seen.length, 2);
          ipc.close();
        } finally {
          await server.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'real transport reports a rate-limited reply',
    () async {
      final dir =
          await Directory.systemTemp.createTemp('discord_ipc_limit');
      try {
        final path = '${dir.path}/discord-ipc-7';
        final server = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        try {
          server.listen((client) async {
            final reader = _Reader(client);
            try {
              final head = await reader.read(8);
              await reader.read(
                  ByteData.sublistView(head).getInt32(4, Endian.little));
              client.add(DiscordIpc.encodeFrame(
                  1, {'evt': 'READY', 'data': {}}));
              final fhead = await reader.read(8);
              await reader.read(
                  ByteData.sublistView(fhead).getInt32(4, Endian.little));
              client.add(DiscordIpc.encodeFrame(2, {
                'data': {'code': 429, 'message': 'Rate limited!'},
              }));
            } finally {
              await reader.close();
            }
          });

          final ipc = await DiscordIpc.connectTo(path, 'probe-id');
          expect(ipc, isNotNull);
          final verdict = await ipc!.setActivity(
              DiscordPresenceService.buildActivity(
                  _track(), _snap(_track()), _now)!);
          expect(verdict, DiscordSend.rateLimited);
          ipc.close();
        } finally {
          await server.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
