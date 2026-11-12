import AppKit
import SwiftUI

// MARK: - SpectrumWheelIcon

/// 12 rainbow-colored bars arranged radially, spinning slowly.
///
/// Under macOS Reduce Motion the wheel holds still (#4528, DESIGN.md Motion: gate every
/// animation on Reduce Motion). Every surface that shows it also draws a text label beside it
/// (`PolishingOverlayView`, `ColdStartNoticeView`), so the still wheel loses no information.
struct SpectrumWheelIcon: View {
  let size: CGFloat
  /// Test hook: reports the spin decision each time it changes (360 spinning, 0 parked).
  var onSpinTarget: ((Double) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private let bars: [(deg: Double, yOffset: CGFloat, height: CGFloat, color: Color)] = [
    (0, 4, 14, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (30, 7, 10, Color(red: 1.0, green: 0.624, blue: 0.039)),
    (60, 5, 12, Color(red: 1.0, green: 0.839, blue: 0.039)),
    (90, 8, 9, Color(red: 0.188, green: 0.82, blue: 0.345)),
    (120, 4, 14, Color(red: 0.204, green: 0.78, blue: 0.349)),
    (150, 6, 11, Color(red: 0.196, green: 0.847, blue: 0.745)),
    (180, 5, 13, Color(red: 0.392, green: 0.824, blue: 1.0)),
    (210, 8, 9, Color(red: 0.039, green: 0.518, blue: 1.0)),
    (240, 4, 14, Color(red: 0.369, green: 0.361, blue: 0.902)),
    (270, 6, 12, Color(red: 0.749, green: 0.353, blue: 0.949)),
    (300, 7, 10, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (330, 5, 13, Color(red: 1.0, green: 0.624, blue: 0.039)),
  ]

  /// One full turn every eight seconds, read from the clock (a still 0 under Reduce Motion).
  static let turnSeconds: Double = 8

  static func angle(at date: Date, reduceMotion: Bool) -> Double {
    guard OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion) else { return 0 }
    let t = date.timeIntervalSinceReferenceDate
    return t.truncatingRemainder(dividingBy: turnSeconds) / turnSeconds * 360
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
      wheel.rotationEffect(.degrees(Self.angle(at: timeline.date, reduceMotion: reduceMotion)))
    }
    .frame(width: size, height: size)
    .onAppear { reportSpin() }
    // Keyed to the SETTING, not only to onAppear (OverlayMotion.syncAmbientLoop's recorded
    // reason): Reduce Motion can change while the wheel stays on screen, in both directions.
    .onChange(of: reduceMotion) { _, _ in reportSpin() }
    .accessibilityHidden(true)
  }

  private func reportSpin() {
    onSpinTarget?(OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion) ? 360 : 0)
  }

  private var wheel: some View {
    // Scale factor: SVG viewBox is 64x64, we map to `size`
    let scale = size / 64.0
    return Canvas { context, size in
      let cx = size.width / 2
      let cy = size.height / 2
      for bar in bars {
        let barW = 4.0 * scale
        let barH = bar.height * scale
        // Bar rect centered on the canvas, offset upward by yOffset so
        // its visual center sits at the correct radial distance.
        let distFromCenter = 32.0 * scale - bar.yOffset * scale - barH / 2
        let rect = CGRect(
          x: -barW / 2,
          y: -distFromCenter - barH / 2,
          width: barW,
          height: barH
        )
        let cornerRadius = 2.0 * scale
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        // Rotate around canvas center by bar's degree offset (converted to radians).
        let angle = bar.deg * .pi / 180.0
        let transform = CGAffineTransform(translationX: cx, y: cy)
          .rotated(by: angle)
        let rotatedPath = barPath.applying(transform)
        context.fill(rotatedPath, with: .color(bar.color))
      }
    }
    .frame(width: size, height: size)
  }
}
