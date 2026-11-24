import Cocoa
import FlutterMacOS
import MediaPlayer

/// macOS counterpart of `windows/runner/smtc_channel.cpp`.
///
/// Serves the `aubade/smtc` method channel driven by
/// `lib/features/smtc/smtc_service.dart`: publishes track metadata and
/// the playback timeline to `MPNowPlayingInfoCenter` (menu bar Now
/// Playing, Control Center, lock screen, Bluetooth) and routes
/// `MPRemoteCommandCenter` button presses back to Dart as `onButton`.
///
/// Artwork is intentionally not published: `artUrl` is usually a remote
/// URL, and fetching it here would need its own download/cache policy
/// separate from the Flutter image cache. The metadata and timeline
/// still populate the system surfaces.
final class NowPlayingChannel: NSObject {
  private static let statusStopped = 0
  private static let statusPlaying = 1
  private static let statusChanging = 3

  private let channel: FlutterMethodChannel
  private let center = MPNowPlayingInfoCenter.default()
  private let commands = MPRemoteCommandCenter.shared()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "aubade/smtc",
      binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "update":
        if let args = call.arguments as? [String: Any] {
          self.update(args)
        }
        result(nil)
      case "clear":
        self.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    setupCommands()
  }

  // MARK: - Dart -> system

  private func update(_ args: [String: Any]) {
    let hasTrack = args["hasTrack"] as? Bool ?? false
    let status = (args["status"] as? NSNumber)?.intValue ?? Self.statusStopped

    // No track, or the player stopped: never leave a stale entry behind.
    guard hasTrack, status != Self.statusStopped else {
      clear()
      return
    }

    let positionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 0
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 0

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: args["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: durationMs / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: positionMs / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]

    // Stable per-track identifier, when Dart supplies one. The current
    // payload has no media id, so this stays absent rather than being
    // fabricated from the title.
    if let externalId = args["mediaId"] as? String, !externalId.isEmpty {
      info[MPNowPlayingInfoPropertyExternalContentIdentifier] = externalId
    }

    center.nowPlayingInfo = info
    // Buffering while playing still counts as playing (SMTC "Changing").
    center.playbackState =
      (status == Self.statusPlaying || status == Self.statusChanging)
      ? .playing : .paused

    setTransportEnabled(
      true,
      canNext: args["canNext"] as? Bool ?? false,
      canPrev: args["canPrev"] as? Bool ?? false)
  }

  private func clear() {
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    setTransportEnabled(false, canNext: false, canPrev: false)
  }

  // MARK: - System -> Dart

  private func setupCommands() {
    commands.playCommand.addTarget { [weak self] _ in
      self?.button("play") ?? .commandFailed
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      self?.button("pause") ?? .commandFailed
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.button("toggle") ?? .commandFailed
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      self?.button("next") ?? .commandFailed
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.button("previous") ?? .commandFailed
    }

    // No seek / skip / rate transport: Dart only handles `onButton`, so
    // those controls stay hidden instead of sending an unknown message.
    commands.stopCommand.isEnabled = false
    commands.changePlaybackPositionCommand.isEnabled = false
    commands.skipForwardCommand.isEnabled = false
    commands.skipBackwardCommand.isEnabled = false
    commands.seekForwardCommand.isEnabled = false
    commands.seekBackwardCommand.isEnabled = false
    commands.changePlaybackRateCommand.isEnabled = false

    setTransportEnabled(false, canNext: false, canPrev: false)
  }

  private func setTransportEnabled(
    _ enabled: Bool,
    canNext: Bool,
    canPrev: Bool
  ) {
    commands.playCommand.isEnabled = enabled
    commands.pauseCommand.isEnabled = enabled
    commands.togglePlayPauseCommand.isEnabled = enabled
    commands.nextTrackCommand.isEnabled = enabled && canNext
    commands.previousTrackCommand.isEnabled = enabled && canPrev
  }

  private func button(_ name: String) -> MPRemoteCommandHandlerStatus {
    // Command handlers may arrive off the main thread; the Flutter
    // channel must be invoked on the platform (main) thread.
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onButton", arguments: name)
    }
    return .success
  }
}
