import 'package:flutter/painting.dart';

/// Flattens a GitHub-flavoured release-notes body into display-ready spans.
///
/// The update dialog shows notes as static text; its buttons own every action,
/// so markdown is rendered as typography rather than a live document:
/// - `#`/`##`/`###`/`####` headings become bold, slightly larger lines without
///   their hashes.
/// - `**bold**` becomes a bold run.
/// - `- ` / `* ` bullets become `•  ` rows.
/// - `[label](url)` keeps only the label; bare URLs (including parenthetical
///   ones) are dropped, so no `https://` or `github.com` text reaches the UI.
/// - runs of blank lines collapse to one.
///
/// Returns an empty list when [body] has no visible text; callers should hide
/// the notes section entirely in that case.
List<TextSpan> formatReleaseNotes(String body) {
  if (body.trim().isEmpty) return const [];

  const headingStyle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  const bulletStyle = TextStyle(fontWeight: FontWeight.w600);

  final spans = <TextSpan>[];
  var wroteLine = false;
  var blankLines = 0;

  final lines = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');

  for (final rawLine in lines) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) {
      // Any number of blank source lines renders as at most one empty line.
      if (wroteLine) blankLines = 1;
      continue;
    }

    // Horizontal rules (`---`, `--`, `***`, `___`) carry no information.
    if (RegExp(r'^\s{0,3}(?:-{2,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      continue;
    }

    final heading = RegExp(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$').firstMatch(line);
    final bullet = heading == null
        ? RegExp(r'^\s*[-*+]\s+(.*)$').firstMatch(line)
        : null;

    var text = heading?.group(1) ?? bullet?.group(1) ?? line.trim();
    text = _stripInline(text);

    final lineSpans = <TextSpan>[];
    if (heading != null) {
      _appendInline(lineSpans, text, headingStyle);
    } else if (bullet != null) {
      if (text.isEmpty) continue;
      lineSpans.add(const TextSpan(text: '•  ', style: bulletStyle));
      _appendInline(lineSpans, text, null);
    } else {
      _appendInline(lineSpans, text, null);
    }
    if (lineSpans.isEmpty) continue;

    if (wroteLine) {
      spans.add(TextSpan(text: blankLines > 0 ? '\n\n' : '\n'));
    }
    spans.addAll(lineSpans);
    wroteLine = true;
    blankLines = 0;
  }

  return spans;
}

/// Removes link syntax and every URL shape from a single line.
String _stripInline(String input) {
  var text = input;

  // Images: drop the whole badge/image, then keep only link labels.
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (match) => match.group(1) ?? '',
  );
  // Reference-style links: [label][1] -> label.
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\[[^\]]*\]'),
    (match) => match.group(1) ?? '',
  );

  // Bare URLs with a scheme, preserving sentence punctuation that follows.
  text = text.replaceAllMapped(RegExp(r'https?://[^\s<>()]+'), (match) {
    final raw = match.group(0)!;
    var end = raw.length;
    while (end > 0 && '.,;:!?'.contains(raw[end - 1])) {
      end--;
    }
    return raw.substring(end);
  });

  // Scheme-less GitHub references are never useful in the dialog body.
  text = text.replaceAll(
    RegExp(r'\b(?:www\.)?github\.com\b[^\s)]*', caseSensitive: false),
    '',
  );

  // Shells left behind by removed parenthetical URLs.
  text = text
      .replaceAll(RegExp(r'\(\s*\)'), '')
      .replaceAll(RegExp(r'\[\s*\]'), '')
      .replaceAll(RegExp(r'<\s*>'), '');

  // Block quotes, inline code, and trailing markdown artifacts.
  text = text
      .replaceFirst(RegExp(r'^>+\s*'), '')
      .replaceAll('`', '')
      .replaceAll(RegExp(r'[#~]+\s*$'), '')
      .replaceAll(RegExp(r'\s+([.,;:!?])'), r'$1')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .trim();

  return text;
}

/// Splits [text] on `**bold**` and appends the resulting runs to [out].
void _appendInline(List<TextSpan> out, String text, TextStyle? base) {
  final pattern = RegExp(r'\*\*(.+?)\*\*');
  var start = 0;

  void addPlain(String value) {
    final plain = _stripLoneMarkers(value);
    if (plain.isNotEmpty) out.add(TextSpan(text: plain, style: base));
  }

  for (final match in pattern.allMatches(text)) {
    if (match.start > start) {
      addPlain(text.substring(start, match.start));
    }
    out.add(
      TextSpan(
        text: match.group(1),
        style: base == null ? _boldStyle : base.merge(_boldStyle),
      ),
    );
    start = match.end;
  }

  if (start < text.length) addPlain(text.substring(start));

  // Unmatched emphasis markers can leave a dangling space at end of line.
  if (out.isNotEmpty) {
    final tail = out.last;
    final trimmed = (tail.text ?? '').trimRight();
    if (trimmed.isEmpty) {
      out.removeLast();
    } else if (trimmed != tail.text) {
      out[out.length - 1] = TextSpan(text: trimmed, style: tail.style);
    }
  }
}

String _stripLoneMarkers(String value) =>
    value.replaceAll('**', '').replaceAll('__', '');

const _boldStyle = TextStyle(fontWeight: FontWeight.w700);
