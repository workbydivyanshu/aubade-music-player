import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/ui/components/menus.dart';

void main() {
  testWidgets('remote track properties shows metadata and hides technical fields',
      (tester) async {
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () => showWaveTrackProperties(
                context,
                title: 'Starlight',
                artist: 'Muse',
                album: 'Black Holes and Revelations',
                durationSeconds: 240,
                playbackUrl: 'https://cdn.example.com/audio/stream?token=secret123',
                queueKey: 'track:starlight',
                currentQueueKey: 'track:other',
                quality: 'LOSSLESS 24/96',
              ),
              child: const Text('Open Properties'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Properties'));
    await tester.pumpAndSettle();

    // Dialog title
    expect(find.text('Properties'), findsOneWidget);

    // Metadata rows
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Starlight'), findsOneWidget);

    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Muse'), findsOneWidget);

    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Black Holes and Revelations'), findsOneWidget);

    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('4:00'), findsOneWidget);

    // Inspector sections must NOT appear for remote tracks
    expect(find.text('FILE'), findsNothing);
    expect(find.text('AUDIO'), findsNothing);
    expect(find.text('TAGS'), findsNothing);

    // Quality must NOT appear because queueKey != currentQueueKey
    expect(find.text('Quality'), findsNothing);
    expect(find.text('LOSSLESS 24/96'), findsNothing);

    // Privacy verification: no URL, tokens, query params, or copy buttons
    expect(find.textContaining('cdn.example.com'), findsNothing);
    expect(find.textContaining('token='), findsNothing);
    expect(find.textContaining('secret123'), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Copy Link'), findsNothing);

    // Close button dismisses dialog
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Properties'), findsNothing);
  });

  testWidgets('remote track properties displays quiet dash for missing metadata',
      (tester) async {
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () => showWaveTrackProperties(
                context,
                title: '',
                artist: '',
                album: '',
                durationSeconds: 0,
                playbackUrl: '',
              ),
              child: const Text('Open Missing'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Missing'));
    await tester.pumpAndSettle();

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);

    // 4 missing values -> 4 dashes
    expect(find.text('—'), findsNWidgets(4));
  });

  testWidgets('remote track properties shows quality only when matching current playing track',
      (tester) async {
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () => showWaveTrackProperties(
                context,
                title: 'Hysteria',
                artist: 'Muse',
                album: 'Absolution',
                durationSeconds: 227,
                playbackUrl: 'https://stream.example.com/audio/h1',
                queueKey: 'track:hysteria',
                currentQueueKey: 'track:hysteria',
                quality: 'LOSSLESS 24/48',
              ),
              child: const Text('Open Current Properties'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Current Properties'));
    await tester.pumpAndSettle();

    // Quality must appear since queueKey matches currentQueueKey and quality is known
    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('LOSSLESS 24/48'), findsOneWidget);
  });

  testWidgets('local verified file opens full track inspector with FILE AUDIO TAGS',
      (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('aubade_prop_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final tempFile = File('${tempDir.path}/sample.flac')..writeAsStringSync('dummy');

    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () => showWaveTrackProperties(
                context,
                title: 'Local Sample',
                artist: 'Local Artist',
                playbackUrl: tempFile.path,
                durationSeconds: 180,
              ),
              child: const Text('Open Local Properties'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Local Properties'));
    await tester.pumpAndSettle();

    // Full inspector sections appear
    expect(find.text('FILE'), findsOneWidget);
    expect(find.text('AUDIO'), findsOneWidget);
    expect(find.text('TAGS'), findsOneWidget);
  });
}
