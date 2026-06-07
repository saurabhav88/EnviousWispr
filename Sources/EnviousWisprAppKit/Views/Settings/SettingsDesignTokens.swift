import SwiftUI

// MARK: - Settings Color Palette

extension Color {
  // Surfaces
  static let stPageBg = Color(red: 0.973, green: 0.961, blue: 1.0)  // #f8f5ff
  static let stSectionBg = Color.white
  static let stSidebarBg = Color(red: 0.910, green: 0.886, blue: 0.961)  // #e8e2f5

  // Text
  static let stTextSecondary = Color(red: 0.290, green: 0.239, blue: 0.376)  // #4a3d60
  static let stTextTertiary = Color(red: 0.420, green: 0.369, blue: 0.525)  // #6b5e86

  // Accent
  static let stAccent = Color(red: 0.486, green: 0.227, blue: 0.929)  // #7c3aed
  static let stAccentLight = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.09)

  // Toggle
  static let stToggleOn = Color(red: 0.0, green: 0.639, blue: 0.400)  // #00a366
  static let stToggleOff = Color(red: 0.608, green: 0.557, blue: 0.722)  // #9b8eb8

  // Status (semantic — use these, not raw .red/.green/.orange)
  static let stSuccess = Color(red: 0.0, green: 0.639, blue: 0.400)  // #00a366
  static let stWarning = Color(red: 0.800, green: 0.439, blue: 0.0)  // #cc7000
  static let stWarningSoft = Color(red: 0.800, green: 0.439, blue: 0.0).opacity(0.10)
  static let stError = Color(red: 0.753, green: 0.224, blue: 0.169)  // #c0392b

  // Dividers
  static let stDivider = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.08)
}

// MARK: - ShapeStyle Shorthands (enables `.stAccent` in `.foregroundStyle()`)

extension ShapeStyle where Self == Color {
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
}

// MARK: - Settings Layout Constants

enum SettingsLayout {
  static let sectionRadius: CGFloat = 12
  static let rowPaddingH: CGFloat = 14
  static let rowPaddingV: CGFloat = 10
  static let sectionSpacing: CGFloat = 16
  static let contentTop: CGFloat = 20
  static let contentH: CGFloat = 24
  static let contentBottom: CGFloat = 32
}
