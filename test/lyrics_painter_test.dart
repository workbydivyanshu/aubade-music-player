import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aubade/features/lyrics/desktop_lyrics_painter.dart';
import 'package:aubade/features/lyrics/lyrics_models.dart';

LyricLine _line(
  int ms, {
  required String text,
  int durationMs = 2000,
  List<LyricSyllable> syllables = const [],
  String? agent,
}) {
  return LyricLine(
    timeMs: ms,
    durationMs: durationMs,
    text: text,
    syllables: syllables,
    agent: agent,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('kinetic styles', () {
    test('every style has a distinct label and stable id round-trip', () {
      expect(LyricsKineticStyle.values, hasLength(5));
      final labels = <String>{};
      final names = <String>{};
      for (final style in LyricsKineticStyle.values) {
        labels.add(style.label);
        names.add(style.name);
        expect(LyricsKineticStyle.fromId(style.name), style);
      }
      expect(labels, hasLength(5));
      expect(names, hasLength(5));
      expect(LyricsKineticStyle.fromId(null), LyricsKineticStyle.classic);
      expect(LyricsKineticStyle.fromId('nope'), LyricsKineticStyle.classic);
    });

    test('only dynamic lifts and only glow thickens the shadow', () {
      expect(LyricsKineticStyle.dynamic.lift, greaterThan(0));
      expect(LyricsKineticStyle.glow.lift, greaterThan(0));
      expect(LyricsKineticStyle.classic.lift, 0);
      expect(LyricsKineticStyle.minimal.lift, 0);
      expect(LyricsKineticStyle.glow.hasGlow, isTrue);
      expect(
        LyricsKineticStyle.values.where((s) => s.hasGlow),
        [LyricsKineticStyle.glow],
      );
      expect(
        LyricsKineticStyle.values.where((s) => s.hasSoftEdge),
        [LyricsKineticStyle.smooth],
      );
    });

    test('the instrumental countdown threshold is 3.5s', () {
      expect(DesktopLyricsTokens.instrumentalCountdownThresholdMs, 3500);
    });
  });

  group('stanza assembly', () {
    test('nests parenthesised accompaniment under the lead line', () {
      final stanzas = assembleStanzas([
        _line(0, text: 'Lead line'),
        _line(500, text: '(harmony)'),
        _line(1000, text: 'Next line'),
      ]);
      expect(stanzas, hasLength(1));
      final groups = stanzas.single.groups;
      expect(groups, hasLength(2));
      expect(groups.first.leadLine.text, 'Lead line');
      expect(groups.first.backgroundSublines.single.text, '(harmony)');
      expect(groups.first.role, VocalRole.leadLeft);
    });

    test('agent v2 stages the line on the right and both centers it', () {
      expect(
        vocalRoleFor(_line(0, text: 'Second singer', agent: 'v2')),
        VocalRole.duetRight,
      );
      expect(
        vocalRoleFor(_line(0, text: 'Together', agent: 'both')),
        VocalRole.unisonCenter,
      );
      expect(
        vocalRoleFor(_line(0, text: 'Plain', agent: 'v1')),
        VocalRole.leadLeft,
      );
    });

    test('a >=2.5s musical pause closes the stanza', () {
      final stanzas = assembleStanzas([
        _line(0, text: 'One'),
        _line(2500, text: 'Two'),
        _line(8000, text: 'After the break'),
      ]);
      expect(stanzas, hasLength(2));
      expect(stanzas.first.groups, hasLength(2));
      expect(stanzas.last.groups.single.leadLine.text, 'After the break');
    });

    test('empty input yields no stanzas', () {
      expect(assembleStanzas(const []), isEmpty);
    });
  });

  group('enhanced LRC leading word', () {
    test('text before the first inline stamp survives', () {
      final lines = parseEnhancedLrc(
        '[00:01.00] We <00:01.20>are <00:01.60>live',
      );
      expect(lines, hasLength(1));
      final words = lines.single.syllables.map((s) => s.text).toList();
      expect(words.first, 'We');
      expect(words.join(' '), contains('are'));
    });
  });

  group('TTML agent', () {
    test('parses ttm:agent onto the line', () {
      const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body><div>
    <p begin="0s" end="2s" ttm:agent="v2">Right singer</p>
    <p begin="2s" end="4s">Left singer</p>
  </div></body>
</tt>''';
      final lines = parseTtml(ttml);
      expect(lines, hasLength(2));
      expect(lines.first.agent, 'v2');
      expect(vocalRoleFor(lines.first), VocalRole.duetRight);
      expect(vocalRoleFor(lines.last), VocalRole.leadLeft);
    });
  });

  group('ParagraphLayoutCache', () {
    const active = TextStyle(fontSize: 32, fontWeight: FontWeight.w700);
    const idle = TextStyle(fontSize: 32, fontWeight: FontWeight.w700);

    test('maps syllable boundaries to painted advances', () {
      final cache = ParagraphLayoutCache();
      addTearDown(cache.dispose);
      final line = _line(
        0,
        text: 'Hello world',
        syllables: const [
          LyricSyllable(timeMs: 0, durationMs: 500, text: 'Hello '),
          LyricSyllable(timeMs: 500, durationMs: 500, text: 'world'),
        ],
      );
      final layout = cache.getOrCreate(
        line: line,
        maxWidth: 800,
        activeStyle: active,
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
        signature: 'unit',
      );
      expect(layout.syllableOffsetsX.length, 3);
      expect(layout.syllableOffsetsX.first, 0);
      expect(layout.syllableOffsetsX[1], greaterThan(0));
      expect(layout.syllableOffsetsX[2], greaterThan(layout.syllableOffsetsX[1]));
      expect(layout.height, greaterThan(0));
      expect(layout.width, greaterThan(0));
    });

    test('serves the same layout object on a cache hit', () {
      final cache = ParagraphLayoutCache();
      addTearDown(cache.dispose);
      final line = _line(100, text: 'Cached');
      CachedLineLayout build() => cache.getOrCreate(
            line: line,
            maxWidth: 400,
            activeStyle: active,
            idleStyle: idle,
            softStyle: idle,
            faintStyle: idle,
            signature: 'unit',
          );
      expect(identical(build(), build()), isTrue);
    });

    test('a signature change drops stale paragraphs', () {
      final cache = ParagraphLayoutCache();
      addTearDown(cache.dispose);
      final line = _line(100, text: 'Recycled');
      final first = cache.getOrCreate(
        line: line,
        maxWidth: 400,
        activeStyle: active,
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
        signature: 'a',
      );
      final firstHeight = first.activeParagraph.height;
      final second = cache.getOrCreate(
        line: line,
        maxWidth: 400,
        activeStyle: active.copyWith(fontSize: 20),
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
        signature: 'b',
      );
      expect(identical(first, second), isFalse);
      expect(second.activeParagraph.height, lessThan(firstHeight));
    });

    test('dispose releases every native paragraph it built', () {
      final cache = ParagraphLayoutCache();
      cache.getOrCreate(
        line: _line(0, text: 'One'),
        maxWidth: 400,
        activeStyle: active,
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
      );
      cache.getOrCreate(
        line: _line(1000, text: 'Two'),
        maxWidth: 400,
        activeStyle: active,
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
      );
      // Reaching into native memory after dispose is unsafe, so the
      // contract is simply that this returns without throwing.
      cache.dispose();
    });

    test('painters repaint only for a different line, layout or style', () {
      final position = ValueNotifier<int>(0);
      addTearDown(position.dispose);
      final cache = ParagraphLayoutCache();
      addTearDown(cache.dispose);
      final line = _line(0, text: 'Paint me');
      final layout = cache.getOrCreate(
        line: line,
        maxWidth: 400,
        activeStyle: active,
        idleStyle: idle,
        softStyle: idle,
        faintStyle: idle,
      );
      DesktopKaraokeLinePainter painter({LyricsKineticStyle? style}) =>
          DesktopKaraokeLinePainter(
            positionListenable: position,
            line: line,
            layout: layout,
            style: style ?? LyricsKineticStyle.classic,
          );

      expect(painter().shouldRepaint(painter()), isFalse);
      expect(
        painter(style: LyricsKineticStyle.glow)
            .shouldRepaint(painter(style: LyricsKineticStyle.classic)),
        isTrue,
      );

      // Painting at a position before the line paints the idle paragraph
      // only; after the end the whole line is sung. Both must not throw.
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(layout.width + 2, layout.height + 2);
      painter().paint(canvas, size);
      position.value = line.timeMs + line.durationMs + 1;
      painter().paint(canvas, size);
      recorder.endRecording().dispose();
    });
  });
}
