import SwiftUI

// MARK: - Onboarding Color Palette

extension Color {
    // Backgrounds
    static let obBg           = Color(red: 0.973, green: 0.961, blue: 1.0)
    static let obSurface      = Color(red: 0.941, green: 0.925, blue: 0.976)
    static let obCardBg       = Color.white

    // Text
    static let obTextPrimary  = Color(red: 0.059, green: 0.039, blue: 0.102)
    static let obTextSecondary = Color(red: 0.290, green: 0.239, blue: 0.376)
    static let obTextTertiary = Color(red: 0.490, green: 0.435, blue: 0.588)

    // Brand
    static let obAccent       = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let obAccentSoft   = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.1)

    // Semantic
    static let obSuccess      = Color(red: 0.0, green: 0.784, blue: 0.502)
    static let obSuccessSoft  = Color(red: 0.0, green: 0.784, blue: 0.502).opacity(0.1)
    static let obSuccessText  = Color(red: 0.0, green: 0.541, blue: 0.337)
    static let obWarning      = Color(red: 0.902, green: 0.761, blue: 0.0)
    static let obError        = Color(red: 0.902, green: 0.145, blue: 0.227)
    static let obErrorSoft    = Color(red: 0.902, green: 0.145, blue: 0.227).opacity(0.1)

    // Borders
    static let obBorder       = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.06)
    static let obBorderHover  = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.12)

    // Buttons
    static let obBtnDark      = Color(red: 0.059, green: 0.039, blue: 0.102)

    // Rainbow gradient (static property — used as AnyShapeStyle)
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
    static let obDisplay      = Font.system(size: 22, weight: .heavy, design: .rounded)
    static let obSubheading   = Font.system(size: 14, weight: .semibold)
    static let obBody         = Font.system(size: 14, weight: .regular)
    static let obCaption      = Font.system(size: 12, weight: .regular)
    static let obCaptionSmall = Font.system(size: 11, weight: .regular)
    static let obLabel        = Font.system(size: 13, weight: .medium)
    static let obButton       = Font.system(size: 15, weight: .bold)
}

// MARK: - Button Styles

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .kerning(-0.1)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

struct OnboardingAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obAccent, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

struct OnboardingErrorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obError, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
