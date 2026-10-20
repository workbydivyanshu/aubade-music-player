/// One-shot backfill of local-track stream properties.
///
/// Rows scanned before header sniffing existed carry null `sample_rate`
/// / `bit_depth` / `size_bytes` / `bitrate`. This walks those rows
/// once (chunked, bounded concurrency), re-reads each file's header +
/// size, and updates the row in place. Guarded by
/// [Prefs.streamPropsBackfilled] so it runs at most once per install;
/// failures leave the flag unset so the next launch retries.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../search/shared_providers.dart';
import 'local_library_providers.dart';
import 'stream_props.dart';

/// Rows pulled per chunk (bounded memory for huge libraries).
const int _backfillChunkSize = 64;

/// Files probed concurrently inside a chunk (mirrors the scanner pool).
const int _backfillConcurrency = 16;

/// Backfills stream properties for every row that is still missing
/// them, then invalidates the local-library providers. Never throws.
Future<void> backfillStreamPropsOnceIfNeeded(WidgetRef ref) async {
  // WidgetRef (not Ref): the only caller is the app root's ConsumerState
  // initState, whose ref is a WidgetRef. Reads + invalidates both exist
  // on WidgetRef, so no plumbing loss.
  try {
    final prefs = ref.read(prefsProvider);
    if (prefs.streamPropsBackfilled) return;

    final db = ref.read(databaseProvider);
    final raw = db.raw;

    // sample_rate IS NULL = never sniffed; size_bytes IS NULL = no
    // stat yet. Both are filled by this pass.
    final rows = raw.select(
      'SELECT path, duration_ms, bitrate, sample_rate, bit_depth, size_bytes '
      'FROM local_tracks WHERE sample_rate IS NULL OR size_bytes IS NULL;',
    );

    for (var start = 0; start < rows.length; start += _backfillChunkSize) {
      final end = start + _backfillChunkSize;
      final chunk = rows.sublist(start, end > rows.length ? rows.length : end);
      for (var s = 0; s < chunk.length; s += _backfillConcurrency) {
        final poolEnd = s + _backfillConcurrency;
        final pool =
            chunk.sublist(s, poolEnd > chunk.length ? chunk.length : poolEnd);
        await Future.wait(pool.map((row) async {
          try {
            final path = (row['path'] as String?) ?? '';
            if (path.isEmpty) return;

            final props = readStreamPropsSync(path);
            int? size;
            try {
              size = File(path).lengthSync();
            } catch (_) {}

            final durationMs = ((row['duration_ms'] as num?) ?? 0).toInt();
            int? bitrate;
            if (size != null && size > 0 && durationMs > 0) {
              bitrate = (size * 8 / durationMs).round().clamp(0, 100000);
            }

            // A zero means "unknown": keep whatever the row already had.
            final sampleRate = props.sampleRate > 0
                ? props.sampleRate
                : row['sample_rate'] as int?;
            final bitDepth =
                props.bitDepth > 0 ? props.bitDepth : row['bit_depth'] as int?;
            final sizeBytes = size ?? row['size_bytes'] as int?;
            final finalBitrate = bitrate ?? row['bitrate'] as int?;

            raw.execute(
              'UPDATE local_tracks SET sample_rate = ?, bit_depth = ?, '
              'bitrate = ?, size_bytes = ? WHERE path = ?;',
              [sampleRate, bitDepth, finalBitrate, sizeBytes, path],
            );
          } catch (_) {}
        }));
      }
    }

    await prefs.markStreamPropsBackfilled();
    ref.invalidate(localLibraryNotifierProvider);
    ref.invalidate(localGenresProvider);
    ref.invalidate(localHiResProvider);
    ref.invalidate(localAlbumsProvider);
    ref.invalidate(localArtistsProvider);
  } catch (_) {}
}
