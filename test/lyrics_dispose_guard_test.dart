import 'dart:async';

import 'package:aubade/features/lyrics/lyrics_models.dart';
import 'package:aubade/ui/lyrics/lyrics_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The provider hands its repository fetch to [LyricsStreamGuard]. A fetch
/// can resolve after the provider was disposed, or after the first result
/// already closed the stream, so late writes must be dropped rather than
/// thrown at a dead controller.
void main() {
  group('LyricsStreamGuard', () {
    late StreamController<LyricsResult> controller;
    late LyricsStreamGuard guard;
    late List<LyricsResult> seen;
    late List<Object> errors;
    late StreamSubscription<LyricsResult> subscription;

    setUp(() {
      controller = StreamController<LyricsResult>();
      guard = LyricsStreamGuard(controller);
      seen = <LyricsResult>[];
      errors = <Object>[];
      subscription = controller.stream.listen(seen.add, onError: errors.add);
    });

    tearDown(() async {
      await subscription.cancel();
    });

    test('a resolve after dispose does not emit or throw', () async {
      final pending = Completer<LyricsResult>();
      final fetch = pending.future
          .then(guard.emit, onError: guard.fail)
          .whenComplete(guard.finish);

      guard.dispose();
      pending.complete(const LyricsResult.empty());
      await fetch;
      await pumpEventQueue();

      expect(seen, isEmpty);
      expect(errors, isEmpty);
      expect(guard.isClosed, isTrue);
    });

    test('a result after the stream closed is dropped', () async {
      guard.emit(const LyricsResult.empty());
      guard.finish();

      // Simulates a second fetch finishing after the first one closed.
      guard.emit(const LyricsResult(source: 'lrclib'));
      guard.fail(StateError('late failure'), StackTrace.empty);
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(errors, isEmpty);
      expect(guard.isClosed, isTrue);
    });
  });
}
