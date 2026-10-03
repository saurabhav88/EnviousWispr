import EnviousWisprCore
import SwiftUI

/// A small static bar strip on each chime card (#3385, mockup 10).
///
/// **Decoration, not a picture of the sound.** The bars come from the pairing's NAME through
/// a fixed arithmetic hash, so each card has its own steady pattern on every render and every
/// launch. Nothing here reads the WAV, listens to audio, animates or runs a timer, and the
/// strip is hidden from VoiceOver and never takes a click.
struct RecordingChimeWaveform: View {
  let pairing: RecordingSoundPairing
  let isSelected: Bool

  static let barCount = 22

  /// Bar heights in 0.2...1, deterministic per pairing (FNV-1a over the raw value's bytes;
  /// `hashValue` is randomised per process and is never used).
  static func heights(for pairing: RecordingSoundPairing) -> [CGFloat] {
    var state: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in pairing.rawValue.utf8 {
      state = (state ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return (0..<barCount).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return 0.2 + 0.8 * CGFloat((state >> 33) % 1000) / 999
    }
  }

  var body: some View {
    let heights = Self.heights(for: pairing)
    let color = isSelected ? Color.stAccent : Color.stTextTertiary.opacity(0.55)
    // Drawn into whatever width the card leaves, so a narrow card never pushes the badge out.
    Canvas { context, size in
      let slot = size.width / CGFloat(heights.count)
      let barWidth = max(1.5, min(3, slot * 0.6))
      for (index, height) in heights.enumerated() {
        let barHeight = 4 + (size.height - 4) * height
        let rect = CGRect(
          x: CGFloat(index) * slot + (slot - barWidth) / 2,
          y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
      }
    }
    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
