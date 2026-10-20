import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/vault_analytics.dart';
import '../components/artwork.dart' show WaveArtwork;
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Vault — "Wrapped, Any Day": the library's identity page.
///
/// Read-only and privacy-first: every figure is computed 100% locally
/// from the on-device play log + library scan
/// ([vaultAnalyticsProvider] → [VaultAnalytics]); nothing leaves the
/// machine. No play affordances, no material widgets — Wave tokens only
/// (WaveType / WaveRadius / WaveSpacing + context helpers).
///
/// Bento of frosted glass tiles mirroring the repo's genre-card idiom
/// (translucent surface + hairline border + fr10, no page-level blur):
/// 1. Hero      — all-time listening in big tabular h/m + four sub-stats.
/// 2. Fidelity  — one lossless segment carrying an inner hi-res stripe
///                (nested proportion, not three slices) + legend chips.
/// 3. Rotation  — top 10 tracks as rank-badged cards.
/// 3b. Artists  — five compact top-artist chips.
/// 4. Clock     — 24 hourly play bars (plain fractional containers).
/// 5. Privacy   — subtle lock pill stating the local-only promise.
class WaveVaultPage extends ConsumerWidget {
  const WaveVaultPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultAnalyticsProvider);
    // Same async plumbing as the history lane: ring + label while the
    // FutureProvider runs, honest InfoBar card with a Retry that
    // invalidates the provider on failure.
    return vault.when(
      loading: () => const WaveLoading(label: 'Loading Vault…'),
      error: (e, _) => WaveError(
        title: 'Could not load Vault',
        message: '$e',
        onRetry: () => ref.invalidate(vaultAnalyticsProvider),
      ),
      data: (v) => WaveEntranceGroup(
        child: LayoutBuilder(
          builder: (context, viewport) => _body(context, v, viewport),
        ),
      ),
    );
  }
}

Widget _body(BuildContext context, VaultAnalytics v, BoxConstraints c) {
  final wide = c.maxWidth >= 880; // bento pair threshold (min tile ≥ 340)
  final tiles = <Widget>[];

  // Tile 1 — hero, always full width.
  tiles
    ..add(
      WaveEntrance(index: 0, rise: 10, child: _header(context)),
    )
    ..add(const SizedBox(height: WaveSpacing.x8))
    ..add(WaveEntrance(index: 1, child: _heroTile(context, v)))
    ..add(const SizedBox(height: 14));

  // Middle band: heaviest tile (rotation) balances fixed content on the
  // narrow side; everything stacks single-column on compact windows.
  final middle = wide
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: WaveEntrance(
                index: 2,
                child: _heavyTile(context, v),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  WaveEntrance(index: 3, child: _artistsTile(context, v)),
                  const SizedBox(height: 14),
                  WaveEntrance(index: 4, child: _fidelityTile(context, v)),
                ],
              ),
            ),
          ],
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WaveEntrance(index: 2, child: _fidelityTile(context, v)),
            const SizedBox(height: 14),
            WaveEntrance(index: 3, child: _heavyTile(context, v)),
            const SizedBox(height: 14),
            WaveEntrance(index: 4, child: _artistsTile(context, v)),
          ],
        );

  tiles
    ..add(middle)
    ..add(const SizedBox(height: 14))
    ..add(WaveEntrance(index: 5, child: _clockTile(context, v)))
    ..add(const SizedBox(height: 14))
    ..add(WaveEntrance(index: 6, child: _privacyPill(context)));

  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tiles,
    ),
  );
}

// ── Header ──────────────────────────────────────────────────────────────────

Widget _header(BuildContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Vault', style: WaveType.pageTitle.copyWith(fontSize: 24)),
      const SizedBox(height: WaveSpacing.x2),
      Text(
        'Your listening, quantified — computed entirely on this device.',
        style: WaveType.body.copyWith(color: waveTextSecondary(context)),
      ),
    ],
  );
}

// ── Shared frosted tile chrome (genre-card idiom from search_page) ─────────

Widget _tile(
  BuildContext context, {
  required String overline,
  String? trailing,
  required Widget child,
}) {
  final dark = waveIsDark(context);
  return RepaintBoundary(
    child: Container(
      padding: const EdgeInsets.all(WaveSpacing.x12),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.05)
            : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.08)
              : WaveColors.lightOutline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  overline,
                  style: WaveType.overline.copyWith(
                    fontSize: 10,
                    color: waveTextTertiary(context),
                  ),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: WaveType.overline.copyWith(
                    fontSize: 10,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: dark
                        ? WaveColors.textPrimary
                        : WaveColors.lightTextPrimary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: WaveSpacing.x8),
          child,
        ],
      ),
    ),
  );
}

// ── Tile 1 · Hero — all-time listening ─────────────────────────────────────

Widget _heroTile(BuildContext context, VaultAnalytics v) {
  final dark = waveIsDark(context);
  final bigStyle = dark
      ? WaveColors.textPrimary
      : WaveColors.lightTextPrimary;
  final unitStyle = dark
      ? WaveColors.textSecondary
      : WaveColors.lightTextSecondary;
  final minutes = v.allTimeMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;

  // Sub-stat cells: month / week / total plays / streak.
  final stats = <Widget>[
    _VaultStat(label: 'THIS MONTH', value: _minutesShort(v.monthMinutes)),
    _VaultStat(label: 'THIS WEEK', value: _minutesShort(v.weekMinutes)),
    _VaultStat(label: 'TOTAL PLAYS', value: _fmtCount(v.allTimePlays)),
    _VaultStat(label: 'DAY STREAK', value: _fmtCount(v.streakDays)),
  ];

  return _tile(
    context,
    overline: 'ALL-TIME LISTENING',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: WaveType.numeral.copyWith(
              fontSize: 44,
              letterSpacing: -1.2,
              color: bigStyle,
            ),
            children: [
              if (h > 0) ...[
                TextSpan(text: '$h'),
                TextSpan(
                  text: ' h  ',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    color: unitStyle,
                  ),
                ),
              ],
              TextSpan(text: '$m'),
              TextSpan(
                text: ' m',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  color: unitStyle,
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: WaveSpacing.x8),
          color: waveDivider(context),
        ),
        Wrap(
          spacing: 28,
          runSpacing: WaveSpacing.x8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: stats,
        ),
      ],
    ),
  );
}

class _VaultStat extends StatelessWidget {
  final String label;
  final String value;
  const _VaultStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: dark
                ? WaveColors.textPrimary
                : WaveColors.lightTextPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: WaveType.overline.copyWith(
            fontSize: 9.5,
            color: waveTextTertiary(context),
          ),
        ),
      ],
    );
  }
}

// ── Tile 2 · Fidelity — nested lossless / hi-res / lossy bar ───────────────

Widget _fidelityTile(BuildContext context, VaultAnalytics v) {
  final body = v.totalCount <= 0
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: WaveSpacing.x2),
          child: Text(
            'Scan your library to see fidelity.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _fidelityBar(context, v),
            const SizedBox(height: WaveSpacing.x8),
            _fidelityLegend(context, v),
          ],
        );

  return _tile(
    context,
    overline: 'FIDELITY',
    trailing: v.totalCount > 0
        ? '${_fmtCount(v.totalCount)} tracks'
        : null,
    child: body,
  );
}

/// One bar, two layers: the base row is [lossless | lossy | remainder];
/// a hi-res stripe is drawn INSIDE the lossless segment (left-anchored,
/// hires/lossless fraction) so hi-res reads as a subset of lossless —
/// never an independent slice.
Widget _fidelityBar(BuildContext context, VaultAnalytics v) {
  final dark = waveIsDark(context);
  final losslessFill = dark
      ? WaveColors.textSecondary
      : WaveColors.lightTextSecondary;
  final hiresFill = dark
      ? WaveColors.textPrimary
      : WaveColors.lightTextPrimary;
  final lossyFill = dark
      ? WaveColors.accentDim
      : WaveColors.lightTextTertiary;
  final trackFill = waveDivider(context);

  final lossless = v.losslessCount;
  final lossy = v.lossyCount;
  final remainder = (v.totalCount - lossless - lossy).clamp(0, v.totalCount);
  final hiresFrac = lossless <= 0
      ? 0.0
      : (v.hiresCount / lossless).clamp(0.0, 1.0);

  final segments = <Widget>[
    if (lossless > 0)
      Expanded(
        flex: lossless,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: losslessFill)),
            if (v.hiresCount > 0)
              Positioned(
                left: 0,
                right: 0,
                top: 3,
                bottom: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: hiresFrac,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: hiresFill,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    if (lossy > 0) Expanded(flex: lossy, child: ColoredBox(color: lossyFill)),
    if (remainder > 0)
      Expanded(flex: remainder, child: ColoredBox(color: trackFill)),
  ];

  return ClipRRect(
    borderRadius: WaveRadius.tinyRadius,
    child: SizedBox(
      height: 10,
      child: segments.isEmpty
          ? ColoredBox(color: trackFill)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: segments,
            ),
    ),
  );
}

Widget _fidelityLegend(BuildContext context, VaultAnalytics v) {
  final dark = waveIsDark(context);
  final losslessFill = dark
      ? WaveColors.textSecondary
      : WaveColors.lightTextSecondary;
  final hiresFill = dark
      ? WaveColors.textPrimary
      : WaveColors.lightTextPrimary;
  final lossyFill = dark
      ? WaveColors.accentDim
      : WaveColors.lightTextTertiary;
  final total = v.totalCount;

  Widget chip(String label, int count, Color dot) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: WaveSpacing.x2),
        Text(
          '$label ${_fmtCount(count)} · ${_pct(count, total)}%',
          style: WaveType.meta.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: waveTextSecondary(context),
          ),
        ),
      ],
    );
  }

  return Wrap(
    spacing: WaveSpacing.x8,
    runSpacing: WaveSpacing.x2,
    children: [
      chip('FLAC', v.losslessCount, losslessFill),
      chip('24-bit', v.hiresCount, hiresFill),
      chip('Lossy', v.lossyCount, lossyFill),
    ],
  );
}

// ── Tile 3 · Heavy rotation — top 10 track cards ───────────────────────────

Widget _heavyTile(BuildContext context, VaultAnalytics v) {
  final body = v.topTracks.isEmpty
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: WaveSpacing.x2),
          child: Text(
            'No plays yet — your top tracks appear as you listen.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        )
      : LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final perRow = w >= 620 ? 2 : 1;
            final cardW =
                (w - (perRow - 1) * WaveSpacing.x4) / perRow;
            return Wrap(
              spacing: WaveSpacing.x4,
              runSpacing: WaveSpacing.x4,
              children: [
                for (var i = 0; i < v.topTracks.length && i < 10; i++)
                  _VaultTopCard(
                    track: v.topTracks[i],
                    rank: i + 1,
                    width: cardW,
                  ),
              ],
            );
          },
        );

  return _tile(
    context,
    overline: 'HEAVY ROTATION',
    trailing: v.topTracks.isEmpty ? null : 'TOP ${v.topTracks.length}',
    child: body,
  );
}

class _VaultTopCard extends StatelessWidget {
  final VaultTopTrack track;
  final int rank;
  final double width;

  const _VaultTopCard({
    required this.track,
    required this.rank,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final title = dark
        ? WaveColors.textPrimary
        : WaveColors.lightTextPrimary;
    return Container(
      width: width,
      padding: const EdgeInsets.all(WaveSpacing.x8),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.04)
            : WaveColors.lightBackground,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.06)
              : WaveColors.lightOutlineSoft,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: Stack(
              children: [
                Positioned.fill(
                  child: WaveArtwork(
                    url: _fileArt(track.artworkPath),
                    size: 46,
                    radius: WaveRadius.artwork,
                    label: track.title,
                    title: track.title,
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(5, 1, 5, 1),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(WaveRadius.tiny),
                    ),
                    child: Text(
                      '#$rank',
                      style: WaveType.overline.copyWith(
                        fontSize: 9,
                        letterSpacing: 0.4,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: WaveSpacing.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle.copyWith(color: title),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist.isEmpty ? 'Unknown artist' : track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: WaveSpacing.x8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_fmtCount(track.plays)}×',
                style: WaveType.label.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: title,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _mss(track.ms),
                style: WaveType.meta.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: waveTextTertiary(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Tile 3b · Top artists ───────────────────────────────────────────────────

Widget _artistsTile(BuildContext context, VaultAnalytics v) {
  final artists = v.topArtists;
  final body = artists.isEmpty
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: WaveSpacing.x2),
          child: Text(
            'No plays yet — artists fill in as you listen.',
            style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
          ),
        )
      : Wrap(
          spacing: WaveSpacing.x4,
          runSpacing: WaveSpacing.x4,
          children: [
            for (final a in artists) _VaultArtistChip(a),
          ],
        );

  return _tile(context, overline: 'TOP ARTISTS', child: body);
}

class _VaultArtistChip extends StatelessWidget {
  final VaultTopArtist artist;
  const _VaultArtistChip(this.artist);

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final initial = artist.artist.isEmpty
        ? '?'
        : artist.artist.substring(0, 1).toUpperCase();
    return Container(
      padding: const EdgeInsets.fromLTRB(
          WaveSpacing.x8, 5, WaveSpacing.x12, 5),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.04)
            : WaveColors.lightBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.08)
              : WaveColors.lightOutline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : WaveColors.lightOverlay,
            ),
            child: Text(
              initial,
              style: WaveType.label.copyWith(
                fontSize: 10.5,
                color: waveTextSecondary(context),
              ),
            ),
          ),
          const SizedBox(width: WaveSpacing.x4),
          Text(
            artist.artist.isEmpty ? 'Unknown' : artist.artist,
            style: WaveType.label.copyWith(
              color: dark
                  ? WaveColors.textPrimary
                  : WaveColors.lightTextPrimary,
            ),
          ),
          const SizedBox(width: WaveSpacing.x2),
          Text(
            '${_fmtCount(artist.plays)}×',
            style: WaveType.meta.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: waveTextTertiary(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tile 4 · Listening clock — 24 hourly bars ──────────────────────────────

Widget _clockTile(BuildContext context, VaultAnalytics v) {
  final plays = v.hourlyPlays;
  var max = 0;
  for (final p in plays) {
    if (p > max) max = p;
  }
  var peak = -1;
  if (max > 0) {
    for (var i = 0; i < plays.length; i++) {
      if (plays[i] == max) {
        peak = i;
        break;
      }
    }
  }

  Widget columnOfHours(int from, int to) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var h = from; h < to; h++)
            _hourRow(context, h, h < plays.length ? plays[h] : 0,
                max: max, isPeak: h == peak),
        ],
      );

  return _tile(
    context,
    overline: 'LISTENING CLOCK',
    trailing: peak >= 0 ? 'PEAK ${_hourLabel(peak)}' : null,
    child: LayoutBuilder(
      builder: (context, c) {
        if (max <= 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: WaveSpacing.x2),
            child: Text(
              'No plays yet — hours fill in as you listen.',
              style: WaveType.meta.copyWith(
                color: waveTextTertiary(context),
              ),
            ),
          );
        }
        if (c.maxWidth >= 640) {
          // Two 12-hour banks side by side keep the tile compact.
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: columnOfHours(0, 12)),
              const SizedBox(width: WaveSpacing.x12),
              Expanded(child: columnOfHours(12, 24)),
            ],
          );
        }
        return columnOfHours(0, 24);
      },
    ),
  );
}

Widget _hourRow(
  BuildContext context,
  int hour,
  int plays, {
  required int max,
  required bool isPeak,
}) {
  final dark = waveIsDark(context);
  final fill = isPeak
      ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
      : dark
          ? WaveColors.textTertiary.withValues(alpha: 0.75)
          : WaveColors.lightTextTertiary.withValues(alpha: 0.55);
  final track = dark
      ? Colors.white.withValues(alpha: WaveState.hoverAlpha)
      : Colors.black.withValues(alpha: WaveState.hoverAlpha);
  final frac = max > 0 ? (plays / max).clamp(0.0, 1.0) : 0.0;

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            hour.toString().padLeft(2, '0'),
            style: WaveType.overline.copyWith(
              fontSize: 9,
              color: isPeak
                  ? (dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary)
                  : waveTextTertiary(context),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: WaveSpacing.x4),
        Expanded(
          child: SizedBox(
            height: 13,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: track)),
                  if (plays > 0)
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: frac,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: fill,
                              borderRadius: BorderRadius.circular(2.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: WaveSpacing.x4),
        SizedBox(
          width: 40,
          child: Text(
            plays > 0 ? '${_fmtCount(plays)}×' : '',
            textAlign: TextAlign.right,
            style: WaveType.overline.copyWith(
              fontSize: 9,
              letterSpacing: 0.3,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: isPeak
                  ? (dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary)
                  : waveTextTertiary(context),
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Tile 5 · Privacy pill ───────────────────────────────────────────────────

/// Pill geometry is reserved for chips (tokens.dart pillar charter), and
/// this badge is exactly that: a quiet chip — no blur surface, just the
/// hairline + tonal fill used across the page.
Widget _privacyPill(BuildContext context) {
  final dark = waveIsDark(context);
  return Center(
    child: Container(
      padding: const EdgeInsets.fromLTRB(
          WaveSpacing.x12, 8, WaveSpacing.x20, 8),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.04)
            : WaveColors.lightBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.08)
              : WaveColors.lightOutline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FluentIcons.lock_solid,
            size: 13,
            color: waveTextTertiary(context),
          ),
          const SizedBox(width: WaveSpacing.x4),
          Text(
            'Computed 100% locally from your device. '
            'Never transmitted anywhere.',
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextTertiary(context),
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Pure helpers ────────────────────────────────────────────────────────────

/// artworkPath → WaveArtwork URL contract (`file://<abs>`, '' → tonal
/// initials fallback) — mirrors search_page.dart's `_fileArt` exactly.
String _fileArt(String? path) =>
    path == null || path.isEmpty ? '' : 'file://$path';

/// Minutes → short honest label: '5 h 12 m' / '42 m' / '0 m'.
String _minutesShort(int minutes) {
  if (minutes <= 0) return '0 m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h <= 0) return '$m m';
  if (m <= 0) return '$h h';
  return '$h h $m m';
}

/// Milliseconds → m:ss ('' when unknown — honest-zero, not 0:00).
String _mss(int ms) {
  if (ms <= 0) return '';
  final total = ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Integer percentage, floor — honest, never exceeds 100.
int _pct(int part, int total) => total <= 0 ? 0 : part * 100 ~/ total;

/// '1024' → '1,024' (plain grouping, no intl dependency).
String _fmtCount(int n) {
  final s = n.abs().toString();
  if (s.length <= 3) return s;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final rem = s.length - i;
    out.write(s[i]);
    if (rem > 1 && rem % 3 == 1) out.write(',');
  }
  final grouped = out.toString();
  return n < 0 ? '-$grouped' : grouped;
}

/// Hour index → 'HH:00' for the peak label.
String _hourLabel(int hour) =>
    '${hour.toString().padLeft(2, '0')}:00';
