/// Audio formats the player can open directly from disk.
///
/// Shared by the "Open with Aubade" entry points (command line, the
/// org.freedesktop.Application handoff and the Windows pipe handoff) and
/// by the drag-and-drop surface in the shell, so every local file path
/// is accepted by exactly the same rules.
///
/// Extension comparison is case-insensitive and tolerant of the
/// surrounding quotes that shell file associations sometimes keep.
const List<String> playableAudioExtensions = <String>[
  'mp3',
  'flac',
  'm4a',
  'aac',
  'opus',
  'ogg',
  'wav',
];

/// Video containers the drag-and-drop surface has always accepted (the
/// player only reads their audio track). Kept out of the "Open with"
/// list so file associations stay audio-only, but shared here so the
/// drop path and the open path cannot drift apart.
const List<String> dropOnlyAudioExtensions = <String>[
  'mp4',
  'webm',
];

/// Everything the packaging lanes may register as an "Open with"
/// handler. Superset of [playableAudioExtensions]: formats that are
/// handled by the OS association but may fail to decode are still
/// better routed here than to another app.
const List<String> registerableAudioExtensions = <String>[
  'mp3',
  'flac',
  'ogg',
  'opus',
  'oga',
  'm4a',
  'm4b',
  'wav',
  'aiff',
  'aif',
  'aifc',
  'wma',
  'aac',
  'ape',
  'wv',
  'mka',
];

/// MIME types the desktop packaging registers for "Open with Aubade".
///
/// Kept in the same order as the Linux desktop entry so the runtime
/// claim written from Settings offers exactly what a package install
/// offers. Shared by the Linux claim writer and the make-default action.
const List<String> registerableAudioMimeTypes = <String>[
  'audio/mpeg',
  'audio/flac',
  'audio/ogg',
  'audio/opus',
  'audio/x-opus+ogg',
  'audio/mp4',
  'audio/x-m4a',
  'audio/wav',
  'audio/x-wav',
  'audio/vnd.wave',
  'audio/aiff',
  'audio/x-aiff',
  'audio/x-ape',
  'audio/x-wavpack',
  'audio/x-ms-wma',
  'audio/x-musepack',
  'audio/x-matroska',
  'audio/aac',
  'audio/x-flac',
];

/// True when [path] names a file the player is willing to open.
///
/// Only the extension is inspected; callers that care about existence
/// check the filesystem themselves.
bool isSupportedAudioPath(String path) =>
    _hasExtension(path, playableAudioExtensions);

/// True when [path] is accepted by the drag-and-drop surface. Same
/// audio list plus the video containers the shell has always allowed.
bool isSupportedDropPath(String path) =>
    _hasExtension(path, playableAudioExtensions) ||
    _hasExtension(path, dropOnlyAudioExtensions);

/// Strips one layer of matching single or double quotes.
String stripSurroundingQuotes(String value) {
  if (value.length < 2) return value;
  final first = value[0];
  final last = value[value.length - 1];
  if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

bool _hasExtension(String path, List<String> allowed) {
  final clean = stripSurroundingQuotes(path.trim());
  final dot = clean.lastIndexOf('.');
  if (dot < 0 || dot == clean.length - 1) return false;
  final ext = clean.substring(dot + 1).toLowerCase();
  return allowed.contains(ext);
}
