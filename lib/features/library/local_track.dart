import '../../core/audio/stream_models.dart';

/// A track resolved from the local filesystem.
///
/// `path` (absolute file path) is the primary key. Tag metadata comes from
/// `package:audiotags`; `artworkPath` points either to a companion image next
/// to the file or to a cached extract of an embedded picture.
class LocalTrack {
  /// Absolute file path — primary key.
  final String path;

  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? genre;

  /// Playback duration.
  final Duration duration;

  /// Audio bitrate (kbps) and sample rate (Hz). audiotags 1.4.x does not
  /// expose stream properties, so both stay `null` unless populated from
  /// the container header (see `stream_props.dart`).
  final int? bitrate;
  final int? sampleRate;

  /// Bits per sample (lossless containers only) and on-disk file size in
  /// bytes; both `null` until a header sniff / stat fills them in.
  final int? bitDepth;
  final int? sizeBytes;

  /// Lower-case file extension without the leading dot
  /// (`flac`, `mp3`, `m4a`, `opus`, `ogg`, `wav`).
  final String format;

  /// Local cached thumbnail path, if any.
  final String? artworkPath;

  /// Whether the file carries an embedded picture (regardless of caching).
  final bool hasEmbeddedArt;

  /// File modified time, milliseconds since the epoch.
  final int modifiedAt;

  LocalTrack({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.genre,
    required this.duration,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.sizeBytes,
    required this.format,
    this.artworkPath,
    required this.hasEmbeddedArt,
    required this.modifiedAt,
  });

  /// Converts this track into a queue item for playback.
  PlayableTrack toPlayableTrack() => PlayableTrack(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        artworkUrl: artworkPath != null ? 'file://$artworkPath' : '',
        playbackUrl: path,
        durationSeconds: duration.inSeconds,
      );

  /// Serializes to SQLite-friendly values. [duration] is stored as
  /// milliseconds; booleans as 0/1.
  Map<String, dynamic> toMap() => {
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'album_artist': albumArtist,
        'track_number': trackNumber,
        'disc_number': discNumber,
        'year': year,
        'genre': genre,
        'duration_ms': duration.inMilliseconds,
        'bitrate': bitrate,
        'sample_rate': sampleRate,
        'bit_depth': bitDepth,
        'size_bytes': sizeBytes,
        'format': format,
        'artwork_path': artworkPath,
        'has_embedded_art': hasEmbeddedArt ? 1 : 0,
        'modified_at': modifiedAt,
      };

  factory LocalTrack.fromMap(Map<String, dynamic> m) => LocalTrack(
        path: m['path'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        album: m['album'] as String,
        albumArtist: m['album_artist'] as String? ?? '',
        trackNumber: m['track_number'] as int?,
        discNumber: m['disc_number'] as int?,
        year: m['year'] as int?,
        genre: m['genre'] as String?,
        duration: Duration(
          milliseconds: (m['duration_ms'] as num?)?.toInt() ?? 0,
        ),
        bitrate: m['bitrate'] as int?,
        sampleRate: m['sample_rate'] as int?,
        bitDepth: m['bit_depth'] as int?,
        sizeBytes: m['size_bytes'] as int?,
        format: m['format'] as String,
        artworkPath: m['artwork_path'] as String?,
        hasEmbeddedArt: (m['has_embedded_art'] as int?) == 1,
        modifiedAt: (m['modified_at'] as num?)?.toInt() ?? 0,
      );

  /// Copy with the given fields replaced; omitted fields keep their
  /// current value. `null` cannot clear a field — this class only ever
  /// copies to fill values in.
  LocalTrack copyWith({
    String? path,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? trackNumber,
    int? discNumber,
    int? year,
    String? genre,
    Duration? duration,
    int? bitrate,
    int? sampleRate,
    int? bitDepth,
    int? sizeBytes,
    String? format,
    String? artworkPath,
    bool? hasEmbeddedArt,
    int? modifiedAt,
  }) =>
      LocalTrack(
        path: path ?? this.path,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        albumArtist: albumArtist ?? this.albumArtist,
        trackNumber: trackNumber ?? this.trackNumber,
        discNumber: discNumber ?? this.discNumber,
        year: year ?? this.year,
        genre: genre ?? this.genre,
        duration: duration ?? this.duration,
        bitrate: bitrate ?? this.bitrate,
        sampleRate: sampleRate ?? this.sampleRate,
        bitDepth: bitDepth ?? this.bitDepth,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        format: format ?? this.format,
        artworkPath: artworkPath ?? this.artworkPath,
        hasEmbeddedArt: hasEmbeddedArt ?? this.hasEmbeddedArt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
      );
}
