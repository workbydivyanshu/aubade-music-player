/// Lightweight, debounced watcher for the local music folders.
///
/// Uses `Directory.watch` (inotify on Linux, FSEvents on macOS,
/// ReadDirectoryChangesW on Windows) with a stability window so a
/// downloader that writes 20 tracks and an embedded cover in one burst
/// results in a single incremental scan instead of dozens.
///
/// The watcher never touches the database or Riverpod itself: it calls
/// [onChanged] and the library notifier decides how to reconcile. All
/// platform errors (unsupported recursive watch, deleted folder, watch
/// limit) degrade to "no live updates"; the manual scan still works.
library;

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'supported_audio.dart';

/// Called once per settled burst of filesystem changes.
typedef FolderChangedCallback = void Function();

/// Watches a set of music folders for audio-file changes.
class FolderWatcher {
  FolderWatcher({
    required this.onChanged,
    this.debounce = const Duration(milliseconds: 1500),
  });

  final FolderChangedCallback onChanged;
  final Duration debounce;
  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];
  Timer? _timer;

  /// Replaces the watched folder set. Safe to call repeatedly; existing
  /// watches are cancelled first.
  void watch(Iterable<String> folders) {
    stop();
    for (final folder in folders) {
      try {
        final directory = Directory(folder);
        if (!directory.existsSync()) continue;
        _subscriptions.add(
          directory
              .watch(recursive: true)
              .listen(_handleEvent, onError: (_) {}, cancelOnError: false),
        );
      } catch (_) {
        // Watch limits / unsupported filesystems: stay quiet.
      }
    }
  }

  void _handleEvent(FileSystemEvent event) {
    final path = event.path;
    if (path.isEmpty) return;
    final isDelete = event.type == FileSystemEvent.delete;
    // Deletions may target a directory holding audio; everything else
    // only matters when the changed path is playable.
    if (!isDelete && !isSupportedAudioPath(path)) return;

    _timer?.cancel();
    _timer = Timer(debounce, onChanged);
  }

  /// Feeds a synthetic event into the debounce/filter pipeline. Lets
  /// tests exercise the coalescing behaviour without depending on OS
  /// watch latency.
  @visibleForTesting
  void handleEventForTest(FileSystemEvent event) => _handleEvent(event);

  /// Cancels timers and folder watches.
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  /// Alias for [stop], matching widget/notifier disposal conventions.
  void dispose() => stop();
}
