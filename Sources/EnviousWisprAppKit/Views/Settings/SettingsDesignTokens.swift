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

// MARK: - Settings Color Palette
//
// Each token pairs the exact light value shipped before #1047 with a dark
// night-comfort value (low-chroma surfaces, off-white text, desaturated lavender
// accent, muted semantics). Consumers read these statics unchanged, so the whole
// window adapts when `NSApp.appearance` flips.

extension Color {
  // Surfaces
  static let stPageBg = stDynamic(
    lightRGB: (0.973, 0.961, 1.0, 1), darkRGB: (0.075, 0.063, 0.098, 1))  // #f8f5ff / #131019
  static let stSectionBg = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.125, 0.106, 0.169, 1))  // #ffffff / #201b2b
  static let stSidebarBg = stDynamic(
    lightRGB: (0.910, 0.886, 0.961, 1), darkRGB: (0.102, 0.086, 0.137, 1))  // #e8e2f5 / #1a1623

  // Text
  //
  // Primary is the reading-copy colour: near-black in light, near-white in dark.
  // The dark value is capped below pure white (~92%) to limit halation on the
  // night-comfort surfaces while staying markedly crisper than the secondary grey.
  static let stTextPrimary = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.925, 0.914, 0.957, 1))  // #0f0a1a / #ece9f4
  static let stTextSecondary = stDynamic(
    lightRGB: (0.290, 0.239, 0.376, 1), darkRGB: (0.667, 0.635, 0.749, 1))  // #4a3d60 / #aaa2bf
  static let stTextTertiary = stDynamic(
    lightRGB: (0.420, 0.369, 0.525, 1), darkRGB: (0.478, 0.447, 0.565, 1))  // #6b5e86 / #7a7290

  // Accent
  static let stAccent = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 1), darkRGB: (0.655, 0.545, 0.980, 1))  // #7c3aed / #a78bfa
  static let stAccentLight = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 0.09), darkRGB: (0.655, 0.545, 0.980, 0.16))

  // Toggle
  static let stToggleOn = stDynamic(
    lightRGB: (0.0, 0.639, 0.400, 1), darkRGB: (0.361, 0.788, 0.604, 1))  // #00a366 / #5cc99a
  static let stToggleOff = stDynamic(
    lightRGB: (0.608, 0.557, 0.722, 1), darkRGB: (0.290, 0.263, 0.376, 1))  // #9b8eb8 / #4a4360

  // Status (semantic — use these, not raw .red/.green/.orange)
  static let stSuccess = stDynamic(
    lightRGB: (0.0, 0.639, 0.400, 1), darkRGB: (0.361, 0.788, 0.604, 1))  // #00a366 / #5cc99a
  static let stWarning = stDynamic(
    lightRGB: (0.800, 0.439, 0.0, 1), darkRGB: (0.902, 0.718, 0.400, 1))  // #cc7000 / #e6b766
  static let stWarningSoft = stDynamic(
    lightRGB: (0.800, 0.439, 0.0, 0.10), darkRGB: (0.902, 0.718, 0.400, 0.14))
  static let stError = stDynamic(
    lightRGB: (0.753, 0.224, 0.169, 1), darkRGB: (0.937, 0.486, 0.537, 1))  // #c0392b / #ef7c89

  // Dividers
  static let stDivider = stDynamic(
    lightRGB: (0.541, 0.169, 0.886, 0.08), darkRGB: (0.722, 0.667, 0.839, 0.14))
}

// MARK: - ShapeStyle Shorthands (enables `.stAccent` in `.foregroundStyle()`)

extension ShapeStyle where Self == Color {
  static var stTextPrimary: Color { Color.stTextPrimary }
  static var stTextSecondary: Color { Color.stTextSecondary }
  static var stTextTertiary: Color { Color.stTextTertiary }
  static var stAccent: Color { Color.stAccent }
  static var stSuccess: Color { Color.stSuccess }
  static var stWarning: Color { Color.stWarning }
  static var stError: Color { Color.stError }
}

// MARK: - Settings Font Tokens

extension Font {
  static let stSectionHeader = Font.system(size: 11.5, weight: .bold)
  static let stHelper = Font.system(size: 11.5)
  /// Reading-copy body: multi-sentence explainers and section descriptions.
  /// Medium weight reads crisper on the dark night-comfort surfaces (halation).
  static let stBody = Font.system(size: 14, weight: .medium)
}

// MARK: - Settings Layout Constants

enum SettingsLayout {
  static let sectionRadius: CGFloat = 14
  static let rowPaddingH: CGFloat = 14
  static let rowPaddingV: CGFloat = 12
  static let sectionSpacing: CGFloat = 18
  static let contentTop: CGFloat = 20
  static let contentH: CGFloat = 24
  static let contentBottom: CGFloat = 32
}
