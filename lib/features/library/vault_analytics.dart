/// Vault analytics: play-based numbers for the local library, with the
/// offline scrobble queue folded in as a supplement. The UI consumes
/// these model shapes as-is; the numbers come from
/// [AppDatabase.loadVaultAnalytics].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../search/shared_providers.dart';

/// Aggregate numbers for the Vault page.
class VaultAnalytics {
  const VaultAnalytics({
    this.allTimeMinutes = 0,
    this.monthMinutes = 0,
    this.weekMinutes = 0,
    this.allTimePlays = 0,
    this.topTracks = const [],
    this.topArtists = const [],
    this.losslessCount = 0,
    this.lossyCount = 0,
    this.hiresCount = 0,
    this.totalCount = 0,
    this.hourlyPlays = const [],
    this.streakDays = 0,
    this.topSampleRates = const [],
  });

  /// Played minutes over the local play log, all-time / this calendar
  /// month / last 7 days.
  final int allTimeMinutes;
  final int monthMinutes;
  final int weekMinutes;

  /// Total logged plays (all-time).
  final int allTimePlays;

  /// Top 10 played tracks (local play log), most plays first.
  final List<VaultTopTrack> topTracks;

  /// Top 5 played artists, most plays first.
  final List<VaultTopArtist> topArtists;

  /// Library fidelity: lossless / lossy file counts.
  final int losslessCount;
  final int lossyCount;

  /// Lossless tracks above CD quality (rate > 48 kHz or depth > 16 bit).
  final int hiresCount;

  /// Total scanned local tracks.
  final int totalCount;

  /// Play counts per local hour (`Index 0 = 00:00`), always length 24.
  final List<int> hourlyPlays;

  /// Consecutive local play-days ending today; 0 when today has no play.
  final int streakDays;

  /// `[{'sample_rate': Hz, 'count': n}]`, most tracks first, top 4.
  final List<Map<String, int>> topSampleRates;
}

/// One row of the Vault top-tracks list. Stream metadata comes from the
/// matching `local_tracks` row when the title/artist join hits (0 /
/// `null` / `''` for pure YouTube listens).
class VaultTopTrack {
  const VaultTopTrack({
    required this.title,
    required this.artist,
    required this.plays,
    this.ms = 0,
    this.artworkPath,
    this.format = '',
    this.sampleRate = 0,
    this.bitDepth = 0,
  });

  final String title;
  final String artist;
  final int plays;

  /// Total played duration for this track (sum of its local durations).
  final int ms;

  final String? artworkPath;
  final String format;
  final int sampleRate;
  final int bitDepth;
}

/// One row of the Vault top-artists list.
class VaultTopArtist {
  const VaultTopArtist({required this.artist, required this.plays});

  final String artist;
  final int plays;
}

/// Aggregated Vault numbers for the active database.
final vaultAnalyticsProvider = FutureProvider<VaultAnalytics>((ref) async {
  final db = ref.watch(databaseProvider);
  return db.loadVaultAnalytics();
});
