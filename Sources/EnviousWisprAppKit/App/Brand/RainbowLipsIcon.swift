import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

struct RainbowLipsIcon: View {
  let size: CGFloat
  /// Normalised audio level 0.0-1.0, updated every ~50 ms by the parent view.
  let audioLevel: Float
  /// When true, all bars turn red and pulse opacity (distress/interruption state).
  var isDistress: Bool = false

  private let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 22.25, 5, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (10, 17.6375, 8, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (16, 12.04, 12, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (22, 16.96, 9, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (28, 21.5575, 6, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (34, 16.96, 9, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (40, 12.04, 12, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (46, 17.6375, 8, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (52, 22.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  private let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 30.25, 5, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (10, 28.6375, 9, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (16, 27.04, 12, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (22, 28.96, 15, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (28, 30.5575, 17, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (34, 28.96, 15, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (40, 27.04, 12, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (46, 28.6375, 9, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (52, 30.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  // Per-bar sensitivity multipliers (index 0-8).
  // Center bars (index 4) react most; edge bars react least — mirrors the
  // centerDistance weighting used in MenuBarIconAnimator.renderRecordingLips.
  private let sensitivity: [CGFloat] = [0.70, 0.80, 0.90, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70]

  // Baseline scaleY when audio level is zero (lips lightly closed).
  private let silenceScale: CGFloat = 0.55

  // Maximum additional scaleY headroom above silence (reached at level = 1.0
  // for the most-sensitive bar). Chosen so peak scaleY ≈ 1.45 for center bars.
  private let peakRange: CGFloat = 0.90

  /// Compute the Y scale for a given bar index and the current audio level.
  /// Upper and lower bars share the same formula; the caller may pass a
  /// mirrored index to create counterpoint movement between the two lip halves.
  private func yScale(for barIndex: Int, level: CGFloat) -> CGFloat {
    silenceScale + peakRange * level * sensitivity[barIndex]
  }

  private static let distressRed = Color(red: 1.0, green: 0.165, blue: 0.251)

  var body: some View {
    if isDistress {
      // Distress mode: lips in normal shape, all bars red, pulsing opacity.
      // TimelineView drives continuous redraw; Canvas does not respond to @State animation.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let phase = timeline.date.timeIntervalSinceReferenceDate
        let pulseOpacity = 0.4 + 0.6 * (0.5 + 0.5 * sin(phase * .pi / 0.35))
        lipsCanvas(level: 0.3, barColorOverride: Self.distressRed)
          .opacity(pulseOpacity)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
    } else {
      lipsCanvas(level: CGFloat(min(max(audioLevel, 0), 1)), barColorOverride: nil)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }

  /// Shared Canvas renderer for both normal and distress modes.
  /// When `barColorOverride` is non-nil, all bars use that color instead of their rainbow colors.
  private func lipsCanvas(level: CGFloat, barColorOverride: Color?) -> some View {
    let scale = size / 64.0
    return Canvas { context, canvasSize in
      let maxSeparation = 3.5 * scale
      let barW = 4.5 * scale
      let cornerRadius = 1.5 * scale

      for i in 0..<upperBars.count {
        let bar = upperBars[i]
        let s = yScale(for: i, level: level)
        let scaledH = bar.h * scale * s
        let separation = -maxSeparation * level * sensitivity[i]
        let barBottom = (bar.y + bar.h) * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barBottom - scaledH,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }

      for i in 0..<lowerBars.count {
        let bar = lowerBars[i]
        let s = yScale(for: 8 - i, level: level)
        let scaledH = bar.h * scale * s
        let separation = maxSeparation * level * sensitivity[8 - i]
        let barTop = bar.y * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barTop,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }
    }
  }
}
