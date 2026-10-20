import 'package:fluent_ui/fluent_ui.dart';

import '../theme/wave_icons.dart';

/// Rebuilt navigation — music first, panels secondary.
///
/// Layout:
/// - Library: Songs / Albums / Artists / Search
/// - Middle: Vault / Playlists / Liked (your stats + collections)
/// - Then: Downloads
/// - Bottom (pinned): Friends / Settings
///
/// History + Mix Lab stay routable but are NOT prime nav.
class WaveDestination {
  final String path;
  final String label;
  final IconData icon;
  const WaveDestination(this.path, this.label, this.icon);
}

const waveLibraryDestinations = [
  WaveDestination('/songs', 'Songs', WaveIcons.music),
  WaveDestination('/albums', 'Albums', WaveIcons.albums),
  WaveDestination('/artists', 'Artists', WaveIcons.artists),
  WaveDestination('/search', 'Search', WaveIcons.search),
];

const waveListenDestinations = waveLibraryDestinations;

const waveCollectionDestinations = [
  // Vault sits at the top of the collection group: directly under the
  // library separator "(Collections)" header slot, before Playlists /
  // Liked. Icon: FluentIcons.analytics does not exist in fluent_ui
  // 4.16.1 (only analytics_logo/query/report/view, document-shaped) —
  // bar_chart_vertical is the cleanest native chart glyph and survives
  // the 18px rail size.
  WaveDestination('/vault', 'Vault', FluentIcons.bar_chart_vertical),
  WaveDestination('/playlists', 'Playlists', WaveIcons.playlists),
  WaveDestination('/liked', 'Liked Songs', WaveIcons.liked),
];

const waveOfflineDestinations = <WaveDestination>[];

const waveSystemDestinations = [
  WaveDestination('/settings', 'Settings', WaveIcons.settings),
];

List<WaveDestination> get allWaveDestinations => [
      ...waveLibraryDestinations,
      ...waveCollectionDestinations,
      ...waveOfflineDestinations,
      ...waveSystemDestinations,
    ];

String waveRoutePath(String location) => location.split('?').first;

String waveActivePath(String location) {
  final path = waveRoutePath(location);
  for (final d in allWaveDestinations) {
    if (path == d.path || path.startsWith('${d.path}/')) {
      return d.path;
    }
  }
  if (path.startsWith('/song')) return '/songs';
  if (path.startsWith('/album')) return '/albums';
  if (path.startsWith('/artist')) return '/artists';
  if (path.startsWith('/playlist')) return '/playlists';
  if (path.startsWith('/liked')) return '/liked';
  if (path.startsWith('/search')) return '/search';
  if (path.startsWith('/settings')) return '/settings';
  return '/songs';
}
