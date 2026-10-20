import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui/theme/tokens.dart';

/// Settings + session persistence.
///
/// Key names mirror Kotlin LastWave `SettingsPreferences` /
/// `SessionPreferences` (`lw_*`) so behaviour stays comparable.
class Prefs {
  final SharedPreferences _sp;
  Prefs(this._sp);

  static Future<Prefs> load() async =>
      Prefs(await SharedPreferences.getInstance());

  // -- Last.fm BYOK (bring your own keys) ---------------------------------
  // No bundled API keys ship with the app: the user enters their own
  // Last.fm API key + shared secret (from last.fm/api/account/create),
  // stored here in SharedPreferences. All Last.fm features stay
  // disabled until both are set.
  String get lastFmApiKey => _sp.getString('lw_lastfm_api_key') ?? '';
  String get lastFmApiSecret => _sp.getString('lw_lastfm_api_secret') ?? '';
  bool get isLastFmConfigured =>
      lastFmApiKey.isNotEmpty && lastFmApiSecret.isNotEmpty;

  Future<void> saveLastFmKeys({
    required String apiKey,
    required String apiSecret,
  }) async {
    await _sp.setString('lw_lastfm_api_key', apiKey);
    await _sp.setString('lw_lastfm_api_secret', apiSecret);
  }

  Future<void> clearLastFmKeys() async {
    await _sp.remove('lw_lastfm_api_key');
    await _sp.remove('lw_lastfm_api_secret');
  }

  // -- Guest mode (keyless entry) -------------------------------------------
  // Set by the welcome Skip button: the user enters the shell without
  // Last.fm keys or session. Everything except Last.fm features works;
  // reconnect happens in Settings only. Sticky across restarts; cleared
  // by full sign-out and by saving a real session.
  bool get isGuest => _sp.getBool('lw_guest_mode') ?? false;
  Future<void> setGuestMode(bool v) =>
      _sp.setBool('lw_guest_mode', v);

  // -- Last.fm session (web auth under the user's own API key) ------------
  // Authentication is compulsory: there is no guest or anonymous mode.
  // A session is valid only when both the username and the session key
  // are stored. Session keys are bound to the API key that minted them,
  // so saving different API keys signs the session out (see
  // AuthRepository.saveCustomKeys).
  String get sessionKey => _sp.getString('lw_sessionkey') ?? '';
  String get username => _sp.getString('lw_username') ?? '';
  bool get isAuthenticated => username.isNotEmpty && sessionKey.isNotEmpty;

  Future<void> saveSession({
    required String sessionKey,
    required String username,
  }) async {
    await _sp.setString('lw_sessionkey', sessionKey);
    await _sp.setString('lw_username', username);
    // Drop any legacy guest flag from older builds.
    await _sp.remove('lw_guest_mode');
  }

  Future<void> signOut() async {
    await _sp.remove('lw_sessionkey');
    await _sp.remove('lw_username');
    await _sp.remove('lw_guest_mode');
  }

  // -- Audio quality (mirrors Android quality tiers) ---------------------
  /// -1 = YouTube only, 5 = 320k MP3, 6 = 16/44.1 FLAC,
  /// 7 = 24/96, 27 = 24/192.
  static const allowedQualities = [-1, 5, 6, 7, 27];

  bool get preferLossless =>
      _sp.getBool('lw_prefer_lossless_streaming') ?? true;
  int get losslessQuality =>
      _clampQuality(_sp.getInt('lw_lossless_quality') ?? 27);
  int get downloadQuality =>
      _clampQuality(_sp.getInt('lw_download_quality') ?? 27);

  static int _clampQuality(int q) => allowedQualities.contains(q) ? q : 27;

  Future<void> setPreferLossless(bool v) =>
      _sp.setBool('lw_prefer_lossless_streaming', v);
  Future<void> setLosslessQuality(int q) =>
      _sp.setInt('lw_lossless_quality', _clampQuality(q));
  Future<void> setDownloadQuality(int q) =>
      _sp.setInt('lw_download_quality', _clampQuality(q));
  // -- Window behaviour ---------------------------------------------------
  /// Close button / Alt+F4 hides to the tray instead of quitting.
  /// Real quit stays in tray → Quit (ordered player teardown first).
  /// Default on.
  bool get closeToTray =>
      _sp.getBool('lw_close_to_tray') ?? true;
  Future<void> setCloseToTray(bool v) =>
      _sp.setBool('lw_close_to_tray', v);

  // -- Playback behaviour -------------------------------------------------
  /// Keep playing similar tracks (endless radio) after a queue runs
  /// out. Default on — matches Spotify/YTM autoplay behaviour.
  bool get autoplaySimilar =>
      _sp.getBool('lw_autoplay_similar') ?? true;
  Future<void> setAutoplaySimilar(bool v) =>
      _sp.setBool('lw_autoplay_similar', v);

  bool get crossfadeEnabled => _sp.getBool('lw_crossfade_enabled') ?? false;
  int get crossfadeSeconds {
    final v = _sp.getInt('lw_crossfade_seconds') ?? 5;
    return v.clamp(1, 12);
  }

  Future<void> setCrossfade(bool enabled, [int? seconds]) async {
    await _sp.setBool('lw_crossfade_enabled', enabled);
    if (seconds != null) {
      await _sp.setInt('lw_crossfade_seconds', seconds.clamp(1, 12));
    }
  }

  bool get bitPerfect => _sp.getBool('lw_bit_perfect') ?? false;
  Future<void> setBitPerfect(bool v) => _sp.setBool('lw_bit_perfect', v);

  // -- ReplayGain + resampling (local audiophile chain) --------------------
  /// ReplayGain mode: 'off' | 'track' | 'album'.
  String get replayGainMode =>
      _sp.getString('audio_replaygain_mode') ?? 'off';
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
  String get audioDeviceId => _sp.getString('lw_audio_device_id') ?? '';
  Future<void> setAudioDeviceId(String v) =>
      _sp.setString('lw_audio_device_id', v);

  bool get wasapiExclusive => _sp.getBool('lw_wasapi_exclusive') ?? false;
  Future<void> setWasapiExclusive(bool v) =>
      _sp.setBool('lw_wasapi_exclusive', v);

  // -- Appearance: ambient artwork glow ------------------------------------
  /// "The whole app wears the record": dual-orb ambient mesh behind the
  /// page content, driven by the playing artwork's palette. Default on.
  bool get ambientGlowEnabled => _sp.getBool('lw_ambient_glow') ?? true;
  Future<void> setAmbientGlowEnabled(bool v) =>
      _sp.setBool('lw_ambient_glow', v);

  // -- Spotlight: recent searches --------------------------------------------
  /// Newest-first list of recent Spotlight text searches (max 8, trimmed
  /// by the caller). Persisted so empty-query chips survive restarts.
  List<String> get recentSearches =>
      _sp.getStringList('lw_recent_searches') ?? const [];
  Future<void> saveRecentSearches(List<String> v) =>
      _sp.setStringList('lw_recent_searches', v.take(8).toList());

  // -- Library maintenance ------------------------------------------------------
  /// One-shot flag: stream-props header backfill (sample rate / bit depth
  /// / avg bitrate / file size) was computed for all local_tracks rows.
  bool get streamPropsBackfilled =>
      _sp.getBool('lw_streamprops_backfilled') ?? false;
  Future<void> markStreamPropsBackfilled() =>
      _sp.setBool('lw_streamprops_backfilled', true);

  bool get downloadLyrics => _sp.getBool('lw_download_lyrics') ?? true;
  Future<void> setDownloadLyrics(bool v) =>
      _sp.setBool('lw_download_lyrics', v);

  /// Custom download folder. Empty = default (`Music/Aubade`, else
  /// app documents). Set via Settings → Downloads or the Downloads
  /// page; changeable at any time, applies to new downloads.
  ///
  /// A stored value that is exactly the old documented default
  /// (`Music/LastWave`) is treated as unset so the new platform default
  /// applies. Custom user paths are never rewritten.
  String get downloadDir {
    final v = _sp.getString('lw_download_dir') ?? '';
    if (v == 'Music/LastWave' || v == 'Music\\LastWave') return '';
    return v;
  }
  Future<void> setDownloadDir(String v) =>
      _sp.setString('lw_download_dir', v.trim());
  Future<void> resetDownloadDir() =>
      _sp.remove('lw_download_dir');

  // -- Local library (watched folders) --------------------------------------
  /// Folders the local library scanner watches. Persisted under an
  /// `aubade_` prefix (local-first data, not a Kotlin LastWave parity
  /// setting).
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
    await setMusicFolders(
      musicFolders.where((f) => f != folder).toList(),
    );
  }

  // -- Lyrics --------------------------------------------------------------
  bool get wordByWord => _sp.getBool('lw_word_by_word') ?? true;
  Future<void> setWordByWord(bool v) => _sp.setBool('lw_word_by_word', v);

  /// Primary lyrics provider id (`auto` default). Explicit picks get a
  /// head start; the rest of the chain stays as automatic fallback.
  String get lyricsProviderId =>
      _sp.getString('lw_lyrics_provider') ?? 'auto';
  Future<void> setLyricsProviderId(String v) =>
      _sp.setString('lw_lyrics_provider', v);

  String get lyricsAnimation =>
      _sp.getString('lw_lyrics_animation') ?? 'apple_fluid';
  Future<void> setLyricsAnimation(String v) =>
      _sp.setString('lw_lyrics_animation', v);

  // -- Appearance ------------------------------------------------------------
  bool get amoled => _sp.getBool('lw_amoled') ?? false;
  Future<void> setAmoled(bool v) => _sp.setBool('lw_amoled', v);

  /// 'dark' (midnight observatory) or 'light' (pearl white).
  String get themeMode => _sp.getString('lw_theme_mode') ?? 'dark';
  Future<void> setThemeMode(String v) => _sp.setString('lw_theme_mode', v);
  bool get isLight => themeMode == 'light';

  String get accentMode => _sp.getString('lw_accent_mode') ?? 'manual';
  Future<void> setAccentMode(String v) => _sp.setString('lw_accent_mode', v);

  int get accentColor =>
      _sp.getInt('lw_accent') ?? WaveColors.defaultAccent.toARGB32();
  Future<void> setAccentColor(int v) => _sp.setInt('lw_accent', v);

  bool get dynamicNowPlaying => _sp.getBool('lw_dynamic_now_playing') ?? false;
  Future<void> setDynamicNowPlaying(bool v) =>
      _sp.setBool('lw_dynamic_now_playing', v);

  // -- Haze / material (spec §42 — only settings that actually work) ------
  /// 'automatic' | 'haze' | 'solid'. Solid disables BackdropFilter
  /// everywhere (static tonal fallback); automatic uses Haze L1–L3 as
  /// designed, honouring reduce-transparency.
  String get hazeMaterial => _sp.getString('lw_haze_material') ?? 'automatic';
  Future<void> setHazeMaterial(String v) =>
      _sp.setString('lw_haze_material', v);

  /// 'low' | 'medium' | 'high'. Scales L1–L3 blur sigma.
  String get hazeIntensity => _sp.getString('lw_haze_intensity') ?? 'medium';
  Future<void> setHazeIntensity(String v) =>
      _sp.setString('lw_haze_intensity', v);

  /// Accent source: 'system' | 'aubade' | 'artwork' | 'custom'.
  /// 'manual' (legacy) is treated as 'custom'. The theme controller
  /// resolves the effective accent; artwork mode tints from the current
  /// palette seed where available, otherwise falls back to custom.
  /// Stored `'lastwave'` values are read-mapped to `'aubade'` (not
  /// rewritten; the next explicit change persists the new value).
  String get accentSource {
    final v =
        _sp.getString('lw_accent_source') ??
        _sp.getString('lw_accent_mode') ??
        'custom';
    if (v == 'manual') return 'custom';
    if (v == 'lastwave') return 'aubade';
    return v;
  }

  Future<void> setAccentSource(String v) async {
    await _sp.setString('lw_accent_source', v);
    await _sp.setString('lw_accent_mode', v);
  }

  bool get liquidGlass => _sp.getBool('lw_liquid_glass') ?? false;
  Future<void> setLiquidGlass(bool v) => _sp.setBool('lw_liquid_glass', v);

  bool get wavySeekbar => _sp.getBool('lw_wavy_seekbar') ?? false;
  Future<void> setWavySeekbar(bool v) => _sp.setBool('lw_wavy_seekbar', v);

  // -- Scrobbler --------------------------------------------------------------
  bool get scrobblerEnabled => _sp.getBool('lw_scrobbler_enabled') ?? false;
  bool get scrobbleNowPlaying => _sp.getBool('lw_submit_now_playing') ?? true;
  int get scrobblePercent {
    final v = _sp.getInt('lw_scrobble_percent') ?? 50;
    return v.clamp(25, 90);
  }

  Future<void> setScrobbler({
    bool? enabled,
    bool? nowPlaying,
    int? percent,
  }) async {
    if (enabled != null) {
      await _sp.setBool('lw_scrobbler_enabled', enabled);
    }
    if (nowPlaying != null) {
      await _sp.setBool('lw_submit_now_playing', nowPlaying);
    }
    if (percent != null) {
      await _sp.setInt('lw_scrobble_percent', percent.clamp(25, 90));
    }
  }

  // -- YouTube Music --------------------------------------------------------
  /// Push played tracks into the account's YT Music watch history.
  /// Default off: writing to the Google account is opt-in.
  bool get syncYtHistory => _sp.getBool('lw_sync_yt_history') ?? false;

  Future<void> setSyncYtHistory(bool v) =>
      _sp.setBool('lw_sync_yt_history', v);

  /// Skip BotGuard poToken minting entirely (direct-URL clients only).
  /// Default off (poTokens enabled). Escape hatch for machines where the
  /// hidden `Aubade BotGuard` WebView misbehaves: playback then never
  /// opens a WebView and fails open to direct streams; some
  /// ciphered-only tracks may not resolve.
  bool get disablePoToken => _sp.getBool('lw_disable_potoken') ?? false;

  Future<void> setDisablePoToken(bool v) =>
      _sp.setBool('lw_disable_potoken', v);

  // -- Desktop-app Parity (Karaoke Lyrics & Visualizer & CD Mode) ------------
  int getLyricsOffset(String trackKey) =>
      _sp.getInt('lw_lyrics_offset_$trackKey') ?? 0;

  Future<void> setLyricsOffset(String trackKey, int offsetMs) =>
      _sp.setInt('lw_lyrics_offset_$trackKey', offsetMs);

  Future<void> resetLyricsOffset(String trackKey) =>
      _sp.remove('lw_lyrics_offset_$trackKey');

  bool get lyricsTransliteration =>
      _sp.getBool('lw_lyrics_transliteration') ?? true;

  Future<void> setLyricsTransliteration(bool v) =>
      _sp.setBool('lw_lyrics_transliteration', v);

  bool get visualizerEnabled => _sp.getBool('lw_visualizer_enabled') ?? true;

  Future<void> setVisualizerEnabled(bool v) =>
      _sp.setBool('lw_visualizer_enabled', v);

  bool get cdMode => _sp.getBool('lw_cd_mode') ?? false;

  Future<void> setCdMode(bool v) => _sp.setBool('lw_cd_mode', v);

  // -- Discord Rich Presence --------------------------------------------------
  /// Show the current track in Discord status. Default on (Spotify parity).
  bool get discordRichPresence =>
      _sp.getBool('lw_discord_rich_presence') ?? true;

  Future<void> setDiscordRichPresence(bool v) =>
      _sp.setBool('lw_discord_rich_presence', v);

  // -- Addon sources (personal addon URLs) ----------------------------------
  /// User-pasted addon roots (`{base}/a/<token>/`), JSON-encoded.
  List<String> get addonUrls {
    final raw = _sp.getString('lw_addon_urls') ?? '';
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
    'lw_addon_urls',
    jsonEncode(urls.map((e) => e.trim()).where((e) => e.isNotEmpty).toList()),
  );
}

final prefsProvider = Provider<Prefs>((_) {
  throw UnimplementedError('Prefs not initialised — override in main()');
});
