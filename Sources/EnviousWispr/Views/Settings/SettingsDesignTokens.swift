import SwiftUI

// MARK: - Settings Color Palette

extension Color {
    // Surfaces
    static let stPageBg        = Color(red: 0.973, green: 0.961, blue: 1.0)    // #f8f5ff
    static let stSectionBg     = Color.white
    static let stSidebarBg     = Color(red: 0.910, green: 0.886, blue: 0.961)  // #e8e2f5
    static let stChrome        = Color(red: 0.929, green: 0.910, blue: 0.973)  // #ede8f8

    // Text
    static let stTextPrimary   = Color(red: 0.059, green: 0.039, blue: 0.102)  // #0f0a1a
    static let stTextSecondary = Color(red: 0.290, green: 0.239, blue: 0.376)  // #4a3d60
    static let stTextTertiary  = Color(red: 0.490, green: 0.435, blue: 0.588)  // #7d6f96

    // Accent
    static let stAccent        = Color(red: 0.486, green: 0.227, blue: 0.929)  // #7c3aed
    static let stAccentLight   = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.09)
    static let stAccentBorder  = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.35)

    // Toggle
    static let stToggleOn      = Color(red: 0.0, green: 0.784, blue: 0.502)    // #00c880
    static let stToggleOff     = Color(red: 0.769, green: 0.722, blue: 0.847)  // #c4b8d8

    // Dividers
    static let stDivider       = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.08)
    static let stChromeDivider = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.12)

    // Sidebar
    static let stSidebarActiveBg   = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.09)
    static let stSidebarActiveText = Color(red: 0.357, green: 0.129, blue: 0.714) // #5b21b6
}

// MARK: - ShapeStyle Shorthands (enables `.stAccent` in `.foregroundStyle()`)

extension ShapeStyle where Self == Color {
    static var stPageBg: Color { Color.stPageBg }
    static var stSectionBg: Color { Color.stSectionBg }
    static var stSidebarBg: Color { Color.stSidebarBg }
    static var stChrome: Color { Color.stChrome }
    static var stTextPrimary: Color { Color.stTextPrimary }
    static var stTextSecondary: Color { Color.stTextSecondary }
    static var stTextTertiary: Color { Color.stTextTertiary }
    static var stAccent: Color { Color.stAccent }
    static var stAccentLight: Color { Color.stAccentLight }
    static var stAccentBorder: Color { Color.stAccentBorder }
    static var stToggleOn: Color { Color.stToggleOn }
    static var stToggleOff: Color { Color.stToggleOff }
    static var stDivider: Color { Color.stDivider }
    static var stChromeDivider: Color { Color.stChromeDivider }
    static var stSidebarActiveBg: Color { Color.stSidebarActiveBg }
    static var stSidebarActiveText: Color { Color.stSidebarActiveText }
}

// MARK: - Settings Font Tokens

extension Font {
    static let stRowLabel      = Font.system(size: 13.5, weight: .medium)
    static let stSectionHeader = Font.system(size: 11.5, weight: .bold)
    static let stHelper        = Font.system(size: 11.5)
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
