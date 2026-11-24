/// Riverpod wiring for the local library: watched music folders,
/// scan state, and track/album/artist projections from AppDatabase.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart';
import 'folder_watcher.dart';
import 'local_scanner.dart';
import 'local_track.dart';

/// Default watched folder when nothing has been persisted yet.
///
/// Resolved from the current user's home, never a hardcoded
/// `/home/<someone>/Music`: packed builds run on machines whose user is
/// not the packager.
String get _defaultMusicFolder {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (home.trim().isEmpty) return '';
  return p.join(home, 'Music');
}

/// Watched music folders. Initialised from [Prefs.musicFolders]; when
/// nothing is stored and the default folder exists on disk, it is
/// seeded (but not persisted) as the only entry.
final musicFoldersProvider = StateNotifierProvider<MusicFoldersNotifier,
    List<String>>((ref) {
  return MusicFoldersNotifier(ref.watch(prefsProvider));
});

class MusicFoldersNotifier extends StateNotifier<List<String>> {
  MusicFoldersNotifier(Prefs prefs)
      : _prefs = prefs,
        super(_initialFolders(prefs));

  final Prefs _prefs;

  static List<String> _initialFolders(Prefs prefs) {
    final stored = prefs.musicFolders;
    if (stored.isNotEmpty) return stored;
    final folder = _defaultMusicFolder;
    if (folder.isNotEmpty && Directory(folder).existsSync()) {
      return [folder];
    }
    return const [];
  }

  /// Adds a folder, dedupes, persists, and publishes the new list.
  Future<void> addFolder(String folder) async {
    await _prefs.addMusicFolder(folder);
    state = _prefs.musicFolders;
  }

  /// Removes a folder, persists, and publishes the new list.
  Future<void> removeFolder(String folder) async {
    await _prefs.removeMusicFolder(folder);
    state = _prefs.musicFolders;
  }
}

/// True while [LocalLibraryNotifier.scan] is running.
final isScanningProvider = StateProvider<bool>((ref) => false);

/// Scan progress in `0.0 .. 1.0` (drives the Library progress bar).
final scanProgressProvider = StateProvider<double>((ref) => 0.0);

/// Local tracks, loaded from AppDatabase on first read and refreshed
/// after every scan. Errors surface as [AsyncError].
final localLibraryNotifierProvider =
    StateNotifierProvider<LocalLibraryNotifier,
        AsyncValue<List<LocalTrack>>>((ref) {
  return LocalLibraryNotifier(ref, ref.watch(databaseProvider));
});

class LocalLibraryNotifier
    extends StateNotifier<AsyncValue<List<LocalTrack>>> {
  LocalLibraryNotifier(this._ref, this._db)
      : super(AsyncData(_db.getAllLocalTracks())) {
    _watcher = FolderWatcher(onChanged: _onWatchedFolderChanged);
    _ref.listen<List<String>>(
      musicFoldersProvider,
      (_, folders) => _watcher.watch(folders),
      fireImmediately: true,
    );
    _autoScanIfEmpty();
    _maybeRepairDegradedRows();
  }

  final Ref _ref;
  final AppDatabase _db;
  late final FolderWatcher _watcher;
  bool _scanQueued = false;
  bool _queuedFullRescan = false;
  Set<String>? _queuedForceRescanPaths;
  bool _queuedMetadataRepair = false;

  void _autoScanIfEmpty() {
    final current = state.value ?? const [];
    if (current.isEmpty) {
      final folders = _ref.read(musicFoldersProvider);
      if (folders.isNotEmpty) {
        Future.microtask(() => scan());
      }
    }
  }

  /// One-shot repair for rows written before the pure-Dart fallback
  /// existed: re-read only the visibly degraded files, leave the rest of
  /// the library on the mtime fast path.
  void _maybeRepairDegradedRows() {
    final prefs = _ref.read(prefsProvider);
    if (prefs.libraryMetadataRepaired) return;
    if (_ref.read(musicFoldersProvider).isEmpty) return;

    final degraded = _db.getLocalTrackPathsNeedingMetadataRepair();
    if (degraded.isEmpty) {
      unawaited(prefs.markLibraryMetadataRepaired());
      return;
    }
    Future.microtask(
      () => scan(forceRescanPaths: degraded, markMetadataRepaired: true),
    );
  }

  void _onWatchedFolderChanged() {
    if (!mounted) return;
    unawaited(scan());
  }

  @override
  void dispose() {
    _watcher.dispose();
    super.dispose();
  }

  /// Scans the watched [musicFoldersProvider] folders, upserts the
  /// found tracks, and republishes the full table. Files whose on-disk
  /// mtime is unchanged since the last scan skip tag re-reads (mtime
  /// delta skip). With [fullRescan], rows for files that are no longer
  /// present in any scanned folder are dropped.
  ///
  /// A scan started while another is running is coalesced into one
  /// follow-up pass instead of overlapping database writes.
  Future<void> scan({
    bool fullRescan = false,
    Set<String>? forceRescanPaths,
    bool markMetadataRepaired = false,
  }) async {
    if (_ref.read(isScanningProvider)) {
      _scanQueued = true;
      _queuedFullRescan = _queuedFullRescan || fullRescan;
      _queuedMetadataRepair = _queuedMetadataRepair || markMetadataRepaired;
      if (forceRescanPaths != null && forceRescanPaths.isNotEmpty) {
        (_queuedForceRescanPaths ??= <String>{}).addAll(forceRescanPaths);
      }
      return;
    }

    _ref.read(isScanningProvider.notifier).state = true;
    _ref.read(scanProgressProvider.notifier).state = 0.0;

    try {
      final folders = _ref.read(musicFoldersProvider);
      final timestamps = _db.getLocalTrackTimestamps();
      final alivePaths = <String>{};

      await scanFolders(
        folders,
        existingTimestamps: timestamps,
        alivePaths: alivePaths,
        forceRescanPaths: forceRescanPaths?.isNotEmpty == true
            ? forceRescanPaths
            : null,
        onBatch: (batch, count) {
          _db.insertOrUpdateLocalTracks(batch);
          state = AsyncData(_db.getAllLocalTracks());
        },
      );

      if (fullRescan) {
        _db.deleteLocalTracksNotIn(alivePaths);
      }

      if (markMetadataRepaired) {
        await _ref.read(prefsProvider).markLibraryMetadataRepaired();
      }

      state = AsyncData(_db.getAllLocalTracks());
      _ref.read(scanProgressProvider.notifier).state = 1.0;
    } catch (e, st) {
      state = AsyncError(e, st);
    } finally {
      _ref.read(isScanningProvider.notifier).state = false;
      if (_scanQueued) {
        final queuedFull = _queuedFullRescan;
        final queuedPaths = _queuedForceRescanPaths;
        final queuedRepair = _queuedMetadataRepair;
        _scanQueued = false;
        _queuedFullRescan = false;
        _queuedForceRescanPaths = null;
        _queuedMetadataRepair = false;
        unawaited(Future.microtask(
          () => scan(
            fullRescan: queuedFull,
            forceRescanPaths: queuedPaths,
            markMetadataRepaired: queuedRepair,
          ),
        ));
      }
    }
  }
}

/// Album projections for the local Library page (one row per album).
final localAlbumsProvider =
    Provider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseProvider).getLocalAlbums();
});

/// Artist projections for the local Library page (one row per artist).
final localArtistsProvider =
    Provider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseProvider).getLocalArtists();
});

/// Non-blank genres with per-genre `track_count`/`album_count`/artwork.
final localGenresProvider = Provider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseProvider).getLocalGenres();
});

/// Decade buckets (`decade`, `track_count`) for the era reveal, newest
/// first.
final localDecadesProvider = Provider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseProvider).getLocalDecades();
});

/// File-format distribution rows (`format`, `track_count`), most
/// tracks first.
final localFormatStatsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseProvider).getLocalFormatStats();
});

/// Lossless tracks above CD quality (FLAC/WAV/ALAC).
final localHiResProvider = Provider<List<LocalTrack>>((ref) {
  return ref.watch(databaseProvider).getLocalHiResTracks();
});

/// Most recently modified local tracks (default 200), newest first.
final localRecentTracksProvider = Provider<List<LocalTrack>>((ref) {
  return ref.watch(databaseProvider).getLocalRecentTracks();
});

/// Track search for the discovery search field (title/artist/album).
final localSearchTracksProvider =
    Provider.autoDispose.family<List<LocalTrack>, String>((ref, query) {
  return ref.watch(databaseProvider).searchLocalTracks(query);
});

/// Album search: rows have `album`, `album_artist`, `year`,
/// `artwork_path`, `track_count`.
final localSearchAlbumsProvider =
    Provider.autoDispose.family<List<Map<String, dynamic>>, String>(
        (ref, query) {
  return ref.watch(databaseProvider).searchLocalAlbums(query);
});

/// Artist search: rows have `artist`, `track_count`, `artwork_path`.
final localSearchArtistsProvider =
    Provider.autoDispose.family<List<Map<String, dynamic>>, String>(
        (ref, query) {
  return ref.watch(databaseProvider).searchLocalArtists(query);
});

/// All tracks tagged with [genre] (case-insensitive).
final localGenreTracksProvider =
    Provider.autoDispose.family<List<LocalTrack>, String>((ref, genre) {
  return ref.watch(databaseProvider).getLocalTracksForGenre(genre);
});

/// Era reveal: 'classics' spans 1900-1989, any other key is a decade.
final localEraTracksProvider =
    Provider.autoDispose.family<List<LocalTrack>, String>((ref, era) {
  final db = ref.watch(databaseProvider);
  if (era == 'classics') return db.getLocalTracksForYearRange(1900, 1989);
  return db.getLocalTracksForDecade(int.parse(era));
});
