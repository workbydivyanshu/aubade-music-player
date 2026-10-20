/// YouTube web sign-in flow — WebView dependency excised.
///
/// The system-WebView sign-in window (`desktop_webview_window`, and the
/// Linux native guard around it) was removed together with the BotGuard
/// poToken engine. Login now happens via the paste-cookies flow handled
/// in the settings UI; [YtWebLogin] survives only as a compile-compat
/// stub: every entry point keeps its previous signature from the
/// caller's perspective, but sign-in always returns null (no session
/// captured) and window helpers are no-ops.
class YtWebLogin {
  YtWebLogin._();

  /// Runs the sign-in flow. Stubbed: always returns null (cancelled).
  static Future<String?> signIn() async => null;

  /// Clean-room sign-in for adding another Google account. Stubbed.
  static Future<String?> signInFresh() => signIn();

  /// The cached login window's page ID type previously came from the
  /// webview package; stubs expose a plain dynamic null handle.
  static dynamic get cachedWindow => null;

  /// Ensure the window exists and is visible. Stubbed: no window can
  /// ever be available, so callers treat this as "no system WebView".
  static Future<dynamic> ensureWindow() async => null;

  /// Hide the window without destroying it. Stubbed no-op.
  static Future<void> hideWindow() async {}

  /// Reload the login page in the cached window. Stubbed no-op.
  static Future<void> reloadLoginPage() async {}

  /// Wait for a logged-in session in a driven window. Stubbed: always
  /// returns null (timeout / no window).
  static Future<String?> waitForLoginSession(
    dynamic webview, {
    Duration timeout = const Duration(minutes: 10),
  }) async => null;

  /// Page ID captured alongside the last successful sign-in (null =
  /// main channel). Never set since the WebView flow was excised.
  static String? lastCapturedPageId;

  /// Read the active channel's delegation page ID from the page.
  /// Stubbed: always null (main channel).
  static Future<String?> readDelegatedPageId(dynamic webview) async => null;

  /// Pure page-text matcher for the Google passkey stall. Unit-tested;
  /// kept behavior-pure so tests keep passing.
  static bool isPasskeyVerificationStall(String pageText) {
    final t = pageText.toLowerCase();
    return t.contains('verifying') && t.contains('passkey');
  }
}
