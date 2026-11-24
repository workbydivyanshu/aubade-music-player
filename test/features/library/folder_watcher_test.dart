import 'dart:io';

import 'package:aubade/features/library/folder_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coalesces a burst of audio events into one callback', () async {
    var calls = 0;
    final watcher = FolderWatcher(
      onChanged: () => calls++,
      debounce: const Duration(milliseconds: 80),
    );
    addTearDown(watcher.dispose);

    watcher.handleEventForTest(
      FileSystemCreateEvent('/music/01 - Hit the Wall.flac', false),
    );
    watcher.handleEventForTest(
      FileSystemCreateEvent('/music/02 - Death Wish.flac', false),
    );
    watcher.handleEventForTest(
      FileSystemCreateEvent('/music/cover.jpg', false),
    );

    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(
      calls,
      1,
      reason: 'a download burst settles into a single scan trigger',
    );
  });

  test('ignores non-audio changes but accepts directory deletions', () async {
    var calls = 0;
    final watcher = FolderWatcher(
      onChanged: () => calls++,
      debounce: const Duration(milliseconds: 50),
    );
    addTearDown(watcher.dispose);

    watcher.handleEventForTest(
      FileSystemCreateEvent('/music/notes.txt', false),
    );
    watcher.handleEventForTest(
      FileSystemModifyEvent('/music/cover.jpg', false, true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(calls, 0);

    watcher.handleEventForTest(
      FileSystemDeleteEvent('/music/some album', true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      calls,
      1,
      reason: 'a deleted folder can remove tracks from the library',
    );
  });
}
