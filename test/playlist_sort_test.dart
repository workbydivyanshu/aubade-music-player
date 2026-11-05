import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/ui/collections/playlist_detail_page.dart';

/// Per-playlist sort persistence: the `aubade_playlist_sort_<id>` key
/// holds `mode:asc|desc`; corrupt or unknown values fall back to the
/// default selection so a read always succeeds before the first frame.
void main() {
  group('PlaylistSortPreference storage', () {
    test('round-trips all six selections', () {
      for (final p in [
        const PlaylistSortPreference(),
        const PlaylistSortPreference(direction: PlaylistSortDirection.desc),
        const PlaylistSortPreference(mode: PlaylistSortMode.title),
        const PlaylistSortPreference(
          mode: PlaylistSortMode.title,
          direction: PlaylistSortDirection.desc,
        ),
        const PlaylistSortPreference(mode: PlaylistSortMode.artist),
        const PlaylistSortPreference(
          mode: PlaylistSortMode.artist,
          direction: PlaylistSortDirection.desc,
        ),
      ]) {
        expect(
          PlaylistSortPreference.fromStorage(p.storageValue),
          p,
          reason: 'storageValue ${p.storageValue} must round-trip',
        );
      }
    });

    test('unknown or missing values resolve to defaults', () {
      expect(
        PlaylistSortPreference.fromStorage(null),
        PlaylistSortPreference.defaults,
      );
      expect(
        PlaylistSortPreference.fromStorage('duration:asc'),
        PlaylistSortPreference.defaults,
      );
      expect(
        PlaylistSortPreference.fromStorage('default:ascending'),
        PlaylistSortPreference.defaults,
      );
      expect(
        PlaylistSortPreference.fromStorage('garbage'),
        PlaylistSortPreference.defaults,
      );
    });
  });

  group('Prefs.playlistSort', () {
    test('persists independently per playlist id', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Prefs(await SharedPreferences.getInstance());

      expect(
        prefs.playlistSort(3),
        PlaylistSortPreference.defaults,
        reason: 'nothing stored yet',
      );

      await prefs.setPlaylistSort(
        3,
        const PlaylistSortPreference(
          mode: PlaylistSortMode.title,
          direction: PlaylistSortDirection.desc,
        ),
      );
      await prefs.setPlaylistSort(
        7,
        const PlaylistSortPreference(mode: PlaylistSortMode.artist),
      );

      expect(
        prefs.playlistSort(3),
        const PlaylistSortPreference(
          mode: PlaylistSortMode.title,
          direction: PlaylistSortDirection.desc,
        ),
      );
      expect(
        prefs.playlistSort(7),
        const PlaylistSortPreference(mode: PlaylistSortMode.artist),
      );
      expect(prefs.playlistSort(9), PlaylistSortPreference.defaults);
    });

    test('raw key/value contract is mode:asc|desc for one id', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Prefs(await SharedPreferences.getInstance());

      await prefs.setPlaylistSort(
        12,
        const PlaylistSortPreference(
          mode: PlaylistSortMode.artist,
          direction: PlaylistSortDirection.desc,
        ),
      );

      expect(
        (await SharedPreferences.getInstance()).get('aubade_playlist_sort_12'),
        'artist:desc',
      );
    });

    test('survives corrupt storage without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'aubade_playlist_sort_42': ';;broken',
      });
      final prefs = Prefs(await SharedPreferences.getInstance());
      expect(prefs.playlistSort(42), PlaylistSortPreference.defaults);
    });
  });

  group('playlist sort UI contract', () {
    test('six options carry the six dropdown labels', () {
      expect(playlistSortOptions, hasLength(6));
      final labels = [
        for (final p in playlistSortOptions) playlistSortOptionLabel(p),
      ];
      expect(labels, [
        'Default order',
        'Reverse default order',
        'Title A–Z',
        'Title Z–A',
        'Artist A–Z',
        'Artist Z–A',
      ]);
      expect(labels.toSet(), hasLength(6), reason: 'labels are unique');
    });

    test('header cycle: new column asc, same column flips, unknown col +', () {
      const def = PlaylistSortPreference();
      expect(
        nextPlaylistSortOnHeader(def, 0),
        const PlaylistSortPreference(mode: PlaylistSortMode.title),
      );
      expect(
        nextPlaylistSortOnHeader(
          const PlaylistSortPreference(mode: PlaylistSortMode.title),
          0,
        ),
        const PlaylistSortPreference(
          mode: PlaylistSortMode.title,
          direction: PlaylistSortDirection.desc,
        ),
      );
      expect(
        nextPlaylistSortOnHeader(
          const PlaylistSortPreference(mode: PlaylistSortMode.artist),
          0,
        ),
        const PlaylistSortPreference(mode: PlaylistSortMode.title),
      );
      // Tapping #/Added (non-sortable in playlists) keeps the selection.
      expect(nextPlaylistSortOnHeader(def, 2), PlaylistSortPreference.defaults);
    });

    test('default order keeps source order, reversal reverses it', () {
      final list = ['one', 'two', 'three'].toList();
      applyPlaylistSort(
        list,
        const PlaylistSortPreference(),
        titleOf: (s) => s,
        artistOf: (s) => s,
      );
      expect(list, ['one', 'two', 'three']);

      applyPlaylistSort(
        list,
        const PlaylistSortPreference(direction: PlaylistSortDirection.desc),
        titleOf: (s) => s,
        artistOf: (s) => s,
      );
      expect(list, ['three', 'two', 'one']);
    });

    test('title sort is case-insensitive with stable source ties', () {
      final list = [
        const _Named('b1', 'banana', ''),
        const _Named('a1', 'Apple', ''),
        const _Named('b2', 'banana', ''),
      ].map((e) => e).toList();
      applyPlaylistSort(
        list,
        const PlaylistSortPreference(mode: PlaylistSortMode.title),
        titleOf: (t) => t.title,
        artistOf: (t) => t.artist,
      );
      expect(list.map((t) => t.id).toList(), [
        'a1',
        'b1',
        'b2',
      ], reason: 'case-insensitive order, ties in source order');

      applyPlaylistSort(
        list,
        const PlaylistSortPreference(
          mode: PlaylistSortMode.title,
          direction: PlaylistSortDirection.desc,
        ),
        titleOf: (t) => t.title,
        artistOf: (t) => t.artist,
      );
      expect(list.map((t) => t.id).toList(), [
        'b1',
        'b2',
        'a1',
      ], reason: 'desc reverses comparison but ties stay in source order');
    });
  });
}

class _Named {
  final String id, title, artist;
  const _Named(this.id, this.title, this.artist);
}
