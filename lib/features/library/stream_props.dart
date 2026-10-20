/// Stream properties mined straight from container headers.
///
/// `audiotags` 1.4.x exposes no stream properties at all, which left
/// `local_tracks.bitrate` / `sample_rate` permanently null. This file
/// reads only the first bytes of a file (bounded, synchronous, one
/// `RandomAccessFile`) and decodes what the container itself declares:
///
/// - FLAC : STREAMINFO first block — 20-bit sample rate, 3-bit channels,
///          5-bit bit depth (canonical layout, see `_decodeFlac`).
/// - WAV  : `fmt ` chunk — channels, sample rate, bits per sample.
/// - OGG  : OpusHead / Vorbis identification header (bit depth 0 —
///          lossy, never invented).
/// - MP3  : first valid Layer III frame header — sample rate + channel
///          mode (best effort; bit depth 0 — lossy).
/// - M4A  : `moov` → `stsd` → `mp4a`/`alac` AudioSampleEntry — sample
///          rate + channels (best effort; bit depth 0).
///
/// A zero value always means "unknown / not decoded"; nothing is ever
/// guessed from bitrate or extension. Every decode is wrapped in
/// try/catch and every IO error degrades to [StreamProps.unknown].
library;

import 'dart:io';
import 'dart:typed_data';

/// Decoded stream properties. `0` = unknown.
class StreamProps {
  const StreamProps({
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.channels = 0,
  });

  /// Sample rate in Hz, or 0 when unknown.
  final int sampleRate;

  /// Bits per sample (FLAC / WAV only), or 0 when unknown/lossy.
  final int bitDepth;

  /// Channel count, or 0 when unknown.
  final int channels;

  static const StreamProps unknown = StreamProps();
}

/// Reads [path]'s first header bytes and decodes stream properties.
///
/// Synchronous and bounded: a 64-byte sniff for every container, plus a
/// second sequential read for MP3 (4 KiB frame scan) and M4A (top-level
/// box walk to `moov`). Never throws; unreadable or unrecognized files
/// return [StreamProps.unknown].
StreamProps readStreamPropsSync(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final head = file.readSync(64);
    if (head.length < 12) return StreamProps.unknown;

    if (_magic(head, 0, 'fLaC')) return _decodeFlac(head);
    if (_magic(head, 0, 'RIFF') && _magic(head, 8, 'WAVE')) {
      return _decodeWav(head);
    }
    if (_magic(head, 0, 'OggS')) return _decodeOgg(head);
    if (_magic(head, 0, 'ID3') || head[0] == 0xFF) {
      // Frame-sync scan window: the sniffed head plus the rest of the
      // first 4 KiB, so a bare MP3 (no ID3 tag) sees its frame at 0.
      final tail = file.readSync(4096 - head.length);
      final window = Uint8List(head.length + tail.length)
        ..setRange(0, head.length, head)
        ..setRange(head.length, head.length + tail.length, tail);
      return _decodeMp3(window);
    }
    if (_magic(head, 4, 'ftyp')) return _decodeM4a(file);
    return StreamProps.unknown;
  } catch (_) {
    return StreamProps.unknown;
  } finally {
    try {
      file?.closeSync();
    } catch (_) {}
  }
}

/// Builds a plausible result: channels and sample rate must be sane
/// (8 kHz..768 kHz), anything else degrades to [StreamProps.unknown].
StreamProps _props(int sampleRate, int bitDepth, int channels) {
  if (sampleRate < 8000 || sampleRate > 768000 || channels <= 0) {
    return StreamProps.unknown;
  }
  return StreamProps(
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channels,
  );
}

/// FLAC (`fLaC`): the first metadata block must be STREAMINFO (byte 4
/// low 7 bits == 0). STREAMINFO payload starts at byte 8; the 64-bit
/// field at payload offset 10 (file bytes 18..25) packs, MSB first:
/// 20-bit sample rate, 3-bit channels-1, 5-bit bit depth-1, 36-bit
/// total samples. Decoded with the canonical bit-shift layout used by
/// libFLAC / dr_flac readers.
StreamProps _decodeFlac(Uint8List b) {
  if ((b[4] & 0x7F) != 0) return StreamProps.unknown;
  if (b.length < 42) return StreamProps.unknown;
  final rate = (b[18] << 12) | (b[19] << 4) | (b[20] >> 4);
  final channels = ((b[20] >> 1) & 0x07) + 1;
  final depth = (((b[20] & 0x01) << 4) | (b[21] >> 4)) + 1;
  return _props(rate, depth, channels);
}

/// WAV (`RIFF`/`WAVE`): walk the chunk table for `fmt ` (usually at
/// offset 12) and read the PCM fields — channels (payload +2), sample
/// rate (+4), bits per sample (+14). Needs a ≥16-byte fmt chunk.
StreamProps _decodeWav(Uint8List b) {
  var off = 12;
  while (off + 8 <= b.length) {
    final isFmt = b[off] == 0x66 &&
        b[off + 1] == 0x6D &&
        b[off + 2] == 0x74 &&
        b[off + 3] == 0x20;
    final size = _le32(b, off + 4);
    if (isFmt) {
      if (size < 16 || off + 24 > b.length) return StreamProps.unknown;
      final channels = _le16(b, off + 10);
      final rate = _le32(b, off + 12);
      final depth = _le16(b, off + 22);
      return _props(rate, depth, channels);
    }
    if (size <= 0) break;
    off += 8 + size;
  }
  return StreamProps.unknown;
}

/// OGG: first page body carries either an OpusHead or a Vorbis
/// identification header. The magic can sit behind a page header +
/// segment table, so scan for it instead of assuming a fixed offset.
/// OpusHead: channels at +9, input sample rate (LE u32) at +12; the
/// decoded rate is always 48 kHz, but the header's input rate is what
/// users see. Vorbis id: channels at +11, rate (LE u32) at +12.
/// Bit depth stays 0 — both are lossy codecs.
StreamProps _decodeOgg(Uint8List b) {
  final opus = _indexOf(b, 'OpusHead');
  if (opus >= 0 && opus + 16 <= b.length) {
    final rate = _le32(b, opus + 12);
    final channels = b[opus + 9];
    return _props(rate, 0, channels);
  }
  final vorbis = _indexOf(b, 'vorbis');
  if (vorbis >= 0 && vorbis + 16 <= b.length) {
    final channels = b[vorbis + 11];
    final rate = _le32(b, vorbis + 12);
    return _props(rate, 0, channels);
  }
  return StreamProps.unknown;
}

/// MPEG audio (MP3): scan the loaded window for the first valid Layer
/// III frame sync and decode the MPEG1/2/2.5 sample-rate table plus the
/// channel mode. Bit depth 0 — lossy. ID3v2 headers are skipped by
/// their syncsafe size when present.
StreamProps _decodeMp3(Uint8List b) {
  var start = 0;
  if (b.length >= 10 && _magic(b, 0, 'ID3')) {
    start = 10 +
        (((b[6] & 0x7F) << 21) |
            ((b[7] & 0x7F) << 14) |
            ((b[8] & 0x7F) << 7) |
            (b[9] & 0x7F));
  }
  const mpeg1 = [44100, 48000, 32000];
  const mpeg2 = [22050, 24000, 16000];
  const mpeg25 = [11025, 12000, 8000];
  for (var i = start; i + 4 <= b.length; i++) {
    if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
    final version = (b[i + 1] >> 3) & 0x03; // 0=2.5, 2=2, 3=1
    if (version == 1) continue; // Reserved.
    final layer = (b[i + 1] >> 1) & 0x03;
    if (layer != 1) continue; // Layer III only (bits 01).
    final bitrateIndex = (b[i + 2] >> 4) & 0x0F;
    if (bitrateIndex == 0 || bitrateIndex == 15) continue; // Free/bad.
    final rateIndex = (b[i + 2] >> 2) & 0x03;
    if (rateIndex == 3) continue; // Reserved.
    final rate = version == 3
        ? mpeg1[rateIndex]
        : version == 2
            ? mpeg2[rateIndex]
            : mpeg25[rateIndex];
    final channels = ((b[i + 3] >> 6) & 0x03) == 3 ? 1 : 2;
    return _props(rate, 0, channels);
  }
  return StreamProps.unknown;
}

/// M4A/MP4: walk top-level boxes (8-byte headers, seeking over
/// payloads) until `moov`, then scan its payload for `stsd` + the first
/// `mp4a` / `alac` AudioSampleEntry. Entry layout, relative to the
/// 'mp4a' magic: channels at +20 (BE u16), sample size at +22, sample
/// rate as 16.16 fixed point at +28 (upper 16 bits = Hz). Best effort:
/// any miss returns unknown.
StreamProps _decodeM4a(RandomAccessFile file) {
  final total = file.lengthSync();
  var pos = 0;
  while (pos + 8 <= total) {
    file.setPositionSync(pos);
    final hdr = file.readSync(8);
    if (hdr.length < 8) return StreamProps.unknown;
    final size = _u32be(hdr, 0);
    if (size < 8) return StreamProps.unknown; // 0 = to EOF, 1 = 64-bit.
    final type = String.fromCharCodes(hdr.sublist(4, 8));
    if (type == 'moov') {
      final want = size - 8;
      final readLen = want > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : want;
      return _decodeMoov(file.readSync(readLen));
    }
    pos += size;
  }
  return StreamProps.unknown;
}

StreamProps _decodeMoov(Uint8List b) {
  final stsd = _indexOf(b, 'stsd');
  final from = stsd < 0 ? 0 : stsd;
  var mp4a = _indexOfFrom(b, 'mp4a', from);
  if (mp4a < 0) mp4a = _indexOfFrom(b, 'alac', from);
  if (mp4a < 0 || mp4a + 32 > b.length) return StreamProps.unknown;
  final channels = (b[mp4a + 20] << 8) | b[mp4a + 21];
  final rate = (b[mp4a + 28] << 8) | b[mp4a + 29];
  return _props(rate, 0, channels);
}

bool _magic(Uint8List b, int off, String s) {
  if (off + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[off + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOf(Uint8List b, String s) => _indexOfFrom(b, s, 0);

int _indexOfFrom(Uint8List b, String s, int from) {
  final first = s.codeUnitAt(0);
  for (var i = from < 0 ? 0 : from; i + s.length <= b.length; i++) {
    if (b[i] != first) continue;
    var hit = true;
    for (var j = 1; j < s.length; j++) {
      if (b[i + j] != s.codeUnitAt(j)) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

int _le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

int _u32be(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
