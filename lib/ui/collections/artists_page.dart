import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/library/local_library_providers.dart';
import '../components/artwork.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Artist rows from the local library DB, most tracks first. Artwork
/// stays empty (initials fallback) — the scanner indexes audio tags.
final _waveArtistsProvider = Provider<
    List<({String name, String artwork, int tracks})>>((ref) {
  return [
    for (final m in ref.watch(localArtistsProvider))
      (
        name: m['artist'] as String? ?? '',
        artwork: '',
        tracks: (m['track_count'] as num?)?.toInt() ?? 0,
      ),
  ].where((e) => e.name.isNotEmpty).toList();
});

/// Artists — 120px circle portraits with rank pill, initials fallback.
/// Tap opens the dedicated artist layout.
class WaveArtistsPage extends ConsumerWidget {
  const WaveArtistsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_waveArtistsProvider);
    if (list.isEmpty) {
      return const WaveEmpty(
        icon: FluentIcons.contact,
        title: 'No artists yet',
        subtitle:
            'Artists from your music folders appear here after a library scan.',
      );
    }
    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
              child: WaveEntrance(
                rise: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Artists',
                        style: WaveType.pageTitle
                            .copyWith(fontSize: 24)),
                    Text('${list.length} voices',
                        style: WaveType.meta.copyWith(
                            color: waveTextSecondary(
                                context))),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                mainAxisExtent: 176,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = list[i];
                  return WaveEntrance(
                    index: i,
                    rise: 10,
                    child: _ArtistCell(
                        name: a.name,
                        artwork: a.artwork,
                        rank: i + 1,
                        tracks: a.tracks),
                  );
                },
                childCount: list.length,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistCell extends StatefulWidget {
  final String name;
  final String artwork;
  final int rank;
  final int tracks;
  const _ArtistCell(
      {required this.name,
      required this.artwork,
      required this.rank,
      required this.tracks});
  @override
  State<_ArtistCell> createState() => _ArtistCellState();
}

class _ArtistCellState extends State<_ArtistCell> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return WaveContextMenu(
      items: () => [
        WaveMenuAction(
          leading: const Icon(FluentIcons.contact, size: 13),
          label: 'Open artist',
          onPressed: () => context.go(
              '/artist/${Uri.encodeComponent(widget.name)}'),
        ),
        WaveMenuAction(
          leading: const Icon(FluentIcons.search, size: 13),
          label: 'Search for artist',
          onPressed: () => context.go(
              '/search?q=${Uri.encodeComponent(widget.name)}'),
        ),
      ],
      child: MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => context.go(
            '/artist/${Uri.encodeComponent(widget.name)}'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    scale: _hover ? 1.04 : 1.0,
                    duration:
                        const Duration(milliseconds: 110),
                    child: WaveArtwork.circle(
                        url: widget.artwork,
                        size: 120,
                        label: widget.name,
                        title: widget.name,
                        artist: widget.name),
                  ),
                  Positioned(
                    left: 8,
                    top: 0,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: dark
                            ? WaveColors.surfaceRaised
                            : WaveColors.lightSurface,
                        borderRadius:
                            BorderRadius.circular(999),
                        border: Border.all(
                            color: dark
                                ? WaveColors.outline
                                : WaveColors
                                    .lightOutline),
                      ),
                      child: Text('${widget.rank}',
                          style: WaveType.meta.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: WaveType.trackTitle.copyWith(
                      fontSize: 12.5,
                      color: _hover
                          ? waveAccent(context)
                          : null)),
              Text('${widget.tracks} tracks',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: WaveType.meta.copyWith(
                      fontSize: 10.5,
                      color: waveTextTertiary(context))),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
