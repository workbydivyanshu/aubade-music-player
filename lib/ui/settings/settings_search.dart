import 'package:fluent_ui/fluent_ui.dart';

/// Searchable index of the settings groups. The catalog is group-level:
/// results jump to and highlight the group card that owns a setting,
/// they never create a second scroll tree. Group ids here are the
/// stable ids passed to `_Group(id: …)` in `settings_page.dart`.
class SettingsSearchEntry {
  /// `_SectionBody` section id (see `_waveSettingsSections` canon).
  final String section;
  final String groupId;
  final String groupTitle;
  final List<String> keywords;
  const SettingsSearchEntry({
    required this.section,
    required this.groupId,
    required this.groupTitle,
    this.keywords = const [],
  });

  /// Rail label shown for the result row.
  String get sectionLabel {
    switch (section) {
      case 'library':
        return 'Library';
      case 'audio':
        return 'Audio';
      case 'playback':
        return 'Playback';
      case 'appearance':
        return 'Appearance';
      case 'lyrics':
        return 'Lyrics';
      case 'lastfm':
        return 'Last.fm';
      case 'general':
        return 'General';
      case 'downloads':
        return 'Downloads';
      case 'experimental':
        return 'Experimental';
      case 'sources':
        return 'Addon sources';
      case 'about':
        return 'About';
      default:
        return section;
    }
  }
}

/// Every settings group, in stable order. When a group is added or
/// renamed, update both its `_Group(id: …)` and this catalog.
const List<SettingsSearchEntry> kSettingsSearchCatalog = [
  SettingsSearchEntry(
    section: 'library',
    groupId: 'music-folders',
    groupTitle: 'Music folders',
    keywords: ['local', 'scan', 'watch', 'path', 'folders'],
  ),
  SettingsSearchEntry(
    section: 'library',
    groupId: 'indexing',
    groupTitle: 'Library indexing',
    keywords: ['local', 'rescan', 'index', 'metadata'],
  ),
  SettingsSearchEntry(
    section: 'audio',
    groupId: 'audio-output',
    groupTitle: 'Audio output',
    keywords: ['device', 'system default', 'exclusive', 'wasapi'],
  ),
  SettingsSearchEntry(
    section: 'audio',
    groupId: 'loudness',
    groupTitle: 'Loudness & Dynamics',
    keywords: ['replaygain', 'preamp', 'clipping', 'limiter', 'gain'],
  ),
  SettingsSearchEntry(
    section: 'audio',
    groupId: 'resampling',
    groupTitle: 'Resampling & DAC',
    keywords: ['sox', 'sample rate', 'bit-perfect', 'native', 'dac'],
  ),
  SettingsSearchEntry(
    section: 'playback',
    groupId: 'playback',
    groupTitle: 'Playback',
    keywords: ['gapless', 'crossfade', 'autoplay', 'similar', 'speed'],
  ),
  SettingsSearchEntry(
    section: 'appearance',
    groupId: 'theme',
    groupTitle: 'Theme',
    keywords: ['light', 'dark', 'pearl', 'midnight', 'accent'],
  ),
  SettingsSearchEntry(
    section: 'appearance',
    groupId: 'haze',
    groupTitle: 'Haze material',
    keywords: ['blur', 'panel', 'backdrop', 'translucency'],
  ),
  SettingsSearchEntry(
    section: 'appearance',
    groupId: 'surfaces',
    groupTitle: 'Surfaces',
    keywords: ['amoled', 'black', 'artwork', 'accent', 'glow'],
  ),
  SettingsSearchEntry(
    section: 'lyrics',
    groupId: 'lyrics-timing',
    groupTitle: 'Timing',
    keywords: [
      'offset',
      'karaoke',
      'word',
      'line',
      'provider',
      'transliteration',
    ],
  ),
  SettingsSearchEntry(
    section: 'lastfm',
    groupId: 'lastfm-connection',
    groupTitle: 'Last.fm connection',
    keywords: ['sign in', 'session', 'username', 'scrobbler account'],
  ),
  SettingsSearchEntry(
    section: 'lastfm',
    groupId: 'api-keys',
    groupTitle: 'API keys',
    keywords: ['byok', 'app key', 'share'],
  ),
  SettingsSearchEntry(
    section: 'lastfm',
    groupId: 'lastfm-scrobbling',
    groupTitle: 'Last.fm scrobbling',
    keywords: ['scrobble', 'percent', 'now playing', 'threshold'],
  ),
  SettingsSearchEntry(
    section: 'general',
    groupId: 'behaviour',
    groupTitle: 'Behaviour',
    keywords: ['tray', 'minimize', 'startup', 'window', 'discord'],
  ),
  SettingsSearchEntry(
    section: 'general',
    groupId: 'open-with',
    groupTitle: 'Open with',
    keywords: ['default player', 'context menu', 'audio files'],
  ),
  SettingsSearchEntry(
    section: 'downloads',
    groupId: 'offline',
    groupTitle: 'Offline',
    keywords: ['download', 'lyrics sidecar', 'lrc', 'quality'],
  ),
  SettingsSearchEntry(
    section: 'sources',
    groupId: 'addon-sources',
    groupTitle: 'Addon sources',
    keywords: ['addon', 'urls', 'lossless', 'provider'],
  ),
  SettingsSearchEntry(
    section: 'experimental',
    groupId: 'experimental',
    groupTitle: 'Experimental',
    keywords: ['translucency', 'wavy seekbar', 'prototype'],
  ),
  SettingsSearchEntry(
    section: 'about',
    groupId: 'about-telemetry',
    groupTitle: 'System & Audio Telemetry',
    keywords: ['kernel', 'system', 'machine', 'updates'],
  ),
];

String _normHaystack(SettingsSearchEntry e) =>
    '${e.groupTitle} ${e.sectionLabel} ${e.keywords.join(' ')}'
        .toLowerCase();

/// Group search: every whitespace-separated token must appear in the
/// haystack (title, rail label or keywords). An empty query yields no
/// results so the surface stays idle until typing.
List<SettingsSearchEntry> searchSettingsGroups(String query) {
  final tokens = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return const [];
  return [
    for (final e in kSettingsSearchCatalog)
      if (tokens.every(_normHaystack(e).contains)) e,
  ];
}

/// The in-pane jump scope: the settings page hosts one around each
/// section pane; groups check it every build.
///
/// A jump carries the target id in [jumpId]; the group that matches
/// performs `Scrollable.ensureVisible` after its first frame, calls
/// [onJumpConsumed] to clear the one-shot jump state, and keeps the
/// [highlightId] accent until the page clears it (~2.2s later).
class SettingsJumpScope extends InheritedWidget {
  /// Id of the group that should scroll into view (one-shot).
  final String? jumpId;

  /// Id of the group that should show the accent highlight.
  final String? highlightId;

  final void Function() onJumpConsumed;

  const SettingsJumpScope({
    super.key,
    required this.jumpId,
    required this.highlightId,
    required this.onJumpConsumed,
    required super.child,
  });

  static SettingsJumpScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SettingsJumpScope>();
  }

  @override
  bool updateShouldNotify(SettingsJumpScope old) =>
      old.jumpId != jumpId || old.highlightId != highlightId;
}
