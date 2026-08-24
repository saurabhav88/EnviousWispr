import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - SpectrumWheelIcon

/// 12 rainbow-colored bars arranged radially, spinning slowly.
struct SpectrumWheelIcon: View {
  @State private var rotation: Double = 0
  let size: CGFloat

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

  var body: some View {
    // Scale factor: SVG viewBox is 64x64, we map to `size`
    let scale = size / 64.0
    Canvas { context, size in
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
    .rotationEffect(.degrees(rotation))
    .onAppear {
      withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
        rotation = 360
      }
    }
    .accessibilityHidden(true)
  }
}
