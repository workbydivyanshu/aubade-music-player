/// Recursively scans local folders for audio tracks and caches artwork.
///
/// Supported extensions: .mp3, .flac, .m4a, .aac, .opus, .ogg, .wav.
/// Tag reading uses `package:audiotags` with Tauon-style tolerance: if
/// `AudioTags.read` throws or returns `null`, the track degrades to
/// basename-based fallback values instead of aborting the scan.
///
/// Performance notes:
/// - Files are tag-read through a bounded pool of `_scanConcurrency`
///   concurrent workers, so a scan is disk-bound rather than serial.
/// - Passing `existingTimestamps` (path -> on-disk mtime in epoch
///   milliseconds) enables a Tauon-style mtime delta skip: unchanged
///   files are not re-read and emit no tracks, batches or progress.
/// - Passing `alivePaths` fills it with every discovered audio path
///   (skipped or not) so callers can prune rows for vanished files.
library;

import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_track.dart';
import 'stream_props.dart';

/// Extensions recognized by the local library scan.
const Set<String> _supportedExtensions = {
  '.mp3',
  '.flac',
  '.m4a',
  '.aac',
  '.opus',
  '.ogg',
  '.wav',
};

/// Companion images checked (in order) next to the track file.
const List<String> _companionImages = [
  'cover.jpg',
  'cover.png',
  'folder.jpg',
  'front.jpg',
];

/// Sub-directory (inside the app cache dir) holding extracted embedded art.
const String _artCacheDirName = 'aubade_art';

/// Simultaneous file tag scans (Tuned for gate-limited disk pipelines).
const int _scanConcurrency = 16;

/// Callback for incremental batch updates as tracks are discovered.
typedef ScanBatchCallback = void Function(List<LocalTrack> batch, int totalSoFar);

/// Callback for track progress counter.
typedef ScanProgressCallback = void Function(int totalSoFar);

/// Scan [folders] recursively and return one [LocalTrack] per audio file,
/// sorted by path, with perfect dedupe (each path yielded once even when
/// folders overlap or run through the concurrent pool).
///
/// When [onBatch] is supplied, discovered tracks are emitted in chunks of
/// [batchSize] (default 50) for immediate database insertion and live UI
/// updates.
///
/// When [existingTimestamps] (path -> on-disk mtime in epoch milliseconds,
/// e.g. from `AppDatabase.getLocalTrackTimestamps`) maps a file to its
/// current mtime, that file is skipped entirely: no tag re-read, no track,
/// no batch, no progress callback.
///
/// When [alivePaths] is supplied, every discovered audio path (skipped or
/// not) is added to it so callers can prune rows for vanished files.
Future<List<LocalTrack>> scanFolders(
  Iterable<String> folders, {
  ScanBatchCallback? onBatch,
  ScanProgressCallback? onProgress,
  int batchSize = 50,
  Map<String, int>? existingTimestamps,
  Set<String>? alivePaths,
}) async {
  final tracks = <LocalTrack>[];
  final seen = <String>{};
  final companionCache = <String, String?>{};
  final currentBatch = <LocalTrack>[];

  Directory? artCacheDir;
  try {
    final cacheRoot = await getApplicationCacheDirectory();
    artCacheDir = Directory(p.join(cacheRoot.path, _artCacheDirName));
    if (!artCacheDir.existsSync()) {
      artCacheDir.createSync(recursive: true);
    }
  } catch (_) {}

  final hasTimestamps =
      existingTimestamps != null && existingTimestamps.isNotEmpty;

  for (final folder in folders) {
    // Phase 1 (discovery): walk only, no tag I/O.
    List<File> candidates;
    try {
      candidates = await _discoverFiles(Directory(folder), seen);
    } catch (_) {
      // A single unreadable folder must not abort the whole scan.
      continue;
    }

    // Phase 2 (delta split): stat every candidate once and drop the ones
    // whose on-disk mtime still matches the recorded timestamp.
    final toScan = <File>[];
    for (final file in candidates) {
      if (hasTimestamps) {
        int mtimeMillis;
        try {
          mtimeMillis = (await file.stat()).modified.millisecondsSinceEpoch;
        } catch (_) {
          continue; // Unreadable file: drop the candidate silently.
        }
        if (existingTimestamps[file.path] == mtimeMillis) continue;
      }
      toScan.add(file);
    }

    // Phase 3 (bounded pool): tag-read chunks of `_scanConcurrency`;
    // Future.wait preserves the chunk's order so batching/progress
    // sequencing stays deterministic.
    for (var start = 0; start < toScan.length; start += _scanConcurrency) {
      final end = start + _scanConcurrency;
      final chunk =
          toScan.sublist(start, end > toScan.length ? toScan.length : end);
      final scanned = await Future.wait(chunk.map((file) async {
        try {
          return await _scanFile(
            file,
            companionCache: companionCache,
            artCacheDir: artCacheDir,
          );
        } catch (_) {
          // Skip corrupt or unreadable audio file without failing the scan.
          return null;
        }
      }));
      for (final track in scanned) {
        if (track == null) continue;
        tracks.add(track);
        currentBatch.add(track);
        onProgress?.call(tracks.length);

        if (currentBatch.length >= batchSize) {
          onBatch?.call(List<LocalTrack>.from(currentBatch), tracks.length);
          currentBatch.clear();
        }
      }
    }
  }

  // Flush remaining tracks in the final batch.
  if (currentBatch.isNotEmpty) {
    onBatch?.call(List<LocalTrack>.from(currentBatch), tracks.length);
    currentBatch.clear();
  }

  tracks.sort((a, b) => a.path.compareTo(b.path));

  if (alivePaths != null) alivePaths.addAll(seen);

  return tracks;
}

/// Phase 1 of a folder scan: recursive walk collecting supported audio
/// files. Dedupe goes through [seen] (`entity.path`), which is shared
/// across folders, so overlapping folder lists yield each file once.
Future<List<File>> _discoverFiles(Directory dir, Set<String> seen) async {
  final candidates = <File>[];
  try {
    await for (final entity in dir
        .list(recursive: true, followLinks: false)
        .handleError((_) {})) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!_supportedExtensions.contains(ext)) continue;
      if (!seen.add(entity.path)) continue;
      candidates.add(entity);
    }
  } catch (_) {
    // A single unreadable directory must not abort the whole scan.
  }
  return candidates;
}

Future<LocalTrack> _scanFile(
  File file, {
  required Map<String, String?> companionCache,
  Directory? artCacheDir,
}) async {
  final path = file.path;
  final format =
      p.extension(path).toLowerCase().substring(1); // strip the leading dot
  final modifiedAt = (await file.stat()).modified.millisecondsSinceEpoch;

  // On-disk size (avg bitrate denominator) and stream properties from
  // the container header. Both are best-effort: a miss keeps the column
  // null without failing the scan.
  int? sizeBytes;
  try {
    sizeBytes = file.lengthSync();
  } catch (_) {}
  final props = readStreamPropsSync(path);

  Tag? tag;
  try {
    tag = await AudioTags.read(path);
  } catch (_) {
    tag = null; // Tauon-style tolerance: unreadable tags fall back below.
  }

  final title = tag?.title ?? p.basenameWithoutExtension(path);
  final artist = tag?.trackArtist ?? 'Unknown Artist';
  final album = tag?.album ?? 'Unknown Album';
  // audiotags returns `duration` as seconds (Rust core:
  // `file.properties().duration().as_secs()`), not milliseconds.
  final duration =
      tag != null ? Duration(seconds: tag.duration ?? 0) : Duration.zero;
  final durationMs = duration.inMilliseconds;
  final hasEmbeddedArt = (tag?.pictures.isNotEmpty) ?? false;
  final artworkPath = await _resolveArtwork(
    file,
    tag,
    companionCache: companionCache,
    artCacheDir: artCacheDir,
  );

  return LocalTrack(
    path: path,
    title: title,
    artist: artist,
    album: album,
    albumArtist: tag?.albumArtist ?? '',
    trackNumber: tag?.trackNumber,
    discNumber: tag?.discNumber,
    year: tag?.year,
    genre: tag?.genre,
    duration: duration,
    // audiotags 1.4.x does not expose stream properties; the header
    // sniff supplies them, and the average bitrate falls out of
    // file size ÷ duration (bits per millisecond == kbps).
    bitrate: durationMs > 0 && sizeBytes != null && sizeBytes > 0
        ? (sizeBytes * 8 / durationMs).round().clamp(0, 100000)
        : null,
    sampleRate: props.sampleRate > 0 ? props.sampleRate : null,
    bitDepth: props.bitDepth > 0 ? props.bitDepth : null,
    sizeBytes: sizeBytes,
    format: format,
    artworkPath: artworkPath,
    hasEmbeddedArt: hasEmbeddedArt,
    modifiedAt: modifiedAt,
  );
}

/// Resolves artwork for [file]. A companion image next to the file wins;
/// otherwise the first embedded picture is extracted and cached under the
/// app cache dir (`aubade_art/<sha256>.jpg`).
/// Companion lookup is cached per-directory for O(1) checks.
Future<String?> _resolveArtwork(
  File file,
  Tag? tag, {
  required Map<String, String?> companionCache,
  Directory? artCacheDir,
}) async {
  final parentDir = p.dirname(file.path);

  // 1. Companion image next to the track (memoized per directory).
  if (companionCache.containsKey(parentDir)) {
    final cached = companionCache[parentDir];
    if (cached != null) return cached;
  } else {
    String? found;
    for (final name in _companionImages) {
      final candidate = File(p.join(parentDir, name));
      if (candidate.existsSync()) {
        found = candidate.path;
        break;
      }
    }
    companionCache[parentDir] = found;
    if (found != null) return found;
  }

  // 2. Extract an embedded picture and cache it by content hash.
  final pictures = tag?.pictures;
  if (pictures == null || pictures.isEmpty) return null;

  final bytes = pictures.first.bytes;
  final hash = sha256.convert(bytes).toString();

  final cacheDir = artCacheDir ??
      Directory(
        p.join((await getApplicationCacheDirectory()).path, _artCacheDirName),
      );
  try {
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
  } catch (_) {}

  final cacheFile = File(p.join(cacheDir.path, '$hash.jpg'));
  if (!cacheFile.existsSync()) {
    try {
      await cacheFile.writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }
  return cacheFile.path;
}
