import SwiftUI

/// One app logo the closing film shows: the website's own mark for the app, as one SVG path
/// on a 24-point grid, in the app's color (founder 2026-11-13: the film shows the real logos).
/// Data: `FilmAppLogos.generated.swift`, from `website/src/data/home/compatibleApps.json`.
struct FilmAppLogo: Equatable {
  let name: String
  let hex: String
  /// Near-black marks (Notion, Craft, TextEdit) take the text color, as the mockup draws them.
  let ink: Bool
  let path: String

  static func named(_ name: String) -> FilmAppLogo? { all.first { $0.name == name } }
}

/// Draws a `FilmAppLogo` at `size`, filled like the mockup's mask (non-zero fill).
struct FilmAppLogoView: View {
  let logo: FilmAppLogo
  let size: CGFloat

  var body: some View {
    SVGLogoShape(data: logo.path)
      .fill(logo.ink ? Color.obTextPrimary : Color(hex: logo.hex))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// The path, read once per shape and scaled from its 24-point grid to the frame.
private struct SVGLogoShape: Shape {
  let data: String

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    return SVGPathData.path(data)
      .applying(CGAffineTransform(scaleX: scale, y: scale))
      .offsetBy(dx: rect.minX, dy: rect.minY)
  }
}
