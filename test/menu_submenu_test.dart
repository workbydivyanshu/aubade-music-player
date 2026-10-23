import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/features/library/playlists.dart';
import 'package:aubade/ui/components/menus.dart';

Future<void> _pumpPanel(WidgetTester tester, List<WaveMenuEntry> entries) async {
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    FluentApp(
      themeMode: ThemeMode.dark,
      home: ScaffoldPage(
        content: Center(
          child: SizedBox(
            width: 260,
            child: WaveFlyoutPanel.items(entries: entries),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Builds the real "Add to playlist" entry against [repo] and hands back
/// the submenu with the rows it would cascade.
Future<(WaveMenuSubmenu, List<WaveMenuEntry>)> _playlistRows(
  WidgetTester tester,
  PlaylistRepository repo,
) async {
  WaveMenuSubmenu? entry;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playlistRepositoryProvider.overrideWith((ref) => repo),
      ],
      child: FluentApp(
        themeMode: ThemeMode.dark,
        home: Consumer(
          builder: (context, ref, _) {
            entry ??= waveAddToPlaylistEntry(
              context: context,
              ref: ref,
              playlists: ref.watch(playlistRepositoryProvider),
              track: const StoredTrack(name: 'Song', artist: 'Artist'),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (entry!, entry!.items());
}

/// Hovers a submenu row and settles its nested panel open.
Future<void> _hoverRow(WidgetTester tester, Finder row) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();

  await gesture.moveTo(tester.getCenter(row));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a library of only Liked Songs still offers a way to add one', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = PlaylistRepository(db);
    await repo.ensureLikedSongs();

    final (_, rows) = await _playlistRows(tester, repo);
    final labels = rows.whereType<WaveMenuAction>().map((a) => a.label);

    // The submenu is present and non-empty with zero custom playlists.
    expect(labels, isNotEmpty);
    expect(labels, contains('New playlist…'));
    // Aubade keeps its Liked Songs row as a filing target.
    expect(labels, contains(SavedPlaylist.likedTitle));
  });

  testWidgets('the create row leads, then the existing playlists', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = PlaylistRepository(db);
    await repo.ensureLikedSongs();
    // Inserted directly: two repository writes stamp the same frozen
    // epoch-millisecond id under the test clock and collide on the key.
    db.raw.execute(
      'INSERT INTO saved_playlists(id, title, mode, tracks_json, created_at_millis) '
      'VALUES(?, ?, ?, ?, ?);',
      [1, 'Chill', 'custom', '[]', 2],
    );
    repo.refresh();

    final (_, rows) = await _playlistRows(tester, repo);
    final labels =
        rows.whereType<WaveMenuAction>().map((a) => a.label).toList();

    // Liked Songs is pinned first in the repository's own ordering.
    expect(labels, ['New playlist…', SavedPlaylist.likedTitle, 'Chill']);
  });

  testWidgets('creating a playlist from the entry files the track in it', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = PlaylistRepository(db);
    await repo.ensureLikedSongs();

    final (entry, _) = await _playlistRows(tester, repo);
    final create = entry
        .items()
        .whereType<WaveMenuAction>()
        .firstWhere((a) => a.label == 'New playlist…');
    create.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('New playlist'), findsOneWidget);
    await tester.enterText(find.byType(TextBox), 'Gym');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final gym = repo.state.firstWhere((p) => p.title == 'Gym');
    expect(gym.tracks.single.name, 'Song');
    expect(gym.tracks.single.artist, 'Artist');
  });

  testWidgets('hovering a submenu row opens its nested panel', (tester) async {
    await _pumpPanel(tester, [
      WaveMenuAction(label: 'Play', onPressed: () {}),
      WaveMenuSubmenu(
        label: 'Add to playlist',
        items: () => [
          WaveMenuAction(label: 'Chill', onPressed: () {}),
          WaveMenuAction(label: 'Focus', onPressed: () {}),
        ],
      ),
    ]);

    await _hoverRow(tester, find.text('Add to playlist'));

    expect(find.text('Chill'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
  });

  testWidgets('a submenu with no entries has nothing to show', (tester) async {
    await _pumpPanel(tester, [
      WaveMenuSubmenu(label: 'Add to playlist', items: () => const []),
    ]);

    await _hoverRow(tester, find.text('Add to playlist'));

    // The row itself is still there; nothing else is.
    expect(find.text('Add to playlist'), findsOneWidget);
  });
}
