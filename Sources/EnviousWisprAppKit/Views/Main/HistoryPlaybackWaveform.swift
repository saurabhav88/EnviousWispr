import SwiftUI

/// Actual audio levels under the native scrubber. The scrubber still owns focus, seeking
/// and VoiceOver. A missing preview leaves the scrubber in place.
struct HistoryPlaybackWaveform: View {
  let player: MeetingPlaybackController
  let positionMs: Int
  @State private var levels: [Float] = []

  var body: some View {
    Canvas { context, size in
      guard !levels.isEmpty else { return }
      let slot = size.width / CGFloat(levels.count)
      let width = min(4, slot * 0.62)
      let fraction = CGFloat(positionMs) / CGFloat(max(1, player.durationMs))
      for (index, level) in levels.enumerated() {
        let x = (CGFloat(index) + 0.5) * slot
        let height = DesignSpacing.xxs + CGFloat(level) * (size.height - DesignSpacing.xxs)
        let bar = CGRect(x: x - width / 2, y: (size.height - height) / 2, width: width, height: height)
        let tint = x <= fraction * size.width ? Color.stAccent : Color.stTextTertiary
        context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(tint))
      }
    }
    .frame(height: DesignSpacing.xxl)
    .padding(.horizontal, DesignSpacing.md)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
    .task(id: player.state == .unavailable) {
      let next = await player.waveform()
      guard !Task.isCancelled else { return }
      levels = next
    }
  }
}
