import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aubade/core/artwork/official_artwork_service.dart';
import 'package:aubade/core/audio/stream_models.dart';
import 'package:aubade/core/network/lastfm_api.dart';
import 'package:aubade/core/network/rate_guard.dart';
import 'package:aubade/core/storage/app_database.dart';
import 'package:aubade/core/storage/prefs.dart';
import 'package:aubade/core/storage/secure_store.dart';
import 'package:aubade/features/addons/addon_api.dart';
import 'package:aubade/features/downloads/download_manager.dart';
import 'package:aubade/features/innertube/innertube_api.dart';
import 'package:aubade/features/lastfm/scrobble_repository.dart';
import 'package:aubade/features/lyrics/lyrics_repository.dart';
import 'package:aubade/features/search/shared_providers.dart'
    show databaseProvider;
import 'package:aubade/features/player/playback_service.dart';
import 'package:aubade/ui/components/desktop_table.dart';

/// Header-sort contracts of [WaveDesktopTable]:
/// - Uncontrolled callers keep their internal 2-state cycle (rows
///   reorder; a second tap on the same header flips direction) —
///   behaviour unchanged by the controlled-mode addition.
/// - Controlled callers (`onHeaderSort`) stop owning sort state: taps
///   only report the column, and row order follows the parent's
///   pass-through feed rather than any internal comparison.
class _Row {
  final String key, title, artist;
  const _Row(this.key, this.title, this.artist);
}

class _Harness extends StatelessWidget {
  final Prefs prefs;
  final AppDatabase db;
  final PlaybackService service;
  final List<_Row> items;
  final int? controlledSortCol;
  final WaveSortDir? controlledSortDir;
  final void Function(int col)? onHeaderSort;
  const _Harness({
    required this.prefs,
    required this.db,
    required this.service,
    required this.items,
    this.controlledSortCol,
    this.controlledSortDir,
    this.onHeaderSort,
  });

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        playbackServiceProvider.overrideWith((ref) => service),
      ],
      child: FluentApp(
        home: ScaffoldPage(
          content: WaveDesktopTable<_Row>(
            items: items,
            keyOf: (t) => t.key,
            titleOf: (t) => t.title,
            subtitleOf: (t) => t.artist,
            albumOf: (_) => '',
            artworkOf: (_) => '',
            playableOf: (t) => PlayableTrack(title: t.title, artist: t.artist),
            onPlay: (_) {},
            titleSortOf: (t) => t.title.toLowerCase(),
            artistSortOf: (t) => t.artist.toLowerCase(),
            onHeaderSort: onHeaderSort,
            controlledSortCol: controlledSortCol,
            controlledSortDir: controlledSortDir,
          ),
        ),
      ),
    );
  }
}

const _rows = [
  _Row('a', 'Beta', 'Zed'),
  _Row('b', 'alpha', 'Marx'),
  _Row('c', 'Gamma', 'Apple'),
];

void main() {
  late Prefs prefs;
  late AppDatabase db;
  late PlaybackService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    final dio = Dio();
    final tube = InnerTubeMusicApi(dio, SecureStore());
    final lossless = AddonApi(const []);
    final scrobbler = ScrobbleRepository(
      LastFmApiService(dio, LastFmRateGuard()),
      prefs,
      db,
    );
    final downloads = DownloadManager(
      db,
      prefs,
      lossless,
      tube,
      LyricsRepository(dio),
    );
    service = PlaybackService(
      tube,
      lossless,
      scrobbler,
      downloads,
      PrefsHandle(prefs),
      SessionStore(db),
      OfficialArtworkService(),
    );
  });

  testWidgets('uncontrolled: header tap cycles asc then desc', (tester) async {
    await tester.pumpWidget(
      _Harness(prefs: prefs, db: db, service: service, items: _rows),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('TITLE'));
    await tester.pumpAndSettle();
    // asc: lowest title owns the first row.
    expect(find.text('alpha'), findsOneWidget);

    await tester.tap(find.text('TITLE'));
    await tester.pumpAndSettle();
    // Second tap on the same header flips the direction.
    expect(find.text('Zed'), findsOneWidget);
    await service.disposePlayer();
  });

  testWidgets('controlled: taps report only the column, twice', (tester) async {
    var taps = <int>[];
    await tester.pumpWidget(
      _Harness(
        prefs: prefs,
        db: db,
        service: service,
        items: _rows,
        onHeaderSort: (col) => taps.add(col),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('TITLE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ARTIST'));
    await tester.pumpAndSettle();
    expect(taps, [0, 1]);
    await service.disposePlayer();
  });

  testWidgets('controlled: rows follow the parent feed, no internal sort', (
    tester,
  ) async {
    // The parent owns the order (it already applied its persisted
    // sort). A controlled col/dir must not make the table re-sort.
    await tester.pumpWidget(
      _Harness(
        prefs: prefs,
        db: db,
        service: service,
        items: _rows,
        controlledSortCol: 1,
        controlledSortDir: WaveSortDir.desc,
      ),
    );
    await tester.pumpAndSettle();
    // Source order unchanged; internal artist sorting would start
    // with a different row.
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    await service.disposePlayer();
  });
}
