import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/core/constants/app_links.dart';
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
    // Start back-dated by position, end at the track's duration.
    expect(ts.keys, ['start', 'end']);
    expect(ts['start'], _now.millisecondsSinceEpoch ~/ 1000 - 10);
    expect(ts['end'], (ts['start'] as int) + 200);
    final assets = activity?['assets'] as Map;
    expect(assets['large_image'], 'https://cdn.example/cover.jpg');
    expect(assets['large_text'], 'Test Album');
    expect(assets['small_image'], 'logo');
    expect(assets['small_text'], 'Aubade');
    // Presence upgrade shape: one site button, no instance flag.
    expect(activity?['buttons'], hasLength(1));
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
  // Presence upgrade: button, timestamps, album dedupe, small image
  // ---------------------------------------------------------------------------

  test('payload carries exactly the site download button', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(artworkUrl: 'https://cdn.example/cover.jpg'),
      _snap(_track(artworkUrl: 'https://cdn.example/cover.jpg')),
      _now,
    );
    final buttons = activity?['buttons'] as List;
    expect(buttons, hasLength(1));
    final button = buttons.single as Map;
    expect(button['label'], 'Get Aubade');
    expect(button['url'], 'https://aubadehq.vercel.app/download');
    expect(button['url'], kLandingDownloadUrl);
    expect(activity.toString().toLowerCase(), isNot(contains('github')));
  });

  test('timestamps end at start plus the track duration', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(),
      _snap(_track(),
          position: const Duration(seconds: 42),
          duration: const Duration(minutes: 3, seconds: 15)),
      _now,
    );
    final ts = activity?['timestamps'] as Map;
    final start = _now.millisecondsSinceEpoch ~/ 1000 - 42;
    expect(ts['start'], start);
    expect(ts['end'], start + 195);
  });

  test('timestamps cap the position at the track duration', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(),
      _snap(_track(),
          position: const Duration(seconds: 300),
          duration: const Duration(seconds: 200)),
      _now,
    );
    final ts = activity?['timestamps'] as Map;
    final start = _now.millisecondsSinceEpoch ~/ 1000 - 200;
    expect(ts['start'], start);
    expect(ts['end'], start + 200);
  });

  test('pause drops start and end together', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(),
      _snap(_track(),
          isPlaying: false,
          position: const Duration(seconds: 42),
          duration: const Duration(minutes: 3)),
      _now,
    );
    expect(activity?.containsKey('timestamps'), isFalse);
    expect(activity?['state'], 'Paused - Test Album');
  });

  test('album equal to the title is dropped while playing', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'Same Name', artist: 'Band', album: 'Same Name'),
      _snap(_track(title: 'Same Name', artist: 'Band', album: 'Same Name')),
      _now,
    );
    expect(activity?.containsKey('state'), isFalse);
    expect((activity?['assets'] as Map)['large_text'], 'Same Name');
  });

  test('album equal to the artist is dropped while playing', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'Song', artist: 'The Band', album: 'The Band'),
      _snap(_track(title: 'Song', artist: 'The Band', album: 'The Band')),
      _now,
    );
    expect(activity?.containsKey('state'), isFalse);
  });

  test('album dedupe trims and ignores case', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'Test Song', artist: 'Test Artist', album: '  test song  '),
      _snap(_track(
          title: 'Test Song', artist: 'Test Artist', album: '  test song  ')),
      _now,
    );
    expect(activity?.containsKey('state'), isFalse);
  });

  test('a normal album stays in the state line', () {
    final activity = DiscordPresenceService.buildActivity(
      _track(title: 'Song', artist: 'Band', album: 'Real Album'),
      _snap(_track(title: 'Song', artist: 'Band', album: 'Real Album')),
      _now,
    );
    expect(activity?['state'], 'Real Album');
  });

  test('one character albums are padded for Discord', () {
    final playing = DiscordPresenceService.buildActivity(
      _track(title: 'Song', artist: 'Band', album: 'X'),
      _snap(_track(title: 'Song', artist: 'Band', album: 'X')),
      _now,
    );
    expect(playing?['state'], 'X ');
    final paused = DiscordPresenceService.buildActivity(
      _track(title: 'Song', artist: 'Band', album: 'X'),
      _snap(_track(title: 'Song', artist: 'Band', album: 'X'),
          isPlaying: false),
      _now,
    );
    expect(paused?['state'], 'Paused - X ');
  });

  test('small logo overlay appears only for http(s) artwork', () {
    for (final art in <String>[
      'https://cdn.example/cover.jpg',
      'http://cdn.example/cover.jpg',
    ]) {
      final activity = DiscordPresenceService.buildActivity(
        _track(artworkUrl: art),
        _snap(_track(artworkUrl: art)),
        _now,
      );
      final assets = activity?['assets'] as Map;
      expect(assets['small_image'], 'logo', reason: art);
      expect(assets['small_text'], 'Aubade', reason: art);
    }
    for (final art in <String>[
      '',
      'blob:http://localhost:5199/abc',
      'file:///home/user/cover.png',
    ]) {
      final activity = DiscordPresenceService.buildActivity(
        _track(artworkUrl: art),
        _snap(_track(artworkUrl: art)),
        _now,
      );
      final assets = activity?['assets'] as Map;
      expect(assets['large_image'], 'logo', reason: art);
      expect(assets.containsKey('small_image'), isFalse, reason: art);
      expect(assets.containsKey('small_text'), isFalse, reason: art);
    }
  });

  test('status_display_type follows the member list pref', () {
    expect(DiscordPresenceService.statusDisplayTypeFor('title'), 2);
    expect(DiscordPresenceService.statusDisplayTypeFor('album'), 3);
    expect(DiscordPresenceService.statusDisplayTypeFor('unknown'), 2);
    final titleMode = DiscordPresenceService.buildActivity(
        _track(), _snap(_track()), _now);
    expect(titleMode?['status_display_type'], 2);
    final albumMode = DiscordPresenceService.buildActivity(
        _track(), _snap(_track()), _now,
        statusDisplayType: DiscordPresenceService.statusDisplayAlbum);
    expect(albumMode?['status_display_type'], 3);
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

  test('seek drift beyond 3s bypasses the throttle', () {
    final now = DateTime.now();
    final justPushed = now.subtract(const Duration(seconds: 1));
    expect(
        DiscordPresenceService.shouldPush(
            changed: false,
            lastPush: justPushed,
            backoffUntil: null,
            now: now,
            driftSeconds: const Duration(seconds: 4)),
        isTrue);
    expect(
        DiscordPresenceService.shouldPush(
            changed: false,
            lastPush: justPushed,
            backoffUntil: null,
            now: now,
            driftSeconds: const Duration(seconds: -4)),
        isTrue);
    expect(
        DiscordPresenceService.shouldPush(
            changed: false,
            lastPush: justPushed,
            backoffUntil: null,
            now: now,
            driftSeconds: const Duration(seconds: 3)),
        isFalse);
    // A changed key keeps the normal 5s throttle even with drift.
    expect(
        DiscordPresenceService.shouldPush(
            changed: true,
            lastPush: justPushed,
            backoffUntil: null,
            now: now,
            driftSeconds: const Duration(seconds: 9)),
        isFalse);
  });

  test('first send is deferred before the track reaches 2s', () {
    expect(
        DiscordPresenceService.shouldDeferFirstSend(
            position: const Duration(milliseconds: 1500),
            keyChanged: false),
        isTrue);
    expect(
        DiscordPresenceService.shouldDeferFirstSend(
            position: const Duration(seconds: 2), keyChanged: false),
        isFalse);
    // A new key takes over immediately, even before 2s.
    expect(
        DiscordPresenceService.shouldDeferFirstSend(
            position: const Duration(milliseconds: 1500),
            keyChanged: true),
        isFalse);
  });

  test('reconnect backoff escalates and resets on success', () {
    final backoff = ReconnectBackoff();
    expect(backoff.delay, const Duration(seconds: 15));
    // First retry after a failure stays at 15s.
    backoff.recordFailure();
    expect(backoff.delay, const Duration(seconds: 15));
    backoff.recordFailure();
    expect(backoff.delay, const Duration(seconds: 25));
    backoff.recordFailure();
    expect(backoff.delay, const Duration(seconds: 40));
    backoff.recordFailure();
    expect(backoff.delay, const Duration(seconds: 40));
    backoff.recordSuccess();
    expect(backoff.delay, const Duration(seconds: 15));
    expect(backoff.failures, 0);
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
