import SwiftUI

/// The EnviousWispr brand mark: the rainbow waveform (two mirrored rows of
/// coloured bars), drawn vectorially so it stays crisp at any size without
/// bundling an image. Geometry + colours mirror `website/public/favicon.svg`
/// (viewBox 256, bars translated by (8, 13)).
struct WisprLogoMark: View {
  private struct Bar {
    let x: CGFloat
    let y: CGFloat
    let h: CGFloat
    let color: Color
  }

  private static let barWidth: CGFloat = 14
  private static let corner: CGFloat = 5

  private static let bars: [Bar] = [
    // Top row (opacity 0.90)
    Bar(x: 16, y: 84.2, h: 20, color: c(255, 42, 64, 0.9)),
    Bar(x: 40, y: 65.75, h: 32, color: c(255, 140, 0, 0.9)),
    Bar(x: 64, y: 43.36, h: 48, color: c(255, 215, 0, 0.9)),
    Bar(x: 88, y: 63.04, h: 36, color: c(173, 255, 47, 0.9)),
    Bar(x: 112, y: 81.43, h: 24, color: c(0, 250, 154, 0.9)),
    Bar(x: 136, y: 63.04, h: 36, color: c(0, 255, 255, 0.9)),
    Bar(x: 160, y: 43.36, h: 48, color: c(30, 144, 255, 0.9)),
    Bar(x: 184, y: 65.75, h: 32, color: c(65, 105, 225, 0.9)),
    Bar(x: 208, y: 84.2, h: 20, color: c(138, 43, 226, 0.9)),
    // Bottom row (opacity 0.85)
    Bar(x: 16, y: 125.8, h: 20, color: c(65, 105, 225, 0.85)),
    Bar(x: 40, y: 119.35, h: 36, color: c(30, 144, 255, 0.85)),
    Bar(x: 64, y: 112.96, h: 48, color: c(0, 255, 255, 0.85)),
    Bar(x: 88, y: 120.64, h: 60, color: c(0, 250, 154, 0.85)),
    Bar(x: 112, y: 127.03, h: 68, color: c(173, 255, 47, 0.85)),
    Bar(x: 136, y: 120.64, h: 60, color: c(255, 215, 0, 0.85)),
    Bar(x: 160, y: 112.96, h: 48, color: c(255, 140, 0, 0.85)),
    Bar(x: 184, y: 119.35, h: 36, color: c(255, 42, 64, 0.85)),
    Bar(x: 208, y: 125.8, h: 20, color: c(138, 43, 226, 0.85)),
  ]

  private static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
  }

  var body: some View {
    Canvas { context, size in
      let scale = size.width / 256
      for bar in Self.bars {
        let rect = CGRect(
          x: (bar.x + 8) * scale,
          y: (bar.y + 13) * scale,
          width: Self.barWidth * scale,
          height: bar.h * scale)
        context.fill(
          Path(roundedRect: rect, cornerRadius: Self.corner * scale),
          with: .color(bar.color))
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityHidden(true)
  }
}
