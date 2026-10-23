import 'dart:convert';

/// Cross-process handoff identifiers shared by the Windows launcher and
/// pipe server.
const String windowsMutexName = 'aubade.handoff.mutex';
const String windowsPipeName = r'\\.\pipe\aubade.handoff';

/// A lone `.` line asks an already-running instance to raise its window
/// without opening any files.
const String windowsFocusMarker = '.';

/// Decoded contents of one pipe connection.
class WindowsOpenPipePayload {
  final List<String> paths;
  final bool focusRequested;

  const WindowsOpenPipePayload({
    this.paths = const <String>[],
    this.focusRequested = false,
  });

  bool get isEmpty => paths.isEmpty && !focusRequested;
}

/// Encodes file paths for the handoff pipe: one UTF-8 path per line,
/// each terminated by CRLF. A focus request appends a lone `.` line.
String encodeWindowsOpenPipePayload(
  List<String> paths, {
  bool focus = false,
}) {
  final buffer = StringBuffer();
  for (final path in paths) {
    final clean = path.replaceAll(RegExp(r'[\r\n]'), '').trim();
    if (clean.isEmpty) continue;
    buffer
      ..write(clean)
      ..write('\r\n');
  }
  if (focus) {
    buffer
      ..write(windowsFocusMarker)
      ..write('\r\n');
  }
  return buffer.toString();
}

/// Bytes on the wire for one handoff payload.
List<int> encodeWindowsOpenPipeBytes(
  List<String> paths, {
  bool focus = false,
}) =>
    utf8.encode(encodeWindowsOpenPipePayload(paths, focus: focus));

/// Decodes CRLF (or plain LF) separated pipe text. Blank lines are
/// ignored; a line that is exactly `.` becomes a focus request.
WindowsOpenPipePayload decodeWindowsOpenPipePayload(String text) {
  final paths = <String>[];
  var focus = false;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final value = line.trim();
    if (value.isEmpty) continue;
    if (value == windowsFocusMarker) {
      focus = true;
      continue;
    }
    paths.add(value);
  }
  return WindowsOpenPipePayload(paths: paths, focusRequested: focus);
}
