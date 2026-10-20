import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/features/library/playlists.dart';
import 'package:aubade/ui/components/focus_glyph.dart';
import 'package:aubade/ui/components/marquee.dart';
import 'package:aubade/ui/theme/motion.dart';
import 'package:aubade/ui/theme/tokens.dart';

void main() {
  group('WaveMotion reduced-motion table', () {
    test('modeFor maps the OS flag', () {
      expect(WaveMotion.modeFor(disableAnimations: true),
          WaveMotionMode.reduced);
      expect(
          WaveMotion.modeFor(disableAnimations: false), WaveMotionMode.full);
    });

    test('reduced motion pins every interaction to 1.0', () {
      expect(
        WaveMotion.interactionScale(
          mode: WaveMotionMode.reduced,
          hovered: true,
          pressed: true,
        ),
        1.0,
      );
    });

    test('full motion preserves per-widget hover/press deltas', () {
      expect(
        WaveMotion.interactionScale(
          mode: WaveMotionMode.full,
          hovered: true,
          pressed: false,
          hoverScale: 1.10,
        ),
        1.10,
      );
      expect(
        WaveMotion.interactionScale(
          mode: WaveMotionMode.full,
          hovered: true,
          pressed: true,
          pressScale: 0.90,
        ),
        0.90,
      );
    });
  });

  testWidgets('respectReduce follows MediaQuery.disableAnimations',
      (tester) async {
    late bool reduced;
    await tester.pumpWidget(m.MediaQuery(
      data: const m.MediaQueryData(disableAnimations: true),
      child: m.Builder(builder: (context) {
        reduced = WaveMotion.respectReduce(context);
        return const m.SizedBox();
      }),
    ));
    expect(reduced, isTrue);
  });

  testWidgets('WaveEntrance lands on the final frame under reduced motion',
      (tester) async {
    await tester.pumpWidget(m.MaterialApp(
      home: m.MediaQuery(
        data: const m.MediaQueryData(disableAnimations: true),
        child: const WaveEntranceGroup(
          child: WaveEntrance(index: 3, child: m.Text('row')),
        ),
      ),
    ));
    await tester.pump();
    // No fade/rise wrapper: the child is returned untouched.
    expect(
      find.descendant(
        of: find.byType(WaveEntrance),
        matching: find.byType(m.Opacity),
      ),
      findsNothing,
    );
    expect(find.text('row'), findsOneWidget);
  });

  testWidgets('WaveMarqueeText scrolls only text that overflows',
      (tester) async {
    Future<void> pumpMarquee(String text, {required bool reduce}) async {
      await tester.pumpWidget(m.MaterialApp(
        home: m.MediaQuery(
          data: m.MediaQueryData(
            disableAnimations: reduce,
            textScaler: m.TextScaler.noScaling,
          ),
          child: m.Material(
            color: m.Colors.transparent,
            child: m.Center(
              child: m.SizedBox(
                width: 80,
                child: WaveMarqueeText(text, maxLines: 1),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    await pumpMarquee('Short', reduce: false);
    expect(
      find.descendant(
        of: find.byType(WaveMarqueeText),
        matching: find.byType(m.ClipRect),
      ),
      findsNothing,
      reason: 'short titles must not animate',
    );

    await pumpMarquee(
        'A title that is definitely wider than eighty logical pixels',
        reduce: false);
    expect(
      find.descendant(
        of: find.byType(WaveMarqueeText),
        matching: find.byType(m.ClipRect),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 6));
    final transforms = tester.widgetList<m.Transform>(
      find.descendant(
        of: find.byType(WaveMarqueeText),
        matching: find.byType(m.Transform),
      ),
    );
    expect(
      transforms.any((t) => t.transform.getTranslation().x < -1),
      isTrue,
      reason: 'the overflowing title should have scrolled',
    );

    await pumpMarquee(
        'A title that is definitely wider than eighty logical pixels',
        reduce: true);
    expect(
      find.descendant(
        of: find.byType(WaveMarqueeText),
        matching: find.byType(m.ClipRect),
      ),
      findsNothing,
      reason: 'reduced motion keeps the static ellipsis',
    );
  });

  testWidgets('FocusGlyph takes keyboard focus and activates on Enter',
      (tester) async {
    var activations = 0;
    await tester.pumpWidget(f.FluentApp(
      home: FocusGlyph(
        onActivate: () => activations++,
        child: const m.SizedBox(width: 34, height: 34),
      ),
    ));
    await tester.pump();

    final focus = tester.widget<f.Focus>(find.descendant(
      of: find.byType(FocusGlyph),
      matching: find.byType(f.Focus),
    ));
    expect(focus.canRequestFocus, isTrue);
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.focusNode!.hasFocus, isTrue,
        reason: 'glyph node should own primary focus');

    final ring = tester.widget<m.AnimatedContainer>(find.byType(
      m.AnimatedContainer,
    ));
    final decoration = ring.foregroundDecoration! as m.BoxDecoration;
    final border = decoration.border! as m.Border;
    expect(border.top.color, isNot(m.Colors.transparent));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 1);
  });

  testWidgets('FocusGlyph removes disabled glyphs from the tab order',
      (tester) async {
    await tester.pumpWidget(f.FluentApp(
      home: const FocusGlyph(
        enabled: false,
        child: m.SizedBox(width: 34, height: 34),
      ),
    ));
    final focus = tester.widget<f.Focus>(find.descendant(
      of: find.byType(FocusGlyph),
      matching: find.byType(f.Focus),
    ));
    expect(focus.canRequestFocus, isFalse);
    expect(focus.skipTraversal, isTrue);
  });

  group('liked key derivation', () {
    test('reads the liked playlist and lowercases name|artist', () {
      final keys = likedKeysFor(const [
        SavedPlaylist(
          id: 1,
          title: 'Mix',
          mode: 'custom',
          tracks: [StoredTrack(name: 'Other', artist: 'Someone')],
        ),
        SavedPlaylist(
          id: 2,
          title: SavedPlaylist.likedTitle,
          mode: SavedPlaylist.likedMode,
          tracks: [StoredTrack(name: 'Song', artist: 'Artist', videoId: 'v')],
        ),
      ]);
      expect(keys, {'song|artist'});
    });

    test('no liked playlist means an empty const set', () {
      expect(likedKeysFor(const []), isEmpty);
    });

    test('notifier suppresses rebuilds for set-equal state', () {
      final notifier = LikedKeysNotifier();
      expect(notifier.updateShouldNotify({'a|b'}, {'a|b'}), isFalse);
      expect(notifier.updateShouldNotify({'a|b'}, {'a|b', 'c|d'}), isTrue);
    });
  });
}
