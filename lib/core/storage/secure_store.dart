import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure credential storage (session keys, cookies).
///
/// Uses OS keychain/credential-manager; falls back to in-memory on
/// platforms without a backend so the app keeps working.
class SecureStore {
  static const _sessionKey = 'aubade.session_key';
  static const _ytCookies = 'aubade.yt_cookies';
  static const _ytProfiles = 'aubade.yt_profiles';
  static const _ytActive = 'aubade.yt_active';

  // Pre-rebrand keys: read-only fallbacks, never deleted (harmless
  // residue keeps rollback to an older build forgiving).
  static const _legacySessionKey = 'lastwave.session_key';
  static const _legacyYtCookies = 'lastwave.yt_cookies';
  static const _legacyYtProfiles = 'lastwave.yt_profiles';
  static const _legacyYtActive = 'lastwave.yt_active';

  final FlutterSecureStorage _storage;
  final Map<String, String> _memoryFallback = {};

  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> _read(String key) async {
    try {
      final v = await _storage.read(key: key);
      if (v != null) return v;
    } catch (_) {
      // fall through to memory
    }
    return _memoryFallback[key];
  }

  Future<void> _write(String key, String? value) async {
    if (value == null) {
      _memoryFallback.remove(key);
      try {
        await _storage.delete(key: key);
      } catch (_) {}
      return;
    }
    _memoryFallback[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  /// New key first; on a miss, read the legacy key and write it
  /// forward (best-effort) before returning it. The legacy entry is
  /// intentionally left in place.
  Future<String?> _readForward(String key, String legacyKey) async {
    final current = await _read(key);
    if (current != null && current.isNotEmpty) return current;
    final legacy = await _read(legacyKey);
    if (legacy == null || legacy.isEmpty) return current ?? legacy;
    try {
      await _write(key, legacy);
    } catch (_) {}
    return legacy;
  }

  Future<String?> readSessionKey() =>
      _readForward(_sessionKey, _legacySessionKey);
  Future<void> writeSessionKey(String? v) => _write(_sessionKey, v);

  Future<String?> readYtCookies() =>
      _readForward(_ytCookies, _legacyYtCookies);
  Future<void> writeYtCookies(String? v) => _write(_ytCookies, v);

  /// Multi-profile roster (`YtProfile.listToJson`) + active pointer
  /// (`{"email": ..., "pageId": ...}`). The active jar itself stays in
  /// [_ytCookies], so single-profile behavior is unchanged.
  Future<String?> readYtProfiles() =>
      _readForward(_ytProfiles, _legacyYtProfiles);
  Future<void> writeYtProfiles(String? v) =>
      _write(_ytProfiles, v);

  Future<String?> readYtActive() =>
      _readForward(_ytActive, _legacyYtActive);
  Future<void> writeYtActive(String? v) => _write(_ytActive, v);

  Future<void> clearAll() async {
    _memoryFallback.clear();
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }
}

final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());
