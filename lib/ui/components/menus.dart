import 'dart:async';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../app/track_actions.dart';
import '../../core/audio/stream_models.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/scrobble_repository.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../app_shell/wave_hotkeys.dart';
import '../theme/tokens.dart';
import 'buttons.dart' show LWTooltip;

/// Snappy flyout entrance shared by every DropDownButton/menu in the
/// app. Same slide-from-edge language as fluent's default, compressed
/// into the first ~55% of the 167ms controller (≈90ms) plus a fast
/// fade — the full-length slide reads as lag on click. Pass as
/// `transitionBuilder:` on DropDownButton, or mirror with an explicit
/// 90ms `transitionDuration` on direct `showFlyout` calls.
Widget fastFlyoutTransition(
  BuildContext context,
  Animation<double> animation,
  FlyoutPlacementMode placementMode,
  Widget flyout,
) {
  if (animation.isCompleted || animation.isDismissed) return flyout;
  if (animation.status == AnimationStatus.reverse) {
    return FadeTransition(opacity: animation, child: flyout);
  }
  final textDirection = Directionality.of(context);
  final begin = switch (placementMode) {
    FlyoutPlacementMode.topCenter ||
    FlyoutPlacementMode.topLeft ||
    FlyoutPlacementMode.topRight =>
      const Offset(0, 1),
    _ => const Offset(0, -1),
  };
  const fast = Interval(0.0, 0.55, curve: Curves.easeOutCubic);
  return ClipRect(
    child: FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: fast),
      child: SlideTransition(
        textDirection: textDirection,
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: fast),
        ),
        child: flyout,
      ),
    ),
  );
}

/// Menu data model for [WaveFlyoutPanel].
///
/// Labels are plain strings (not Text widgets) so rows can enforce
/// single-line ellipsis inside the fixed-width panel. Carries no layout
/// of its own — rendering is owned by the panel.
sealed class WaveMenuEntry {
  const WaveMenuEntry();
}

/// One tappable row. `onPressed == null` renders disabled.
class WaveMenuAction extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final String? hint;
  final VoidCallback? onPressed;
  const WaveMenuAction({
    this.leading,
    required this.label,
    this.hint,
    this.onPressed,
  });
}

/// Horizontal divider.
class WaveMenuSeparator extends WaveMenuEntry {
  const WaveMenuSeparator();
}

/// Hover-cascade nested menu (e.g. "Add to playlist").
class WaveMenuSubmenu extends WaveMenuEntry {
  final Widget? leading;
  final String label;
  final List<WaveMenuEntry> Function() items;
  const WaveMenuSubmenu({
    this.leading,
    required this.label,
    required this.items,
  });
}

/// Single Fluent menu source for every track row / card / hero.
///
/// One builder produces [WaveMenuEntry] lists rendered by
/// [WaveFlyoutPanel] (right-click menus). Plugin DropDownButtons keep
/// their own inline item lists and are unaffected.
///
/// Rows carrying a local [PlayableTrack] (a playbackUrl that exists on
/// disk) also get the native file-ops cluster — Show in File Manager,
/// Copy File Path — directly ahead of Properties.
List<WaveMenuEntry> waveTrackMenuItems({
  required WidgetRef ref,
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
  PlayableTrack? playable,
  String? removeLabel,
  VoidCallback? onRemove,
}) {
  final player = ref.read(playbackServiceProvider.notifier);
  final track = playable ??
      PlayableTrack(
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: videoId,
      );
  final library = ref.read(playlistRepositoryProvider.notifier);
  final liked = library.likedKeys().contains(track.queueKey);
  final playlists = ref.read(playlistRepositoryProvider);

  StoredTrack stored() => StoredTrack(
        name: title,
        artist: artist,
        artworkUrl: artworkUrl,
        videoId: track.videoId,
      );

  final items = <WaveMenuEntry>[
    WaveMenuAction(
      leading: const Icon(FluentIcons.play, size: 15),
      label: 'Play',
      hint: 'Enter',
      onPressed: () =>
          player.play(track, sourceLabel: 'Context menu'),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.add, size: 15),
      label: 'Play next',
      onPressed: () => player.playNext(track),
    ),
    WaveMenuAction(
      leading: const Icon(FluentIcons.list, size: 15),
      label: 'Add to queue',
      onPressed: () => player.addToQueue(track),
    ),
    const WaveMenuSeparator(),
    WaveMenuAction(
      leading: Icon(
        liked ? FluentIcons.heart_fill : FluentIcons.heart,
        size: 15,
      ),
      label: liked ? 'Unlike' : 'Like',
      onPressed: () async {
        final loved = await library.toggleLiked(stored());
        _syncLovedToLastFm(ref, artist: artist, track: title, loved: loved);
      },
    ),
  ];

  // Native local-file ops, present only when the row is a real local
  // file: reveal in the folder, copy the exact path, then Properties —
  // one file-ops cluster set off from the library/playlist region.
  final playbackUrl = track.playbackUrl;
  final isLocalFile =
      playbackUrl.isNotEmpty && File(playbackUrl).existsSync();
  if (isLocalFile) {
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.folder_open, size: 15),
        label: 'Show in File Manager',
        onPressed: () =>
            unawaited(Process.run('xdg-open', [p.dirname(playbackUrl)])),
      ),
    );
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.copy, size: 15),
        label: 'Copy File Path',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: playbackUrl));
          unawaited(displayInfoBar(
            ref.context,
            builder: (context, close) => InfoBar(
              title: const Text('File path copied'),
              severity: InfoBarSeverity.info,
              onClose: close,
            ),
          ));
        },
      ),
    );
  }
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.info, size: 15),
      label: 'Properties',
      onPressed: () => showWaveTrackProperties(
        ref.context,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        playbackUrl: playbackUrl,
        durationSeconds: track.durationSeconds,
      ),
    ),
  );
  items.add(const WaveMenuSeparator());
  if (playlists.isNotEmpty) {
    items.add(
      WaveMenuSubmenu(
        leading: const Icon(FluentIcons.list_mirrored, size: 15),
        label: 'Add to playlist',
        items: () => [
          for (final playlist in playlists)
            WaveMenuAction(
              leading: Icon(
                playlist.isLikedSongs
                    ? FluentIcons.heart
                    : FluentIcons.list_mirrored,
                size: 15,
              ),
              label: playlist.title,
              onPressed: () => library.addTrack(playlist.id, stored()),
            ),
        ],
      ),
    );
  }
  items.add(const WaveMenuSeparator());
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.album, size: 15),
      label: 'Go to album',
      onPressed: () => goToAlbumOfTrack(
        ref,
        title: title,
        artist: artist,
        album: track.album,
      ),
    ),
  );
  items.add(
    WaveMenuAction(
      leading: const Icon(FluentIcons.microphone, size: 15),
      label: 'Go to artist',
      onPressed: () => ref.context
          .go('/artist/${Uri.encodeComponent(artist)}'),
    ),
  );
  if (removeLabel != null && onRemove != null) {
    items.add(const WaveMenuSeparator());
    items.add(
      WaveMenuAction(
        leading: const Icon(FluentIcons.delete, size: 15),
        label: removeLabel,
        hint: 'Del',
        onPressed: onRemove,
      ),
    );
  }
  return items;
}

/// Track properties dialog (Fluent ContentDialog).
///
/// A track with a live local path opens the full Track Inspector — an
/// Apple-style key/value sheet over FILE / AUDIO / TAGS sections read
/// straight from disk. Online or vanished-file tracks keep the minimal
/// 2-line identity dialog.
Future<void> showWaveTrackProperties(
  BuildContext context, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String playbackUrl = '',
  int durationSeconds = 0,
}) {
  final isLocalFile =
      playbackUrl.isNotEmpty && File(playbackUrl).existsSync();
  if (!isLocalFile) {
    return showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Properties'),
        constraints: const BoxConstraints(maxWidth: 440),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.trackTitle),
              const SizedBox(height: 4),
              Text(artist, style: WaveType.body),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  return showDialog(
    context: context,
    builder: (context) => _WaveTrackInspector(
      name: title,
      artist: artist,
      playbackUrl: playbackUrl,
      durationSeconds: durationSeconds,
    ),
  );
}

const String _missingValue = '—';

/// Inspector key column — clears the widest label ("Album Artist")
/// before the value column starts, keeping every row on one grid.
const double _inspectorKeyWidth = 110;

/// Full Track Inspector for local files. Stateful only because the tag
/// read arrives async: the dialog is up with the passed-in scalars
/// first, then embeds values are merged in when the reader lands.
class _WaveTrackInspector extends StatefulWidget {
  final String name;
  final String artist;
  final String playbackUrl;
  final int durationSeconds;
  const _WaveTrackInspector({
    required this.name,
    required this.artist,
    required this.playbackUrl,
    required this.durationSeconds,
  });

  @override
  State<_WaveTrackInspector> createState() => _WaveTrackInspectorState();
}

class _WaveTrackInspectorState extends State<_WaveTrackInspector> {
  int? _fileBytes;
  _StreamHead? _head;
  Tag? _tags;
  bool _tagsRead = false;

  @override
  void initState() {
    super.initState();
    try {
      _fileBytes = File(widget.playbackUrl).lengthSync();
    } catch (_) {
      // Deleted between menu and dialog: rows degrade to '—'.
      _fileBytes = null;
    }
    _head = _readStreamHead(widget.playbackUrl);
    unawaited(_readTags());
  }

  /// Reads embedded tags after the dialog is up. A failed or empty read
  /// keeps the passed-in scalars and honest '—' rows — no error dialog.
  Future<void> _readTags() async {
    Tag? tags;
    try {
      tags = await AudioTags.read(widget.playbackUrl);
    } catch (_) {
      tags = null;
    }
    if (!mounted) return;
    setState(() {
      _tags = tags;
      _tagsRead = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = waveTextPrimary(context);
    final secondary = waveTextSecondary(context);
    final tertiary = waveTextTertiary(context);
    final keyStyle = WaveType.label.copyWith(color: secondary);

    // Fixed key column + fluid value column. '—' placeholders render in
    // tertiary so empty slots stay visible but recede; numeric values
    // keep the repo's tabular-figures idiom.
    Widget kvRow(
      String label,
      String value, {
      int maxLines = 1,
      bool numeric = false,
      TextStyle? valueStyle,
    }) {
      final style = valueStyle ??
          WaveType.body.copyWith(
            color: value == _missingValue ? tertiary : primary,
            fontFeatures:
                numeric ? const [FontFeature.tabularFigures()] : null,
          );
      return Padding(
        padding: const EdgeInsetsDirectional.only(bottom: WaveSpacing.x4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _inspectorKeyWidth,
              child: Text(label, style: keyStyle),
            ),
            const SizedBox(width: WaveSpacing.x8),
            Expanded(
              child: Text(
                value,
                style: style,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // Overline section headers — the app's quiet eyebrow idiom, never
    // bold shouting; content is separated purely by whitespace.
    Widget section(String header, List<Widget> rows) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(header, style: WaveType.overline.copyWith(color: tertiary)),
            const SizedBox(height: WaveSpacing.x2),
            ...rows,
          ],
        );

    final fileRows = <Widget>[
      kvRow('File name', _waveTagText(p.basename(widget.playbackUrl))),
      // The path is the payload here: secondary color, wraps twice, then
      // ellipsis, so very long trees never break the row grid.
      kvRow(
        'Path',
        widget.playbackUrl,
        maxLines: 2,
        valueStyle: WaveType.body.copyWith(color: secondary),
      ),
      kvRow(
        'Size',
        _fileBytes == null ? _missingValue : _formatFileSize(_fileBytes!),
        numeric: true,
      ),
      kvRow('Container', _formatContainer(widget.playbackUrl)),
    ];

    final head = _head;
    final audioRows = <Widget>[
      kvRow(
        'Duration',
        _formatTrackLength(widget.durationSeconds),
        numeric: true,
      ),
      kvRow(
        'Bitrate',
        _formatBitrate(_fileBytes, widget.durationSeconds),
        numeric: true,
      ),
      kvRow(
        'Sample rate',
        head == null ? _missingValue : _formatSampleRate(head.sampleRate),
        numeric: true,
      ),
      kvRow(
        'Channels',
        head == null ? _missingValue : _formatChannelCount(head.channels),
      ),
    ];

    final tagRows = <Widget>[
      // Passed-in scalars until the read lands; afterwards the file's
      // own values, scalars as fallback so Title/Artist never lie empty.
      kvRow(
        'Title',
        _tagsRead
            ? _fallbackText(_tags?.title, widget.name)
            : _waveTagText(widget.name),
      ),
      kvRow(
        'Artist',
        _tagsRead
            ? _fallbackText(_tags?.trackArtist, widget.artist)
            : _waveTagText(widget.artist),
      ),
      kvRow('Album', _waveTagText(_tags?.album)),
      kvRow('Album Artist', _waveTagText(_tags?.albumArtist)),
      kvRow(
        'Track No',
        _waveNumberText(_tags?.trackNumber, _tags?.trackTotal),
        numeric: true,
      ),
      kvRow(
        'Disc No',
        _waveNumberText(_tags?.discNumber, _tags?.discTotal),
        numeric: true,
      ),
      kvRow(
        'Year',
        _tags?.year == null ? _missingValue : '${_tags!.year}',
        numeric: true,
      ),
      kvRow('Genre', _waveTagText(_tags?.genre)),
    ];

    return ContentDialog(
      title: const Text('Properties'),
      // Wider inspector, stock dialog height cap; roomier 24px chrome,
      // everything else stays the repo's standard dialog look.
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 756),
      style: ContentDialogThemeData(
        padding: const EdgeInsetsDirectional.all(WaveSpacing.x20),
      ),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.name,
                style: WaveType.trackTitle.copyWith(color: primary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: WaveSpacing.x2),
              Text(
                widget.artist,
                style: WaveType.body.copyWith(color: secondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: WaveSpacing.x16),
              section('FILE', fileRows),
              const SizedBox(height: WaveSpacing.x16),
              section('AUDIO', audioRows),
              const SizedBox(height: WaveSpacing.x16),
              section('TAGS', tagRows),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String _waveTagText(String? text) =>
    (text == null || text.trim().isEmpty) ? _missingValue : text.trim();

/// Tag value with a fallback scalar (Title/Artist keep the passed-in
/// strings when the embedded tag is missing that field).
String _fallbackText(String? tagValue, String fallback) {
  final trimmed = tagValue?.trim() ?? '';
  if (trimmed.isNotEmpty) return trimmed;
  final fb = fallback.trim();
  return fb.isEmpty ? _missingValue : fb;
}

/// '3', or '3/12' when the total rides along in the file's tag frame.
String _waveNumberText(int? number, int? total) {
  if (number == null || number <= 0) return _missingValue;
  if (total != null && total > 0) return '$number/$total';
  return '$number';
}

/// m:ss, minutes unbounded; 0 means "unknown", shown honestly as '—'.
String _formatTrackLength(int totalSeconds) {
  if (totalSeconds <= 0) return _missingValue;
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Finder-style sizing: whole KBs under 1 MB, one decimal after.
String _formatFileSize(int bytes) {
  const megabyte = 1024 * 1024;
  if (bytes < megabyte) return '${(bytes / 1024).round()} KB';
  return '${(bytes / megabyte).toStringAsFixed(1)} MB';
}

/// Average bitrate from the file's own size — blunt and honest, no
/// container magic; guarded against zero/negative sizing and duration.
String _formatBitrate(int? bytes, int durationSeconds) {
  if (bytes == null || bytes <= 0 || durationSeconds <= 0) return _missingValue;
  final kbps = bytes * 8 / durationSeconds / 1000;
  return '${kbps.round()} kbps (avg)';
}

/// The shipped container as an uppercase badge (FLAC / MP3 / M4A / …).
String _formatContainer(String path) {
  final ext = p.extension(path);
  return ext.isEmpty ? _missingValue : ext.substring(1).toUpperCase();
}

/// Sample rate / channel count read straight from FLAC or WAV headers —
/// the two containers 'audiotags' cannot service with stream
/// properties. MP3 / M4A / OPUS have no cheap header form here and
/// report no head at all (the inspector shows '—', never guesses from
/// bitrate); every IO race or malformed head yields null too.
class _StreamHead {
  const _StreamHead(this.sampleRate, this.channels);
  final int sampleRate; // Hz.
  final int channels;
}

/// Reads the first 64 bytes: FLAC ('fLaC' magic — STREAMINFO is always
/// the first metadata block, 20-bit rate + 3-bit channel count into
/// bytes 18–20) or WAV ('RIFF' — fmt chunk at fixed offsets, channels
/// 22–23 and rate 24–27, little-endian).
_StreamHead? _readStreamHead(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final head = file.readSync(64);
    if (head.length < 28) return null;
    int? rate;
    int? channels;
    final isFlac = head[0] == 0x66 &&
        head[1] == 0x4C &&
        head[2] == 0x61 &&
        head[3] == 0x43;
    final isWav = head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46;
    if (isFlac) {
      if ((head[4] & 0x7F) != 0) return null; // First block ≠ STREAMINFO.
      rate = (head[18] << 12) | (head[19] << 4) | (head[20] >> 4);
      channels = ((head[20] >> 1) & 0x07) + 1;
    } else if (isWav) {
      channels = head[22] | (head[23] << 8);
      rate = head[24] | (head[25] << 8) | (head[26] << 16) | (head[27] << 24);
    }
    if (rate == null || rate <= 0 || channels == null || channels <= 0) {
      return null;
    }
    return _StreamHead(rate, channels);
  } catch (_) {
    return null;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {}
  }
}

/// '44.1 kHz' / '48 kHz' / '96 kHz' — no .0 tails, one decimal only
/// when the rate actually needs it.
String _formatSampleRate(int sampleRate) {
  final kHz = sampleRate / 1000;
  if ((kHz - kHz.roundToDouble()).abs() < 0.05) return '${kHz.round()} kHz';
  return '${kHz.toStringAsFixed(1)} kHz';
}

/// 'Stereo' / 'Mono'; wider layouts stay anonymous rather than numeric.
String _formatChannelCount(int channels) {
  if (channels == 1) return 'Mono';
  if (channels == 2) return 'Stereo';
  return _missingValue;
}

/// Opaque fixed-width menu surface replacing plugin [MenuFlyout] /
/// [FlyoutContent] for our popups.
///
/// WHY: plugin MenuFlyout wraps content in IntrinsicWidth (an uncached
/// bottom-up measurement of the whole subtree on every open — the
/// RenderPhysicalModel/ClipPath/CustomPaint intrinsics cascade from the
/// profiles) plus an Acrylic/PhysicalModel shell. This panel sizes by
/// top-down constraints instead (stretch inside a fixed max width: O(n),
/// cached, nothing to measure) with an opaque surface + cacheable
/// BoxShadows. Rows are the theme's own [FlyoutListTile], so item
/// visuals (hover fill, typography, trailing style) are pixel-identical.
class WaveFlyoutPanel extends StatefulWidget {
  final List<WaveMenuEntry>? entries;
  final Widget? child;
  final double maxWidth;
  const WaveFlyoutPanel.items({
    super.key,
    required this.entries,
    this.maxWidth = 280,
  }) : child = null;
  const WaveFlyoutPanel.child({
    super.key,
    required this.child,
    this.maxWidth = 280,
  }) : entries = null;
  @override
  State<WaveFlyoutPanel> createState() => _WaveFlyoutPanelState();
}

class _WaveFlyoutPanelState extends State<WaveFlyoutPanel> {
  int _highlight = -1;
  FlyoutController? _openSubmenu;
  final Map<int, GlobalKey<_WaveSubmenuRowState>> _subKeys = {};

  @override
  void dispose() {
    // Cascaded submenu is its own route: close it with the parent.
    // Guarded + caught: dispose order vs. the child route is not
    // contractual, and close() asserts attached+open in debug.
    try {
      final sub = _openSubmenu;
      _openSubmenu = null;
      if (sub != null && sub.isOpen) sub.close();
    } catch (_) {}
    super.dispose();
  }

  /// Indices of keyboard-focusable rows (actions + submenus, no dividers).
  List<int> get _actionable => [
        for (var i = 0; i < (widget.entries?.length ?? 0); i++)
          if (widget.entries![i] is WaveMenuAction ||
              widget.entries![i] is WaveMenuSubmenu)
            i,
      ];

  void _moveHighlight(int dir) {
    final stops = _actionable;
    if (stops.isEmpty) return;
    setState(() {
      final at = stops.indexOf(_highlight);
      _highlight = at < 0
          ? (dir > 0 ? stops.first : stops.last)
          : stops[(at + dir) % stops.length];
    });
  }

  void _activate(BuildContext context, int index) {
    final entry = widget.entries![index];
    if (entry is WaveMenuSubmenu) {
      _subKeys[index]?.currentState?.openNow();
    } else if (entry is WaveMenuAction) {
      final onPressed = entry.onPressed;
      if (onPressed == null) return;
      Navigator.of(context).maybePop();
      onPressed();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter &&
        _highlight >= 0 &&
        widget.entries != null &&
        _highlight < widget.entries!.length) {
      _activate(context, _highlight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    Widget body;
    if (widget.child != null) {
      body = widget.child!;
    } else {
      final rows = <Widget>[];
      for (var i = 0; i < widget.entries!.length; i++) {
        final entry = widget.entries![i];
        if (entry is WaveMenuSeparator) {
          // Same spec as the plugin separator: 5px bottom pad, zero-margin
          // divider. Built inline — the plugin's is not a Widget.
          rows.add(const Padding(
            padding: EdgeInsetsDirectional.only(bottom: 5),
            child: Divider(
              style: DividerThemeData(
                  horizontalMargin: EdgeInsetsDirectional.zero),
            ),
          ));
        } else if (entry is WaveMenuSubmenu) {
          rows.add(_WaveSubmenuRow(
            key: _subKeys.putIfAbsent(
                i, () => GlobalKey<_WaveSubmenuRowState>()),
            entry: entry,
            highlighted: i == _highlight,
            onOpened: (c) {
              if (_openSubmenu != null &&
                  _openSubmenu != c &&
                  _openSubmenu!.isOpen) {
                _openSubmenu!.close();
              }
              _openSubmenu = c;
            },
          ));
        } else if (entry is WaveMenuAction) {
          final onPressed = entry.onPressed;
          rows.add(FlyoutListTile(
            margin: EdgeInsetsDirectional.zero,
            selected: i == _highlight,
            showSelectedIndicator: false,
            icon: entry.leading,
            text: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: entry.hint == null
                ? null
                : Text(entry.hint!,
                    style: const TextStyle(fontSize: 11)),
            onPressed: onPressed == null
                ? null
                : () {
                    Navigator.of(context).maybePop();
                    onPressed();
                  },
          ));
        }
      }
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    }

    final panel = Container(
      decoration: BoxDecoration(
        color: theme.menuColor,
        borderRadius: BorderRadius.circular(7),
        boxShadow: const [
          BoxShadow(
            color: Color(0x21000000),
            blurRadius: 7.2,
            offset: Offset(0, 3.2),
          ),
          BoxShadow(
            color: Color(0x1C000000),
            blurRadius: 1.8,
            offset: Offset(0, 0.68),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Padding(
          padding:
              const EdgeInsetsDirectional.symmetric(vertical: 2, horizontal: 4),
          child: body,
        ),
      ),
    );

    if (widget.entries == null) return panel;
    // Nav scope: Up/Down stay local while the menu has focus so the
    // global volume shortcuts yield to menu keyboard navigation.
    // (Space stays global: it toggles playback even with a menu open.)
    return WaveKeyNavScope(
      consumeUpDown: true,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: panel,
      ),
    );
  }
}

/// Cascading submenu row: same [FlyoutListTile] visuals as actions, opens
/// a nested [WaveFlyoutPanel] on hover (250ms) or tap/click/Enter.
class _WaveSubmenuRow extends StatefulWidget {
  final WaveMenuSubmenu entry;
  final bool highlighted;
  final ValueChanged<FlyoutController> onOpened;
  const _WaveSubmenuRow({
    super.key,
    required this.entry,
    required this.highlighted,
    required this.onOpened,
  });

  @override
  State<_WaveSubmenuRow> createState() => _WaveSubmenuRowState();
}

class _WaveSubmenuRowState extends State<_WaveSubmenuRow> {
  final _controller = FlyoutController();
  Timer? _hoverTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    // If the parent route is torn down with our submenu open, close it
    // ourselves; the panel dispose covers the reverse order. Caught:
    // the target may already be detached in debug asserts.
    try {
      if (_controller.isOpen) _controller.close();
    } catch (_) {}
    _controller.dispose();
    super.dispose();
  }

  void openNow() {
    _hoverTimer?.cancel();
    if (_controller.isOpen) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.rightTop,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.entry.items(),
      ),
    );
    widget.onOpened(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: MouseRegion(
        onEnter: (_) {
          _hoverTimer?.cancel();
          _hoverTimer = Timer(
            const Duration(milliseconds: 250),
            openNow,
          );
        },
        onExit: (_) => _hoverTimer?.cancel(),
        child: FlyoutListTile(
          margin: EdgeInsetsDirectional.zero,
          selected: widget.highlighted,
          showSelectedIndicator: false,
          icon: widget.entry.leading,
          text: Text(
            widget.entry.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(FluentIcons.chevron_right, size: 12),
          onPressed: openNow,
        ),
      ),
    );
  }
}

/// Right-click region opening a [WaveFlyoutPanel] at the cursor.
class WaveContextMenu extends StatefulWidget {
  final List<WaveMenuEntry> Function() items;
  final Widget child;
  const WaveContextMenu({
    super.key,
    required this.items,
    required this.child,
  });
  @override
  State<WaveContextMenu> createState() => _WaveContextMenuState();
}

class _WaveContextMenuState extends State<WaveContextMenu> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.items().isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: FlyoutPlacementMode.auto,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.items(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: GestureDetector(
        onSecondaryTapDown: (_) => _open(),
        onLongPressStart: (_) => _open(),
        child: widget.child,
      ),
    );
  }
}

/// Canonical context-menu alias: [LWContextMenu] is [WaveContextMenu].
///
/// Right-click / long-press region opening a 7px Fluent menu flyout.
class LWContextMenu extends WaveContextMenu {
  const LWContextMenu({
    super.key,
    required super.items,
    required super.child,
  });
}

/// Button opening a [WaveFlyoutPanel]; the trigger keeps caller visuals
/// verbatim (replaces plugin DropDownButton, whose MenuFlyout pays the
/// IntrinsicWidth measurement on every open).
class WaveMenuButton extends StatefulWidget {
  final List<WaveMenuEntry> entries;
  final FlyoutPlacementMode placement;
  final Widget Function(BuildContext context, VoidCallback onOpen)
      buttonBuilder;
  const WaveMenuButton({
    super.key,
    required this.entries,
    required this.buttonBuilder,
    this.placement = FlyoutPlacementMode.auto,
  });
  @override
  State<WaveMenuButton> createState() => _WaveMenuButtonState();
}

class _WaveMenuButtonState extends State<WaveMenuButton> {
  final _controller = FlyoutController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.entries.isEmpty) return;
    _controller.showFlyout(
      barrierColor: Colors.transparent,
      placementMode: widget.placement,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        entries: widget.entries,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FlyoutTarget(
      controller: _controller,
      child: widget.buttonBuilder(context, _open),
    );
  }
}

/// Overflow button opening a [WaveFlyoutPanel] below-right.
class WaveOverflowButton extends StatelessWidget {
  final String tooltip;
  final List<WaveMenuEntry> items;
  final IconData icon;
  const WaveOverflowButton({
    super.key,
    this.tooltip = 'More',
    required this.items,
    this.icon = FluentIcons.more,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return LWTooltip(
      message: tooltip,
      child: WaveMenuButton(
        entries: items,
        placement: FlyoutPlacementMode.bottomRight,
        buttonBuilder: (context, onOpen) => SizedBox(
          width: WaveDensity.hitArea,
          height: WaveDensity.hitArea,
          child: IconButton(
            icon: Icon(
              icon,
              size: 15,
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
            onPressed: onOpen,
          ),
        ),
      ),
    );
  }
}

/// Add-to-playlist picker dialog (Fluent ContentDialog).
Future<void> showWaveAddToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) async {
  final playlists = ref.read(playlistRepositoryProvider);
  if (playlists.isEmpty) return;
  final selected = await showDialog<int>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Add to playlist'),
      constraints: const BoxConstraints(maxWidth: 440),
      content: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in playlists)
              ListTile.selectable(
                title: Text(p.title),
                subtitle: Text('${p.tracks.length} tracks'),
                leading: Icon(
                  p.isLikedSongs
                      ? FluentIcons.heart
                      : FluentIcons.list_mirrored,
                  size: 15,
                ),
                selectionMode: ListTileSelectionMode.single,
                selected: false,
                onPressed: () =>
                    Navigator.of(context).pop(p.id),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (selected != null) {
    await ref.read(playlistRepositoryProvider.notifier).addTrack(
          selected,
          StoredTrack(
            name: title,
            artist: artist,
            artworkUrl: artworkUrl,
            videoId: videoId,
          ),
        );
  }
}

/// Like toggle helper for the new layer (no legacy toast host).
Future<bool> waveToggleLike(
  WidgetRef ref, {
  required String title,
  required String artist,
  String artworkUrl = '',
  String videoId = '',
}) {
  return ref.read(playlistRepositoryProvider.notifier).toggleLiked(
        StoredTrack(
          name: title,
          artist: artist,
          artworkUrl: artworkUrl,
          videoId: videoId,
        ),
      );
}

/// Mirrors a local like/unlike into Last.fm (`track.love` /
/// `track.unlove`). Fire-and-forget by design: the local toggle already
/// landed, the call is only made for a signed-in session, and
/// [ScrobbleRepository.setLoved] itself no-ops without one — nothing
/// here may block the UI. (Duplicated in track_row.dart and
/// player_dock.dart to keep the component domains dependency-light.)
void _syncLovedToLastFm(
  WidgetRef ref, {
  required String artist,
  required String track,
  required bool loved,
}) {
  if (artist.isEmpty || track.isEmpty) return;
  if (ref.read(authRepositoryProvider).status != AuthStatus.signedIn) {
    return;
  }
  unawaited(ref.read(scrobbleRepositoryProvider).setLoved(
        artist: artist,
        track: track,
        loved: loved,
      ));
}
