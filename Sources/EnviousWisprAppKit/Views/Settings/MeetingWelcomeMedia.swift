import AVFoundation
import AppKit
import SwiftUI

/// The "how it works" slot on EnviousMeet's welcome screen (#4017 O7): the rendered video in the
/// app's language, muted and looping. The animated scene stands in when Reduce Motion is on
/// (it then shows the finished scene, still) and for a language without its own video, so the
/// slot never shows words in another language.
struct MeetingWelcomeMedia: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if !reduceMotion, let url = Self.videoURL() {
      MeetingWelcomeVideo(url: url)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.obBorder, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(Text(MeetingWelcomeAnimation.description))
    } else {
      MeetingWelcomeAnimation()
    }
  }

  /// The welcome video for the first of `languages` that has one (`MeetingWelcome-<code>.mp4`,
  /// `code` without region: "de-AT" uses "de"), or nil.
  static func videoURL(
    languages: [String] = Bundle.main.preferredLocalizations,
    find: (String) -> URL? = { Bundle.main.url(forResource: $0, withExtension: "mp4") }
  ) -> URL? {
    for language in languages {
      let code = language.split(separator: "-").first.map(String.init) ?? language
      if let url = find("MeetingWelcome-\(code)") { return url }
    }
    return nil
  }
}

/// A muted, looping player with no controls. It stops when the view goes away.
private struct MeetingWelcomeVideo: NSViewRepresentable {
  let url: URL

  final class PlayerView: NSView {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer

    init(url: URL) {
      playerLayer = AVPlayerLayer(player: player)
      super.init(frame: .zero)
      wantsLayer = true
      playerLayer.videoGravity = .resizeAspectFill
      layer = playerLayer
      player.isMuted = true
      player.preventsDisplaySleepDuringVideoPlayback = false
      looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
      player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Stops for good: no more looping, no queued items, no player on the layer.
    func stop() {
      player.pause()
      looper?.disableLooping()
      looper = nil
      player.removeAllItems()
      playerLayer.player = nil
    }
  }

  func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }

  func updateNSView(_ view: PlayerView, context: Context) {}

  static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
    view.stop()
  }
}
