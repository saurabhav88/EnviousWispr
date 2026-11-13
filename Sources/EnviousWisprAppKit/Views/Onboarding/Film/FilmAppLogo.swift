import AppKit
import SwiftUI

/// One app logo the closing film shows: the brand's own logo from SVGL, bundled as a PNG
/// (founder 2026-11-13: real brands and real logos only). Data: `FilmAppLogos.generated.swift`
/// and `Resources/app-logo-*.png`, both written by `scripts/design/fetch-app-logos.py`.
struct FilmAppLogo: Equatable {
  let name: String
  /// The bundled PNG's name, without extension.
  let resource: String
  /// The brand ships a separate logo for dark backgrounds (`<resource>-dark.png`).
  let hasDark: Bool

  static func named(_ name: String) -> FilmAppLogo? { all.first { $0.name == name } }

  /// The bundled picture for a light or dark background; nil only if the bundle lacks it.
  func image(dark: Bool) -> NSImage? {
    let name = dark && hasDark ? "\(resource)-dark" : resource
    guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
  }
}

/// Draws a `FilmAppLogo` at `size`. `onLight` pins the light-background logo (the Dock's white
/// tiles); otherwise the logo follows the appearance.
struct FilmAppLogoView: View {
  let logo: FilmAppLogo
  let size: CGFloat
  var onLight = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = logo.image(dark: !onLight && colorScheme == .dark) {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
