import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private static let openWithChannelName = "aubade/open_with"

  private var openWithChannel: FlutterMethodChannel?
  private var pendingOpenPaths: [String] = []
  private var hasFinishedLaunching = false

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidFinishLaunchingNotification(_:)),
      name: NSApplication.didFinishLaunchingNotification,
      object: nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Finder delivers opened documents through this selector on macOS 10.13+.
  // File URLs go to Dart as raw paths; other URLs keep the framework's
  // existing deep-link handling.
  override func application(_ application: NSApplication, open urls: [URL]) {
    var filePaths: [String] = []
    var otherURLs: [URL] = []
    for url in urls {
      if url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
        filePaths.append(url.path)
      } else {
        otherURLs.append(url)
      }
    }

    if !filePaths.isEmpty {
      for path in filePaths where !pendingOpenPaths.contains(path) {
        pendingOpenPaths.append(path)
      }
      if hasFinishedLaunching {
        flushPendingOpenPaths()
      }
    }

    if !otherURLs.isEmpty {
      super.application(application, open: otherURLs)
    }
  }

  @objc private func handleDidFinishLaunchingNotification(_ notification: Notification) {
    hasFinishedLaunching = true
    flushPendingOpenPaths()
  }

  // The channel can only be built once the Flutter view controller exists.
  // Paths that arrived earlier stay queued until a flush can reach Dart.
  private func flushPendingOpenPaths() {
    guard !pendingOpenPaths.isEmpty else {
      return
    }

    let channel: FlutterMethodChannel
    if let existingChannel = openWithChannel {
      channel = existingChannel
    } else {
      guard let flutterViewController =
        mainFlutterWindow?.contentViewController as? FlutterViewController else {
        return
      }
      let newChannel = FlutterMethodChannel(
        name: AppDelegate.openWithChannelName,
        binaryMessenger: flutterViewController.engine.binaryMessenger)
      openWithChannel = newChannel
      channel = newChannel
    }

    let paths = pendingOpenPaths
    pendingOpenPaths.removeAll()
    channel.invokeMethod("files", arguments: paths)
  }
}
