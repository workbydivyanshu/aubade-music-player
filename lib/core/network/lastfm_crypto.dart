import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Last.fm API signing.
///
/// Ported from Kotlin LastWave `data/network/LastFmSigner.kt` (md5 of
/// sorted k+v + secret, skipping `format`, `callback`, `api_sig`).
class LastFmSigner {
  LastFmSigner._();

  /// Strip whitespace/invisible chars; lowercase hex-looking keys.
  static String normalizeKey(String raw) {
    final stripped = raw.replaceAll(RegExp(r'\s+'), '');
    return stripped.toLowerCase();
  }

  /// `md5(sorted(k+v concatenated) + secret)` lowercase hex.
  static String sign(Map<String, String> params, String secret) {
    final entries = params.entries
        .where((e) =>
            e.key != 'format' &&
            e.key != 'callback' &&
            e.key != 'api_sig' &&
            e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final buffer = StringBuffer();
    for (final e in entries) {
      buffer.write(e.key);
      buffer.write(e.value);
    }
    buffer.write(secret);
    return md5.convert(utf8.encode(buffer.toString())).toString();
  }

  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static String sha1Hex(String input) =>
      sha1.convert(utf8.encode(input)).toString();
}
