import SwiftUI

// Onboarding token VALUES (the `ob*` colors and fonts) live in DESIGN.md and are generated
// into Views/Design/DesignTokens.generated.swift (#4506). `obRainbow` is brand art and stays here.

extension Color {
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
