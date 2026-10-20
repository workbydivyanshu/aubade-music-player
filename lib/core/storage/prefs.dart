import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui/theme/tokens.dart';

/// Legacy (`lw_*`, Kotlin LastWave parity) → current (`aubade_*`) pref keys.
///
/// Strategy: migrate on startup, never on read. [Prefs.migrateLegacyKeys]
/// copies each legacy value to its new key, then removes the legacy key.
/// If both keys exist the `aubade_*` value wins (written by a newer build)
/// and only the stale legacy copy is deleted. A second run is a no-op:
/// nothing matches the legacy keys any more, and no data is ever dropped
/// before the new key is written.
const Map<String, String> _legacyPrefKeys = {
  'lw_lastfm_api_key': 'aubade_lastfm_api_key',
  'lw_lastfm_api_secret': 'aubade_lastfm_api_secret',
  'lw_guest_mode': 'aubade_guest_mode',
  'lw_sessionkey': 'aubade_sessionkey',
  'lw_username': 'aubade_username',
  'lw_prefer_lossless_streaming': 'aubade_prefer_lossless_streaming',
  'lw_lossless_quality': 'aubade_lossless_quality',
  'lw_download_quality': 'aubade_download_quality',
  'lw_close_to_tray': 'aubade_close_to_tray',
  'lw_autoplay_similar': 'aubade_autoplay_similar',
  'lw_crossfade_enabled': 'aubade_crossfade_enabled',
  'lw_crossfade_seconds': 'aubade_crossfade_seconds',
  'lw_bit_perfect': 'aubade_bit_perfect',
  'lw_audio_device_id': 'aubade_audio_device_id',
  'lw_wasapi_exclusive': 'aubade_wasapi_exclusive',
  'lw_ambient_glow': 'aubade_ambient_glow',
  'lw_recent_searches': 'aubade_recent_searches',
  'lw_streamprops_backfilled': 'aubade_streamprops_backfilled',
  'lw_download_lyrics': 'aubade_download_lyrics',
  'lw_download_dir': 'aubade_download_dir',
  'lw_word_by_word': 'aubade_word_by_word',
  'lw_lyrics_provider': 'aubade_lyrics_provider',
  'lw_lyrics_animation': 'aubade_lyrics_animation',
  'lw_amoled': 'aubade_amoled',
  'lw_theme_mode': 'aubade_theme_mode',
  'lw_accent_mode': 'aubade_accent_mode',
  'lw_accent': 'aubade_accent',
  'lw_dynamic_now_playing': 'aubade_dynamic_now_playing',
  'lw_haze_material': 'aubade_haze_material',
  'lw_haze_intensity': 'aubade_haze_intensity',
  'lw_accent_source': 'aubade_accent_source',
  'lw_liquid_glass': 'aubade_liquid_glass',
  'lw_wavy_seekbar': 'aubade_wavy_seekbar',
  'lw_scrobbler_enabled': 'aubade_scrobbler_enabled',
  'lw_submit_now_playing': 'aubade_submit_now_playing',
  'lw_scrobble_percent': 'aubade_scrobble_percent',
  'lw_sync_yt_history': 'aubade_sync_yt_history',
  'lw_disable_potoken': 'aubade_disable_potoken',
  'lw_lyrics_transliteration': 'aubade_lyrics_transliteration',
  'lw_visualizer_enabled': 'aubade_visualizer_enabled',
  'lw_cd_mode': 'aubade_cd_mode',
  'lw_discord_rich_presence': 'aubade_discord_rich_presence',
  'lw_addon_urls': 'aubade_addon_urls',
};

/// Per-track lyrics offsets carry a dynamic suffix, so they are migrated
/// by prefix instead of by the fixed table above.
const String _legacyLyricsOffsetPrefix = 'lw_lyrics_offset_';
const String _lyricsOffsetPrefix = 'aubade_lyrics_offset_';

/// Settings + session persistence.
///
/// Key names use the `aubade_*` prefix. Pre-rebrand `lw_*` keys are moved
/// once at startup by [Prefs.migrateLegacyKeys].
class Prefs {
  final SharedPreferences _sp;
  Prefs(this._sp);

  static Future<Prefs> load() async {
    final sp = await SharedPreferences.getInstance();
    await migrateLegacyKeys(sp);
    return Prefs(sp);
  }

  /// One-time, idempotent move of legacy `lw_*` prefs to `aubade_*`.
  ///
  /// Values are copied before the legacy key is removed, so an interrupted
  /// run cannot lose data; the next startup simply retries. Existing
  /// `aubade_*` values are never overwritten (safe when both keys exist).
  static Future<void> migrateLegacyKeys(SharedPreferences sp) async {
    try {
      for (final entry in _legacyPrefKeys.entries) {
        try {
          await _migrateKey(sp, entry.key, entry.value);
        } catch (_) {
          // Best-effort per key: leave the legacy value for the next launch.
        }
      }
      for (final key in sp.getKeys().toList()) {
        if (!key.startsWith(_legacyLyricsOffsetPrefix)) continue;
        try {
          await _migrateKey(
            sp,
            key,
            '$_lyricsOffsetPrefix'
                '${key.substring(_legacyLyricsOffsetPrefix.length)}',
          );
        } catch (_) {
          // Best-effort per key: leave the legacy value for the next launch.
        }
      }
    } catch (_) {
      // Migration is best-effort and must never block startup: a failure
      // here leaves the legacy keys in place for the next launch.
    }
  }

  /// Copies one value with its original type, then drops the legacy key.
  ///
  /// The legacy key is removed only after the platform confirms the write
  /// (`setX` returning true). A failed or unknown-type write leaves the
  /// legacy value untouched so the next launch retries it.
  static Future<void> _migrateKey(
    SharedPreferences sp,
    String legacy,
    String current,
  ) async {
    final value = sp.get(legacy);
    if (value == null) return;
    if (sp.containsKey(current)) {
      // A newer build already wrote the new key; only the stale copy goes.
      await sp.remove(legacy);
      return;
    }
    final bool written;
    if (value is String) {
      written = await sp.setString(current, value);
    } else if (value is bool) {
      written = await sp.setBool(current, value);
    } else if (value is int) {
      written = await sp.setInt(current, value);
    } else if (value is double) {
      written = await sp.setDouble(current, value);
    } else if (value is List) {
      // Desktop stores round-trip lists as `List<dynamic>` (Linux/Windows
      // JSON decode, macOS NSArray), never as `List<String>`. Validate the
      // elements and keep the legacy key if any of them is not a String.
      final strings = <String>[];
      for (final element in value) {
        if (element is! String) return;
        strings.add(element);
      }
      written = await sp.setStringList(current, strings);
    } else {
      // Unknown type: leave the legacy key for a future build to handle.
      return;
    }
    if (written) await sp.remove(legacy);
  }

  // -- Last.fm BYOK (bring your own keys) ---------------------------------
  // No bundled API keys ship with the app: the user enters their own
  // Last.fm API key + shared secret (from last.fm/api/account/create),
  // stored here in SharedPreferences. All Last.fm features stay
  // disabled until both are set.
  String get lastFmApiKey => _sp.getString('aubade_lastfm_api_key') ?? '';
  String get lastFmApiSecret => _sp.getString('aubade_lastfm_api_secret') ?? '';
  bool get isLastFmConfigured =>
      lastFmApiKey.isNotEmpty && lastFmApiSecret.isNotEmpty;

  Future<void> saveLastFmKeys({
    required String apiKey,
    required String apiSecret,
  }) async {
    await _sp.setString('aubade_lastfm_api_key', apiKey);
    await _sp.setString('aubade_lastfm_api_secret', apiSecret);
  }

  Future<void> clearLastFmKeys() async {
    await _sp.remove('aubade_lastfm_api_key');
    await _sp.remove('aubade_lastfm_api_secret');
  }

  // -- Guest mode (keyless entry) -------------------------------------------
  // Set by the welcome Skip button: the user enters the shell without
  // Last.fm keys or session. Everything except Last.fm features works;
  // reconnect happens in Settings only. Sticky across restarts; cleared
  // by full sign-out and by saving a real session.
  bool get isGuest => _sp.getBool('aubade_guest_mode') ?? false;
  Future<void> setGuestMode(bool v) => _sp.setBool('aubade_guest_mode', v);

  // -- Last.fm session (web auth under the user's own API key) ------------
  // Authentication is compulsory: there is no guest or anonymous mode.
  // A session is valid only when both the username and the session key
  // are stored. Session keys are bound to the API key that minted them,
  // so saving different API keys signs the session out (see
  // AuthRepository.saveCustomKeys).
  String get sessionKey => _sp.getString('aubade_sessionkey') ?? '';
  String get username => _sp.getString('aubade_username') ?? '';
  bool get isAuthenticated => username.isNotEmpty && sessionKey.isNotEmpty;

  Future<void> saveSession({
    required String sessionKey,
    required String username,
  }) async {
    await _sp.setString('aubade_sessionkey', sessionKey);
    await _sp.setString('aubade_username', username);
    // Drop any legacy guest flag from older builds.
    await _sp.remove('aubade_guest_mode');
  }

  Future<void> signOut() async {
    await _sp.remove('aubade_sessionkey');
    await _sp.remove('aubade_username');
    await _sp.remove('aubade_guest_mode');
  }

  // -- Audio quality (mirrors Android quality tiers) ---------------------
  /// -1 = YouTube only, 5 = 320k MP3, 6 = 16/44.1 FLAC,
  /// 7 = 24/96, 27 = 24/192.
  static const allowedQualities = [-1, 5, 6, 7, 27];

  bool get preferLossless =>
      _sp.getBool('aubade_prefer_lossless_streaming') ?? true;
  int get losslessQuality =>
      _clampQuality(_sp.getInt('aubade_lossless_quality') ?? 27);
  int get downloadQuality =>
      _clampQuality(_sp.getInt('aubade_download_quality') ?? 27);

  static int _clampQuality(int q) => allowedQualities.contains(q) ? q : 27;

  Future<void> setPreferLossless(bool v) =>
      _sp.setBool('aubade_prefer_lossless_streaming', v);
  Future<void> setLosslessQuality(int q) =>
      _sp.setInt('aubade_lossless_quality', _clampQuality(q));
  Future<void> setDownloadQuality(int q) =>
      _sp.setInt('aubade_download_quality', _clampQuality(q));
  // -- Window behaviour ---------------------------------------------------
  /// Close button / Alt+F4 hides to the tray instead of quitting.
  /// Real quit stays in tray → Quit (ordered player teardown first).
  /// Default on.
  bool get closeToTray => _sp.getBool('aubade_close_to_tray') ?? true;
  Future<void> setCloseToTray(bool v) => _sp.setBool('aubade_close_to_tray', v);

  // -- Playback behaviour -------------------------------------------------
  /// Keep playing similar tracks (endless radio) after a queue runs
  /// out. Default on — matches Spotify/YTM autoplay behaviour.
  bool get autoplaySimilar => _sp.getBool('aubade_autoplay_similar') ?? true;
  Future<void> setAutoplaySimilar(bool v) =>
      _sp.setBool('aubade_autoplay_similar', v);

  bool get crossfadeEnabled => _sp.getBool('aubade_crossfade_enabled') ?? false;
  int get crossfadeSeconds {
    final v = _sp.getInt('aubade_crossfade_seconds') ?? 5;
    return v.clamp(1, 12);
  }

  Future<void> setCrossfade(bool enabled, [int? seconds]) async {
    await _sp.setBool('aubade_crossfade_enabled', enabled);
    if (seconds != null) {
      await _sp.setInt('aubade_crossfade_seconds', seconds.clamp(1, 12));
    }
  }

  bool get bitPerfect => _sp.getBool('aubade_bit_perfect') ?? false;
  Future<void> setBitPerfect(bool v) => _sp.setBool('aubade_bit_perfect', v);

  // -- ReplayGain + resampling (local audiophile chain) --------------------
  /// ReplayGain mode: 'off' | 'track' | 'album'.
  String get replayGainMode => _sp.getString('audio_replaygain_mode') ?? 'off';
  Future<void> setReplayGainMode(String mode) =>
      _sp.setString('audio_replaygain_mode', mode);

  /// ReplayGain pre-amp in dB (-12 … +12).
  double get replayGainPreamp =>
      _sp.getDouble('audio_replaygain_preamp') ?? 0.0;
  Future<void> setReplayGainPreamp(double v) =>
      _sp.setDouble('audio_replaygain_preamp', v);

  /// True-peak limiter for ReplayGain (mpv `replaygain-clip`). Default on.
  bool get replayGainPreventClipping =>
      _sp.getBool('audio_replaygain_clip') ?? true;
  Future<void> setReplayGainPreventClipping(bool v) =>
      _sp.setBool('audio_replaygain_clip', v);

  /// Resampling: 'native' (untouched source rate) | 'sox96' | 'sox192'.
  String get audioResampleMode =>
      _sp.getString('audio_resample_mode') ?? 'native';
  Future<void> setAudioResampleMode(String v) =>
      _sp.setString('audio_resample_mode', v);

  /// Empty = Windows default render endpoint.
  String get audioDeviceId => _sp.getString('aubade_audio_device_id') ?? '';
  Future<void> setAudioDeviceId(String v) =>
      _sp.setString('aubade_audio_device_id', v);

  bool get wasapiExclusive => _sp.getBool('aubade_wasapi_exclusive') ?? false;
  Future<void> setWasapiExclusive(bool v) =>
      _sp.setBool('aubade_wasapi_exclusive', v);

  // -- Appearance: ambient artwork glow ------------------------------------
  /// "The whole app wears the record": dual-orb ambient mesh behind the
  /// page content, driven by the playing artwork's palette. Default on.
  bool get ambientGlowEnabled => _sp.getBool('aubade_ambient_glow') ?? true;
  Future<void> setAmbientGlowEnabled(bool v) =>
      _sp.setBool('aubade_ambient_glow', v);

  // -- Spotlight: recent searches --------------------------------------------
  /// Newest-first list of recent Spotlight text searches (max 8, trimmed
  /// by the caller). Persisted so empty-query chips survive restarts.
  List<String> get recentSearches =>
      _sp.getStringList('aubade_recent_searches') ?? const [];
  Future<void> saveRecentSearches(List<String> v) =>
      _sp.setStringList('aubade_recent_searches', v.take(8).toList());

  // -- Library maintenance ------------------------------------------------------
  /// One-shot flag: stream-props header backfill (sample rate / bit depth
  /// / avg bitrate / file size) was computed for all local_tracks rows.
  bool get streamPropsBackfilled =>
      _sp.getBool('aubade_streamprops_backfilled') ?? false;
  Future<void> markStreamPropsBackfilled() =>
      _sp.setBool('aubade_streamprops_backfilled', true);

  bool get downloadLyrics => _sp.getBool('aubade_download_lyrics') ?? true;
  Future<void> setDownloadLyrics(bool v) =>
      _sp.setBool('aubade_download_lyrics', v);

  /// Custom download folder. Empty = default (`Music/Aubade`, else
  /// app documents). Set via Settings → Downloads or the Downloads
  /// page; changeable at any time, applies to new downloads.
  ///
  /// A stored value that is exactly the old documented default
  /// (`Music/LastWave`) is treated as unset so the new platform default
  /// applies. Custom user paths are never rewritten.
  String get downloadDir {
    final v = _sp.getString('aubade_download_dir') ?? '';
    if (v == 'Music/LastWave' || v == 'Music\\LastWave') return '';
    return v;
  }

  Future<void> setDownloadDir(String v) =>
      _sp.setString('aubade_download_dir', v.trim());
  Future<void> resetDownloadDir() => _sp.remove('aubade_download_dir');

  // -- Local library (watched folders) --------------------------------------
  /// Folders the local library scanner watches (local-first data).
  List<String> get musicFolders =>
      _sp.getStringList('aubade_music_folders') ?? const [];

  Future<void> setMusicFolders(List<String> folders) =>
      _sp.setStringList('aubade_music_folders', folders);

  Future<void> addMusicFolder(String folder) async {
    final trimmed = folder.trim();
    if (trimmed.isEmpty) return;
    final folders = List<String>.from(musicFolders);
    if (folders.contains(trimmed)) return;
    folders.add(trimmed);
    await setMusicFolders(folders);
  }

  Future<void> removeMusicFolder(String folder) async {
    await setMusicFolders(musicFolders.where((f) => f != folder).toList());
  }

  // -- Lyrics --------------------------------------------------------------
  bool get wordByWord => _sp.getBool('aubade_word_by_word') ?? true;
  Future<void> setWordByWord(bool v) => _sp.setBool('aubade_word_by_word', v);

  /// Primary lyrics provider id (`auto` default). Explicit picks get a
  /// head start; the rest of the chain stays as automatic fallback.
  String get lyricsProviderId =>
      _sp.getString('aubade_lyrics_provider') ?? 'auto';
  Future<void> setLyricsProviderId(String v) =>
      _sp.setString('aubade_lyrics_provider', v);

  String get lyricsAnimation =>
      _sp.getString('aubade_lyrics_animation') ?? 'apple_fluid';
  Future<void> setLyricsAnimation(String v) =>
      _sp.setString('aubade_lyrics_animation', v);

  // -- Appearance ------------------------------------------------------------
  bool get amoled => _sp.getBool('aubade_amoled') ?? false;
  Future<void> setAmoled(bool v) => _sp.setBool('aubade_amoled', v);

  /// 'dark' (midnight observatory) or 'light' (pearl white).
  String get themeMode => _sp.getString('aubade_theme_mode') ?? 'dark';
  Future<void> setThemeMode(String v) => _sp.setString('aubade_theme_mode', v);
  bool get isLight => themeMode == 'light';

  String get accentMode => _sp.getString('aubade_accent_mode') ?? 'manual';
  Future<void> setAccentMode(String v) =>
      _sp.setString('aubade_accent_mode', v);

  int get accentColor =>
      _sp.getInt('aubade_accent') ?? WaveColors.defaultAccent.toARGB32();
  Future<void> setAccentColor(int v) => _sp.setInt('aubade_accent', v);

  bool get dynamicNowPlaying =>
      _sp.getBool('aubade_dynamic_now_playing') ?? false;
  Future<void> setDynamicNowPlaying(bool v) =>
      _sp.setBool('aubade_dynamic_now_playing', v);

  // -- Haze / material (spec §42 — only settings that actually work) ------
  /// 'automatic' | 'haze' | 'solid'. Solid disables BackdropFilter
  /// everywhere (static tonal fallback); automatic uses Haze L1–L3 as
  /// designed, honouring reduce-transparency.
  String get hazeMaterial =>
      _sp.getString('aubade_haze_material') ?? 'automatic';
  Future<void> setHazeMaterial(String v) =>
      _sp.setString('aubade_haze_material', v);

  /// 'low' | 'medium' | 'high'. Scales L1–L3 blur sigma.
  String get hazeIntensity =>
      _sp.getString('aubade_haze_intensity') ?? 'medium';
  Future<void> setHazeIntensity(String v) =>
      _sp.setString('aubade_haze_intensity', v);

  /// Accent source: 'system' | 'aubade' | 'artwork' | 'custom'.
  /// 'manual' (legacy) is treated as 'custom'. The theme controller
  /// resolves the effective accent; artwork mode tints from the current
  /// palette seed where available, otherwise falls back to custom.
  /// Stored `'lastwave'` values are read-mapped to `'aubade'` (not
  /// rewritten; the next explicit change persists the new value).
  String get accentSource {
    final v =
        _sp.getString('aubade_accent_source') ??
        _sp.getString('aubade_accent_mode') ??
        'custom';
    if (v == 'manual') return 'custom';
    if (v == 'lastwave') return 'aubade';
    return v;
  }

  Future<void> setAccentSource(String v) async {
    await _sp.setString('aubade_accent_source', v);
    await _sp.setString('aubade_accent_mode', v);
  }

  bool get liquidGlass => _sp.getBool('aubade_liquid_glass') ?? false;
  Future<void> setLiquidGlass(bool v) => _sp.setBool('aubade_liquid_glass', v);

  bool get wavySeekbar => _sp.getBool('aubade_wavy_seekbar') ?? false;
  Future<void> setWavySeekbar(bool v) => _sp.setBool('aubade_wavy_seekbar', v);

  // -- Scrobbler --------------------------------------------------------------
  bool get scrobblerEnabled => _sp.getBool('aubade_scrobbler_enabled') ?? false;
  bool get scrobbleNowPlaying =>
      _sp.getBool('aubade_submit_now_playing') ?? true;
  int get scrobblePercent {
    final v = _sp.getInt('aubade_scrobble_percent') ?? 50;
    return v.clamp(25, 90);
  }

  Future<void> setScrobbler({
    bool? enabled,
    bool? nowPlaying,
    int? percent,
  }) async {
    if (enabled != null) {
      await _sp.setBool('aubade_scrobbler_enabled', enabled);
    }
    if (nowPlaying != null) {
      await _sp.setBool('aubade_submit_now_playing', nowPlaying);
    }
    if (percent != null) {
      await _sp.setInt('aubade_scrobble_percent', percent.clamp(25, 90));
    }
  }

  // -- YouTube Music --------------------------------------------------------
  /// Push played tracks into the account's YT Music watch history.
  /// Default off: writing to the Google account is opt-in.
  bool get syncYtHistory => _sp.getBool('aubade_sync_yt_history') ?? false;

  Future<void> setSyncYtHistory(bool v) =>
      _sp.setBool('aubade_sync_yt_history', v);

  /// Skip BotGuard poToken minting entirely (direct-URL clients only).
  /// Default off (poTokens enabled). Escape hatch for machines where the
  /// hidden `Aubade BotGuard` WebView misbehaves: playback then never
  /// opens a WebView and fails open to direct streams; some
  /// ciphered-only tracks may not resolve.
  bool get disablePoToken => _sp.getBool('aubade_disable_potoken') ?? false;

  Future<void> setDisablePoToken(bool v) =>
      _sp.setBool('aubade_disable_potoken', v);

  // -- Desktop-app Parity (Karaoke Lyrics & Visualizer & CD Mode) ------------
  int getLyricsOffset(String trackKey) =>
      _sp.getInt('aubade_lyrics_offset_$trackKey') ?? 0;

  Future<void> setLyricsOffset(String trackKey, int offsetMs) =>
      _sp.setInt('aubade_lyrics_offset_$trackKey', offsetMs);

  Future<void> resetLyricsOffset(String trackKey) =>
      _sp.remove('aubade_lyrics_offset_$trackKey');

  bool get lyricsTransliteration =>
      _sp.getBool('aubade_lyrics_transliteration') ?? true;

  Future<void> setLyricsTransliteration(bool v) =>
      _sp.setBool('aubade_lyrics_transliteration', v);

  bool get visualizerEnabled =>
      _sp.getBool('aubade_visualizer_enabled') ?? true;

  Future<void> setVisualizerEnabled(bool v) =>
      _sp.setBool('aubade_visualizer_enabled', v);

  bool get cdMode => _sp.getBool('aubade_cd_mode') ?? false;

  Future<void> setCdMode(bool v) => _sp.setBool('aubade_cd_mode', v);

  // -- Discord Rich Presence --------------------------------------------------
  /// Show the current track in Discord status. Default on (Spotify parity).
  bool get discordRichPresence =>
      _sp.getBool('aubade_discord_rich_presence') ?? true;

  Future<void> setDiscordRichPresence(bool v) =>
      _sp.setBool('aubade_discord_rich_presence', v);

  // -- Addon sources (personal addon URLs) ----------------------------------
  /// User-pasted addon roots (`{base}/a/<token>/`), JSON-encoded.
  List<String> get addonUrls {
    final raw = _sp.getString('aubade_addon_urls') ?? '';
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> setAddonUrls(List<String> urls) => _sp.setString(
    'aubade_addon_urls',
    jsonEncode(urls.map((e) => e.trim()).where((e) => e.isNotEmpty).toList()),
  );
}

final prefsProvider = Provider<Prefs>((_) {
  throw UnimplementedError('Prefs not initialised — override in main()');
});
