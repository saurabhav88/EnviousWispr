import AppKit
import SwiftUI

// MARK: - Dynamic color helper

extension Color {
  /// A color that resolves per the effective appearance. `light` is byte-identical
  /// to the pre-dark palette; `dark` is the night-comfort palette (#1047). The
  /// NSColors are built inside the resolver so nothing is captured across the
  /// Sendable boundary.
  static func stDynamic(
    lightRGB: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
    darkRGB: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkRGB : lightRGB
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
      }
    )
  }
}

// Token VALUES (the `st*` colors and fonts, `SettingsLayout`, `SettingsPR1Layout`) live in
// DESIGN.md and are generated into Views/Design/DesignTokens.generated.swift (#4506).
// This file keeps only the hand-written helpers those tokens use.

// MARK: - ShapeStyle Shorthands (enables `.stAccent` in `.foregroundStyle()`)

extension ShapeStyle where Self == Color {
  static var stTextPrimary: Color { Color.stTextPrimary }
  static var stTextSecondary: Color { Color.stTextSecondary }
  static var stTextTertiary: Color { Color.stTextTertiary }
  static var stTextBody: Color { Color.stTextBody }
  static var stAccent: Color { Color.stAccent }
  static var stSuccess: Color { Color.stSuccess }
  static var stWarning: Color { Color.stWarning }
  static var stError: Color { Color.stError }
}

private struct SettingsPR1DensityKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var settingsPR1Density: Bool {
    get { self[SettingsPR1DensityKey.self] }
    set { self[SettingsPR1DensityKey.self] = newValue }
  }
}
