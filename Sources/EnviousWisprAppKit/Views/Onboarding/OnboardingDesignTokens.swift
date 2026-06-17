import SwiftUI

// MARK: - Onboarding Color Palette
//
// #1047: each token pairs the exact pre-dark light value with a dark
// night-comfort value via `Color.stDynamic`. `obRainbow` is the brand
// signature and stays vivid in both modes. `obButtonFill` / `obKeycapTop`
// are new role tokens (see note below) that resolve a light/dark conflict:
// `obTextPrimary` was doubling as both heading text AND a primary-button
// background with white text — inverting it would make that white text
// vanish on dark, so the button-fill role is now its own token.

extension Color {
  // Backgrounds
  static let obSurface = stDynamic(
    lightRGB: (0.941, 0.925, 0.976, 1), darkRGB: (0.125, 0.106, 0.169, 1))
  static let obCardBg = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.145, 0.122, 0.216, 1))

  // Text
  static let obTextPrimary = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.910, 0.894, 0.945, 1))
  static let obTextSecondary = stDynamic(
    lightRGB: (0.290, 0.239, 0.376, 1), darkRGB: (0.667, 0.635, 0.749, 1))
  static let obTextTertiary = stDynamic(
    lightRGB: (0.490, 0.435, 0.588, 1), darkRGB: (0.478, 0.447, 0.565, 1))

  // Primary button fill — dark in light mode (near-black brand fill), a rich
  // purple in dark mode. White button text reads on both (≈5.8:1 on dark).
  static let obButtonFill = stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1), darkRGB: (0.420, 0.310, 0.820, 1))

  // Keycap top — the raised key face; white in light, a light-violet face in
  // dark so the key still reads as a key against the dark window.
  static let obKeycapTop = stDynamic(
    lightRGB: (1, 1, 1, 1), darkRGB: (0.180, 0.155, 0.255, 1))

  // Brand
  static let obAccent = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 1), darkRGB: (0.655, 0.545, 0.980, 1))
  static let obAccentSoft = stDynamic(
    lightRGB: (0.486, 0.227, 0.929, 0.1), darkRGB: (0.655, 0.545, 0.980, 0.16))

  // Semantic
  static let obSuccess = stDynamic(
    lightRGB: (0.0, 0.784, 0.502, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  static let obSuccessSoft = stDynamic(
    lightRGB: (0.0, 0.784, 0.502, 0.1), darkRGB: (0.361, 0.788, 0.604, 0.16))
  static let obSuccessText = stDynamic(
    lightRGB: (0.0, 0.541, 0.337, 1), darkRGB: (0.361, 0.788, 0.604, 1))
  static let obWarning = stDynamic(
    lightRGB: (0.902, 0.761, 0.0, 1), darkRGB: (0.902, 0.718, 0.400, 1))
  static let obError = stDynamic(
    lightRGB: (0.902, 0.145, 0.227, 1), darkRGB: (0.937, 0.486, 0.537, 1))
  static let obErrorSoft = stDynamic(
    lightRGB: (0.902, 0.145, 0.227, 0.1), darkRGB: (0.937, 0.486, 0.537, 0.16))

  // Borders
  static let obBorder = stDynamic(
    lightRGB: (0.541, 0.169, 0.886, 0.06), darkRGB: (0.722, 0.667, 0.839, 0.14))

  // Rainbow gradient (brand signature — unchanged in both modes)
  static let obRainbow = LinearGradient(
    colors: [
      Color(red: 1.0, green: 0.165, blue: 0.251),
      Color(red: 1.0, green: 0.549, blue: 0.0),
      Color(red: 1.0, green: 0.843, blue: 0.0),
      Color(red: 0.678, green: 1.0, blue: 0.184),
      Color(red: 0.0, green: 0.98, blue: 0.604),
      Color(red: 0.0, green: 1.0, blue: 1.0),
      Color(red: 0.118, green: 0.565, blue: 1.0),
      Color(red: 0.255, green: 0.412, blue: 0.882),
      Color(red: 0.541, green: 0.169, blue: 0.886),
    ],
    startPoint: .leading,
    endPoint: .trailing
  )
}

// MARK: - Onboarding Font Tokens

extension Font {
  static let obDisplay = Font.system(size: 22, weight: .heavy, design: .rounded)
  static let obSubheading = Font.system(size: 14, weight: .semibold)
  static let obBody = Font.system(size: 14, weight: .regular)
  static let obCaption = Font.system(size: 12, weight: .regular)
  static let obCaptionSmall = Font.system(size: 11, weight: .regular)
  static let obLabel = Font.system(size: 13, weight: .medium)
}

// MARK: - Button Styles

struct OnboardingButtonStyle: ButtonStyle {
  var color: Color = .obButtonFill

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.obSubheading)
      .kerning(-0.1)
      .foregroundStyle(.white)
      .padding(.horizontal, 28)
      .padding(.vertical, 11)
      .background(color, in: RoundedRectangle(cornerRadius: 12))
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
  }
}
