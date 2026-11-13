import SwiftUI

/// Setup's Welcome (#4528 D1; mockup `isWelcome`, copy verbatim).
struct SetupWelcomeScreen: View {
  let model: SetupScreenModel
  /// The route this screen was built for (presentation is reported against it).
  let epoch: Int

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(animationState: .welcome, size: SetupMetrics.heroLips)
        .padding(.bottom, DesignSpacing.lg)
        .accessibilityHidden(true)
      Text("Talk naturally.\nCapture perfectly.")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Text("Turn spoken thoughts into polished text\nin the apps you use.")
        .font(.firstRunBody)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.md) {
        SetupRow(
          symbol: "checkmark.shield.fill", title: "Private",
          detail: "Your voice stays on your Mac."
        )
        .modifier(SetupRise(delay: 0.06, reduceMotion: reduceMotion))
        SetupRow(
          symbol: "bolt.fill", title: "Fast, even offline",
          detail: "Built for Apple Silicon. No internet needed to dictate."
        )
        .modifier(SetupRise(delay: 0.12, reduceMotion: reduceMotion))
        SetupRow(
          symbol: "sparkles", title: "Polished for you",
          detail: "Filler words, grammar and formatting get fixed."
        )
        .modifier(SetupRise(delay: 0.18, reduceMotion: reduceMotion))
        SetupRow(
          symbol: "person.fill", title: "Free and open source",
          detail: "No account. No subscription. Anonymous stats only."
        )
        .modifier(SetupRise(delay: 0.24, reduceMotion: reduceMotion))
      }
      Spacer(minLength: 0)
      SetupFooter(title: "Set up dictation", action: {
        guard model.routeEpoch == epoch, model.state.step == .welcome else { return }
        model.sources.reportStarted?()
        model.send(.next)
      }) {
        Text("Six short steps to your first dictation.")
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
      }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear { model.screenMounted(.welcome, epoch: epoch) }
  }
}
