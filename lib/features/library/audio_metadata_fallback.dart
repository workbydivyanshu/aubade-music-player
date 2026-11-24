/// Pure-Dart, zero-dependency metadata reader.
///
/// `package:audiotags` is a thin FFI wrapper over Rust `lofty`, and its
/// 1.4.x bridge panics on unparseable numeric tags (notably
/// `bpm=null` / `TBPM=null` in Vorbis comments and ID3). When that
/// panic crosses FFI as an exception the Dart caller loses *every*
/// field — title, artist, album, artwork and duration — even though the
/// container metadata is perfectly readable.
///
/// This file reads the same containers directly in Dart:
///
/// - FLAC: `fLaC` metadata blocks — STREAMINFO (exact duration),
///   VORBIS_COMMENT (case-insensitive keys) and PICTURE.
/// - OGG: page/packet walk for the Vorbis comment packet or `OpusTags`,
///   with picture support via `metadata_block_picture` and a
///   last-page granule duration.
/// - MP3: ID3v2.3/2.4 text frames (`TIT2`, `TPE1`, `TALB`, `TPE2`,
///   `TRCK`, `TPOS`, `TDRC`/`TYER`, `TCON`, `TBPM`) and `APIC`.
///
/// Numeric fields use `tryParse`-style parsing exclusively: a value of
/// `"null"`, `"N/A"` or `""` becomes `null`, never an exception.
///
/// The reader is intentionally tolerant: malformed lengths, truncated
/// blocks and unreadable files return `null` or partial metadata. Only
/// the metadata section is read (plus a bounded tail for OGG duration),
/// never the audio stream.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata extracted without FFI.
class AudioMetadata {
  const AudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.genre,
    this.lyrics,
    this.bpm,
    this.duration = Duration.zero,
    this.picture,
    this.pictureMimeType,
    this.pictureType,
    this.pictureWidth,
    this.pictureHeight,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? genre;
  final String? lyrics;

  /// Parsed only when it is a real number; `"null"` is `null`.
  final double? bpm;

  /// Exact container duration when the format exposes it.
  final Duration duration;

  /// Raw embedded picture bytes, if any.
  final Uint8List? picture;
  final String? pictureMimeType;
  final int? pictureType;
  final int? pictureWidth;
  final int? pictureHeight;

  bool get hasPicture => picture != null && picture!.isNotEmpty;
}

/// Reads [path]'s container metadata in pure Dart.
///
/// Returns `null` only when the file is unreadable or its container is
/// not one of FLAC / OGG / ID3v2-tagged audio. Never throws.
Future<AudioMetadata?> readAudioMetadataFallback(String path) async {
  RandomAccessFile? file;
  try {
    final handle = File(path);
    if (!handle.existsSync()) return null;
    file = handle.openSync();
    final head = file.readSync(4);
    if (head.length < 4) return null;

    if (_magic(head, 0, 'fLaC')) return await _readFlac(file);
    if (_magic(head, 0, 'OggS')) return await _readOgg(file);
    if (_magic(head, 0, 'ID3')) return await _readId3(file);
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {}
  }
}

/// Parses a track filename such as `01 - Hit the Wall.flac`.
///
/// The leading number is separated from the title by whitespace, a dot,
/// an underscore or a hyphen (or any mix). A leading number that leaves
/// no title behind — e.g. `1979.mp3` — is kept as part of the title and
/// no track number is claimed.
class FilenameMetadata {
  const FilenameMetadata({required this.title, this.trackNumber});

  final String title;
  final int? trackNumber;
}

FilenameMetadata parseTrackFilename(String basenameWithoutExtension) {
  final raw = basenameWithoutExtension.trim();
  if (raw.isEmpty) return const FilenameMetadata(title: '');
  final match = RegExp(r'^(\d+)[\s.\-_]+(.*)$').firstMatch(raw);
  if (match == null) return FilenameMetadata(title: raw);
  final rest = match.group(2)?.trim() ?? '';
  if (rest.isEmpty) return FilenameMetadata(title: raw);
  return FilenameMetadata(
    title: rest,
    trackNumber: int.tryParse(match.group(1) ?? ''),
  );
}

/// Album/artist hints inferred from the folder layout.
class FolderMetadata {
  const FolderMetadata({this.album, this.artist});

  final String? album;
  final String? artist;
}

/// Infers album and artist from the directory name when tags are absent.
///
/// Two layouts are recognised:
///
/// - `Album - Artist/Track.flac` (single folder, e.g.
///   `Daughter from Hell (Deluxe) - Gracie Abrams`)
/// - `Artist/Album/Track.flac` (nested, e.g.
///   `Gracie Abrams/Daughter from Hell (Deluxe)`)
///
/// Generic roots (`Music`, `Downloads`, a home directory, temp dirs) are
/// never used as artist or album names.
FolderMetadata inferFolderMetadata(String path) {
  try {
    final parentPath = File(path).parent.path;
    final parent = _basename(parentPath);
    if (!_isUsefulFolder(parent)) return const FolderMetadata();

    final single = RegExp(r'^(.+?)\s+-\s+(.+)$').firstMatch(parent);
    if (single != null) {
      final album = single.group(1)?.trim() ?? '';
      final artist = single.group(2)?.trim() ?? '';
      if (_isUsefulFolder(album) && _isUsefulFolder(artist)) {
        return FolderMetadata(album: album, artist: artist);
      }
      return const FolderMetadata();
    }

    final grandParent = _basename(File(parentPath).parent.path);
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final homeName = home.isEmpty ? '' : _basename(home);
    if (!_isUsefulFolder(grandParent) ||
        grandParent.toLowerCase() == homeName.toLowerCase()) {
      return const FolderMetadata();
    }
    return FolderMetadata(album: parent, artist: grandParent);
  } catch (_) {
    return const FolderMetadata();
  }
}

const Set<String> _genericFolders = {
  'music',
  'musik',
  'audio',
  'media',
  'downloads',
  'desktop',
  'documents',
  'tmp',
  'temp',
  'home',
};

bool _isUsefulFolder(String name) {
  final clean = name.trim();
  if (clean.isEmpty || clean == '/' || clean == '.' || clean == '..') {
    return false;
  }
  return !_genericFolders.contains(clean.toLowerCase());
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

// ---------------------------------------------------------------------------
// FLAC
// ---------------------------------------------------------------------------

Future<AudioMetadata?> _readFlac(RandomAccessFile file) async {
  final total = file.lengthSync();
  final builder = _MetadataBuilder();
  var offset = 4; // past 'fLaC'
  var blocks = 0;

  while (offset + 4 <= total && blocks < 256) {
    file.setPositionSync(offset);
    final header = file.readSync(4);
    if (header.length < 4) break;
    final last = (header[0] & 0x80) != 0;
    final type = header[0] & 0x7F;
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    final start = offset + 4;
    if (length < 0 || start + length > total) break;

    if (type == 0 && length >= 34) {
      _parseStreamInfo(_readAt(file, start, 34), builder);
    } else if (type == 4 && length > 0) {
      _parseVorbisComment(_readAt(file, start, length), builder);
    } else if (type == 6 && length > 0) {
      final parsed = _parseFlacPicture(_readAt(file, start, length));
      if (parsed != null) builder.offerPicture(parsed);
    }

    if (last) break;
    offset = start + length;
    blocks++;
  }

  return builder.build();
}

void _parseStreamInfo(Uint8List p, _MetadataBuilder builder) {
  if (p.length < 18) return;
  final sampleRate = (p[10] << 12) | (p[11] << 4) | (p[12] >> 4);
  final totalSamples =
      ((p[13] & 0x0F) << 32) |
      (p[14] << 24) |
      (p[15] << 16) |
      (p[16] << 8) |
      p[17];
  if (sampleRate > 0 && totalSamples > 0) {
    builder.duration = Duration(
      milliseconds: (totalSamples * 1000) ~/ sampleRate,
    );
  }
}

void _parseVorbisComment(Uint8List bytes, _MetadataBuilder builder) {
  var pos = 0;

  // Vendor string (unused, but must be skipped).
  if (pos + 4 > bytes.length) return;
  final vendorLength = _le32(bytes, pos);
  pos += 4;
  if (vendorLength < 0 || pos + vendorLength > bytes.length) return;
  pos += vendorLength;

  if (pos + 4 > bytes.length) return;
  final count = _le32(bytes, pos);
  pos += 4;
  if (count < 0 || count > 100000) return;

  for (var i = 0; i < count; i++) {
    if (pos + 4 > bytes.length) break;
    final length = _le32(bytes, pos);
    pos += 4;
    if (length < 0 || pos + length > bytes.length) break;
    final entry = utf8.decode(
      Uint8List.sublistView(bytes, pos, pos + length),
      allowMalformed: true,
    );
    pos += length;

    final equals = entry.indexOf('=');
    if (equals <= 0) continue;
    final key = entry.substring(0, equals).trim().toLowerCase();
    final value = entry.substring(equals + 1).trim();
    builder.applyComment(key, value);
  }
}

_EmbeddedPicture? _parseFlacPicture(Uint8List bytes) {
  var pos = 0;
  try {
    if (pos + 4 > bytes.length) return null;
    final type = _u32be(bytes, pos);
    pos += 4;

    if (pos + 4 > bytes.length) return null;
    final mimeLength = _u32be(bytes, pos);
    pos += 4;
    if (mimeLength < 0 || pos + mimeLength > bytes.length) return null;
    final mime = latin1.decode(
      Uint8List.sublistView(bytes, pos, pos + mimeLength),
      allowInvalid: true,
    );
    pos += mimeLength;

    if (pos + 4 > bytes.length) return null;
    final descriptionLength = _u32be(bytes, pos);
    pos += 4;
    if (descriptionLength < 0 || pos + descriptionLength > bytes.length) {
      return null;
    }
    pos += descriptionLength; // Description is not displayed.

    if (pos + 20 > bytes.length) return null;
    final width = _u32be(bytes, pos);
    final height = _u32be(bytes, pos + 4);
    pos += 16; // width/height/depth/colors

    if (pos + 4 > bytes.length) return null;
    final dataLength = _u32be(bytes, pos);
    pos += 4;
    if (dataLength <= 0 || pos + dataLength > bytes.length) return null;
    final data = Uint8List.fromList(
      Uint8List.sublistView(bytes, pos, pos + dataLength),
    );
    if (data.isEmpty) return null;

    return _EmbeddedPicture(
      bytes: data,
      mimeType: mime.isEmpty ? 'image/jpeg' : mime,
      type: type,
      width: width,
      height: height,
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// OGG (Vorbis comments / OpusTags)
// ---------------------------------------------------------------------------

Future<AudioMetadata?> _readOgg(RandomAccessFile file) async {
  final total = file.lengthSync();
  final builder = _MetadataBuilder();
  var pos = 0;
  var packetIndex = 0;
  var pages = 0;
  var sawCommentPacket = false;
  var sampleRate = 0;
  var preSkip = 0;
  var isOpus = false;
  var packet = BytesBuilder(copy: false);

  // Comments and embedded pictures live in the first few pages; 8 MiB
  // is a generous bound that still never touches the audio payload.
  while (pos + 27 <= total && pos < 8 * 1024 * 1024 && pages < 1024) {
    file.setPositionSync(pos);
    final header = file.readSync(27);
    if (header.length < 27 || !_magic(header, 0, 'OggS')) break;
    final segmentCount = header[26];
    final segments = file.readSync(segmentCount);
    if (segments.length < segmentCount) break;

    var bodyLength = 0;
    for (final segment in segments) {
      bodyLength += segment;
    }
    final body = file.readSync(bodyLength);
    if (body.length < bodyLength) break;

    var bodyOffset = 0;
    for (var i = 0; i < segmentCount; i++) {
      final segment = segments[i];
      if (bodyOffset + segment > body.length) break;
      packet.add(Uint8List.sublistView(body, bodyOffset, bodyOffset + segment));
      bodyOffset += segment;
      if (segment == 255) continue; // Packet continues on the next lacing.

      final complete = packet.takeBytes();
      packet = BytesBuilder(copy: false);
      if (packetIndex == 0) {
        if (_magic(complete, 0, 'OpusHead') && complete.length >= 19) {
          isOpus = true;
          preSkip = _le16(complete, 10);
          sampleRate = _le32(complete, 12);
          if (sampleRate <= 0) sampleRate = 48000;
        } else if (complete.length >= 16 && _magic(complete, 1, 'vorbis')) {
          sampleRate = _le32(complete, 12);
        }
      } else if (!sawCommentPacket) {
        if (complete.length > 8 && _magic(complete, 1, 'vorbis')) {
          _parseVorbisComment(Uint8List.sublistView(complete, 7), builder);
          sawCommentPacket = true;
        } else if (_magic(complete, 0, 'OpusTags')) {
          _parseVorbisComment(Uint8List.sublistView(complete, 8), builder);
          sawCommentPacket = true;
        }
      }
      packetIndex++;
    }

    pos += 27 + segmentCount + bodyLength;
    pages++;
    if (sawCommentPacket && builder.picture != null) break;
  }

  if (sawCommentPacket) {
    final duration = _oggDuration(
      file,
      total,
      sampleRate: sampleRate,
      isOpus: isOpus,
      preSkip: preSkip,
    );
    if (duration > Duration.zero) builder.duration = duration;
    return builder.build();
  }
  return null;
}

Duration _oggDuration(
  RandomAccessFile file,
  int total, {
  required int sampleRate,
  required bool isOpus,
  required int preSkip,
}) {
  const tailLimit = 64 * 1024;
  final window = total < tailLimit ? total : tailLimit;
  if (window < 27) return Duration.zero;
  try {
    file.setPositionSync(total - window);
    final tail = file.readSync(window);
    for (var i = tail.length - 27; i >= 0; i--) {
      if (!_magic(tail, i, 'OggS')) continue;
      final granule = _le64(tail, i + 6);
      if (granule <= 0) continue;
      if (isOpus) {
        final samples = granule - preSkip;
        if (samples > 0) {
          return Duration(milliseconds: samples * 1000 ~/ 48000);
        }
      } else if (sampleRate > 0) {
        return Duration(milliseconds: granule * 1000 ~/ sampleRate);
      }
    }
  } catch (_) {}
  return Duration.zero;
}

// ---------------------------------------------------------------------------
// ID3v2
// ---------------------------------------------------------------------------

Future<AudioMetadata?> _readId3(RandomAccessFile file) async {
  file.setPositionSync(0);
  final header = file.readSync(10);
  if (header.length < 10 || !_magic(header, 0, 'ID3')) return null;
  final version = header[3];
  if (version < 3) return null; // v2.2 uses 3-byte frame IDs.
  final flags = header[5];
  var size = _syncsafe(header, 6);
  if (size <= 0) return null;
  const maxTag = 32 * 1024 * 1024;
  if (size > maxTag) size = maxTag;

  file.setPositionSync(10);
  var bytes = file.readSync(size);
  if (bytes.length < 10) return null;
  if ((flags & 0x80) != 0) bytes = _deunsynchronise(bytes);

  final builder = _MetadataBuilder();
  var pos = 0;

  // Extended header: v2.3 size excludes its own four bytes; v2.4's
  // syncsafe size includes them.
  if ((flags & 0x40) != 0 && bytes.length >= 4) {
    final extendedSize = version == 4
        ? _syncsafe(bytes, 0)
        : _u32be(bytes, 0) + 4;
    pos = extendedSize.clamp(0, bytes.length);
  }

  while (pos + 10 <= bytes.length) {
    if (bytes[pos] == 0) break; // Padding.
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;
    final frameSize = version == 4
        ? _syncsafe(bytes, pos + 4)
        : _u32be(bytes, pos + 4);
    final frameFlags = (bytes[pos + 8] << 8) | bytes[pos + 9];
    final start = pos + 10;
    if (frameSize <= 0 || start + frameSize > bytes.length) break;

    var payload = Uint8List.sublistView(bytes, start, start + frameSize);
    if (version == 4 && (frameFlags & 0x0002) != 0) {
      payload = _deunsynchronise(payload);
    }
    if (version == 4 && (frameFlags & 0x0001) != 0 && payload.length >= 4) {
      payload = Uint8List.sublistView(payload, 4);
    }

    switch (id) {
      case 'TIT2':
        builder.title = _decodeTextFrame(payload);
        break;
      case 'TPE1':
        builder.artist = _decodeTextFrame(payload);
        break;
      case 'TALB':
        builder.album = _decodeTextFrame(payload);
        break;
      case 'TPE2':
        builder.albumArtist = _decodeTextFrame(payload);
        break;
      case 'TRCK':
        builder.trackNumber = _parseLeadingInt(_decodeTextFrame(payload));
        break;
      case 'TPOS':
        builder.discNumber = _parseLeadingInt(_decodeTextFrame(payload));
        break;
      case 'TDRC':
      case 'TYER':
      case 'TDRL':
        builder.year ??= _parseYear(_decodeTextFrame(payload));
        break;
      case 'TCON':
        builder.genre = _decodeTextFrame(payload);
        break;
      case 'TBPM':
        builder.bpm = double.tryParse(_decodeTextFrame(payload));
        break;
      case 'APIC':
        final picture = _parseApicFrame(payload);
        if (picture != null) builder.offerPicture(picture);
        break;
    }

    pos = start + frameSize;
  }

  return builder.build();
}

String _decodeTextFrame(Uint8List payload) {
  if (payload.isEmpty) return '';
  final encoding = payload[0];
  final data = Uint8List.sublistView(payload, 1);
  String text;
  switch (encoding) {
    case 0:
      text = latin1.decode(data, allowInvalid: true);
      break;
    case 1:
      text = _decodeUtf16(data);
      break;
    case 2:
      text = _decodeUtf16(data, bigEndian: true);
      break;
    case 3:
      text = utf8.decode(data, allowMalformed: true);
      break;
    default:
      text = latin1.decode(data, allowInvalid: true);
  }
  return text.replaceAll('\u0000', '').trim();
}

String _decodeUtf16(Uint8List bytes, {bool bigEndian = false}) {
  var start = 0;
  var big = bigEndian;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      big = false;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      big = true;
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(
      big ? (bytes[i] << 8) | bytes[i + 1] : bytes[i] | (bytes[i + 1] << 8),
    );
  }
  return String.fromCharCodes(units);
}

_EmbeddedPicture? _parseApicFrame(Uint8List payload) {
  try {
    if (payload.length < 4) return null;
    final encoding = payload[0];
    var pos = 1;

    final mimeEnd = payload.indexOf(0, pos);
    if (mimeEnd < 0) return null;
    final mime = latin1.decode(
      Uint8List.sublistView(payload, pos, mimeEnd),
      allowInvalid: true,
    );
    pos = mimeEnd + 1;
    if (pos >= payload.length) return null;

    final type = payload[pos];
    pos++;

    if (encoding == 1 || encoding == 2) {
      while (pos + 1 < payload.length &&
          !(payload[pos] == 0 && payload[pos + 1] == 0)) {
        pos += 2;
      }
      pos += 2;
    } else {
      final descriptionEnd = payload.indexOf(0, pos);
      if (descriptionEnd < 0) return null;
      pos = descriptionEnd + 1;
    }
    if (pos >= payload.length) return null;

    final data = Uint8List.fromList(Uint8List.sublistView(payload, pos));
    if (data.isEmpty) return null;
    return _EmbeddedPicture(
      bytes: data,
      mimeType: mime.isEmpty ? 'image/jpeg' : mime,
      type: type,
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _EmbeddedPicture {
  const _EmbeddedPicture({
    required this.bytes,
    required this.mimeType,
    this.type,
    this.width,
    this.height,
  });

  final Uint8List bytes;
  final String mimeType;
  final int? type;
  final int? width;
  final int? height;
}

class _MetadataBuilder {
  String? title;
  String? artist;
  String? album;
  String? albumArtist;
  int? trackNumber;
  int? discNumber;
  int? year;
  String? genre;
  String? lyrics;
  double? bpm;
  Duration duration = Duration.zero;
  Uint8List? picture;
  String? pictureMimeType;
  int? pictureType;
  int? pictureWidth;
  int? pictureHeight;

  void applyComment(String key, String value) {
    switch (key) {
      case 'title':
        title ??= _nonEmpty(value);
        break;
      case 'artist':
        artist ??= _nonEmpty(value);
        break;
      case 'album':
        album ??= _nonEmpty(value);
        break;
      case 'albumartist':
      case 'album_artist':
      case 'album artist':
        albumArtist ??= _nonEmpty(value);
        break;
      case 'tracknumber':
      case 'track':
        trackNumber ??= _parseLeadingInt(value);
        break;
      case 'discnumber':
      case 'disc':
        discNumber ??= _parseLeadingInt(value);
        break;
      case 'date':
      case 'year':
        year ??= _parseYear(value);
        break;
      case 'genre':
        genre ??= _nonEmpty(value);
        break;
      case 'lyrics':
      case 'unsyncedlyrics':
      case 'unsynced_lyrics':
        lyrics ??= _nonEmpty(value);
        break;
      case 'bpm':
      case 'tbpm':
        // `double.tryParse` is the whole point: "null" -> null, no throw.
        bpm ??= double.tryParse(value);
        break;
      case 'metadata_block_picture':
        try {
          final parsed = _parseFlacPicture(base64.decode(value));
          if (parsed != null) offerPicture(parsed);
        } catch (_) {}
        break;
      case 'coverart':
        try {
          final data = base64.decode(value);
          if (data.isNotEmpty) {
            offerPicture(
              _EmbeddedPicture(
                bytes: data,
                mimeType: _nonEmpty(pictureMimeType ?? '') ?? 'image/jpeg',
                type: 3,
              ),
            );
          }
        } catch (_) {}
        break;
      case 'coverartmime':
        pictureMimeType ??= _nonEmpty(value);
        break;
    }
  }

  /// Prefers a front cover (picture type 3) over any earlier picture.
  void offerPicture(_EmbeddedPicture candidate) {
    if (candidate.bytes.isEmpty) return;
    final currentIsFront = pictureType == 3;
    final candidateIsFront = candidate.type == 3;
    if (picture == null || (candidateIsFront && !currentIsFront)) {
      picture = candidate.bytes;
      pictureMimeType = candidate.mimeType;
      pictureType = candidate.type;
      pictureWidth = candidate.width;
      pictureHeight = candidate.height;
    }
  }

  AudioMetadata build() => AudioMetadata(
    title: _nonEmpty(title),
    artist: _nonEmpty(artist),
    album: _nonEmpty(album),
    albumArtist: _nonEmpty(albumArtist),
    trackNumber: trackNumber,
    discNumber: discNumber,
    year: year,
    genre: _nonEmpty(genre),
    lyrics: _nonEmpty(lyrics),
    bpm: bpm,
    duration: duration,
    picture: picture,
    pictureMimeType: pictureMimeType,
    pictureType: pictureType,
    pictureWidth: pictureWidth,
    pictureHeight: pictureHeight,
  );
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _parseLeadingInt(String? value) {
  if (value == null) return null;
  final match = RegExp(r'\d+').firstMatch(value);
  return match == null ? null : int.tryParse(match.group(0) ?? '');
}

int? _parseYear(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  final exact = RegExp(r'^(\d{4})$').firstMatch(trimmed);
  if (exact != null) return int.tryParse(exact.group(1) ?? '');
  final leading = RegExp(r'^(\d{4})[-/.]').firstMatch(trimmed);
  return leading == null ? null : int.tryParse(leading.group(1) ?? '');
}

bool _magic(Uint8List bytes, int offset, String value) {
  if (offset < 0 || offset + value.length > bytes.length) return false;
  for (var i = 0; i < value.length; i++) {
    if (bytes[offset + i] != value.codeUnitAt(i)) return false;
  }
  return true;
}

Uint8List _readAt(RandomAccessFile file, int position, int length) {
  file.setPositionSync(position);
  return file.readSync(length);
}

Uint8List _deunsynchronise(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < bytes.length; i++) {
    out.addByte(bytes[i]);
    if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
      i++; // Drop the stuffed zero.
    }
  }
  return out.takeBytes();
}

int _syncsafe(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return ((bytes[offset] & 0x7F) << 21) |
      ((bytes[offset + 1] & 0x7F) << 14) |
      ((bytes[offset + 2] & 0x7F) << 7) |
      (bytes[offset + 3] & 0x7F);
}

int _u32be(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _le16(Uint8List bytes, int offset) {
  if (offset + 2 > bytes.length) return 0;
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _le32(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

int _le64(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return 0;
  var value = 0;
  for (var i = 7; i >= 0; i--) {
    value = (value << 8) | bytes[offset + i];
  }
  return value;
}
