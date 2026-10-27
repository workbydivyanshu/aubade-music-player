import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/features/player/playback_service.dart';

// The queue entry is what the player re-resolves and what the panel
// menus read, so a resolved catalog row's album and length have to land
// on it. The lossless matcher also uses the length to tell the album cut
// from a radio edit; a row that starts at zero would lose that gate.

void main() {
  group('queue entry resolved metadata', () {
    test('a catalog resolve fills album and length the row lacked', () {
      const queued = PlayableTrack(
        title: 'Besharmi Ki Height',
        artist: 'Benny Dayal',
      );

      final resolved = playableWithResolvedMetadata(
        queued,
        album: 'Main Tera Hero',
        durationSeconds: 289,
      );

      expect(resolved.album, 'Main Tera Hero');
      expect(resolved.durationSeconds, 289);
      expect(resolved.title, queued.title);
      expect(resolved.artist, queued.artist);
    });

    test('the source row wins over a resolver guess', () {
      const queued = PlayableTrack(
        title: 'Subha Hone Na De',
        artist: 'Pritam',
        album: 'Desi Boyz',
        durationSeconds: 289,
      );

      final resolved = playableWithResolvedMetadata(
        queued,
        album: 'Radio Edit',
        durationSeconds: 201,
      );

      expect(resolved.album, 'Desi Boyz');
      expect(resolved.durationSeconds, 289);
      expect(identical(resolved, queued), isTrue);
    });

    test('a zero length never rewrites a known one', () {
      const queued = PlayableTrack(
        title: 'Besharmi Ki Height',
        artist: 'Benny Dayal',
        durationSeconds: 289,
      );

      final resolved = playableWithResolvedMetadata(queued);

      expect(resolved.durationSeconds, 289);
      expect(identical(resolved, queued), isTrue);
    });
  });
}
