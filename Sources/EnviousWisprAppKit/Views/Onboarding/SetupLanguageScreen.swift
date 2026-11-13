import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Setup's Language screen (#4528 D1, plan M75; mockup `isLanguage`, copy verbatim). The typed
/// text is a local draft: nothing is written until Continue or Return commits a match through
/// the flow's `chooseLanguage` event, then `next`.
struct SetupLanguageScreen: View {
  let model: SetupScreenModel
  /// The route this screen was built for (presentation is reported against it).
  let epoch: Int

  @State private var text = ""
  @State private var guessed = false
  @State private var started = false
  @State private var greeting: SetupLanguage.Greeting?
  @State private var lips: LipsAnimationState = .idle
  @State private var burst = 0
  @FocusState private var fieldFocused: Bool

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var match: SetupLanguage.Match? { SetupLanguage.match(text) }

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        RainbowLipsView(animationState: lips, size: SetupMetrics.screenLips, burst: burst)
          .accessibilityHidden(true)
        if let greeting {
          SetupGreetingBubble(text: greeting.text, reduceMotion: reduceMotion)
            .offset(x: SetupMetrics.screenLips + DesignSpacing.xxs, y: SetupMetrics.bubbleTop)
        }
      }
      .frame(width: SetupMetrics.screenLips, height: SetupMetrics.screenLips)
      .padding(.bottom, DesignSpacing.xl)
      Text("Which language will\nyou dictate in?")
        .font(.firstRunDisplay)
        .fixedSize(horizontal: false, vertical: true)  // a long German title wraps, never truncates
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Text("EnviousWispr picks the best speech model for it.")
        .font(.firstRunBody)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      SetupLanguageField(
        text: $text, matched: match != nil, focused: $fieldFocused, onSubmit: commit)
      statusRow
      if guessed {
        Text("From your Mac's language settings. Type to change it.")
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
          .multilineTextAlignment(.center)
      }
      Spacer(minLength: 0)
      SetupFooter(title: "Continue", isEnabled: match != nil, action: commit) { EmptyView() }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear(perform: start)
    .onChange(of: text) { _, newValue in edited(newValue) }
    .task(id: match?.greetingCode) { await playGreeting(for: match?.greetingCode) }
  }

  @ViewBuilder private var statusRow: some View {
    ZStack {
      if let match {
        SetupMatchChip(label: match.label)
      } else if SetupLanguage.showsNoMatch(text) {
        Text("No match yet. Try the language's own name, such as Deutsch.")
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(height: SetupMetrics.statusRowHeight)
  }

  /// The starting text: a committed language wins over the Mac's guess (founder D8).
  private func start() {
    guard !started else { return }
    started = true
    let initial = SetupLanguage.initialText(
      committed: model.state.choices.languageMode, macCode: SetupAdvice.macLanguageCode)
    text = initial.text
    guessed = initial.guessed
    if !reduceMotion { burst += 1 }
    fieldFocused = true
    model.screenMounted(.language, epoch: epoch)
  }

  private func edited(_ newValue: String) {
    let initial = SetupLanguage.initialText(
      committed: model.state.choices.languageMode, macCode: SetupAdvice.macLanguageCode)
    if guessed, newValue != initial.text { guessed = false }
  }

  /// Continue and Return: one path. Nothing happens without a match.
  private func commit() {
    guard model.state.step == .language, let match else { return }
    model.send(.chooseLanguage(match.mode))
    model.send(.next)
  }

  /// A new match greets once; an edit, a non-match, leaving the screen or closing the window
  /// cancels the task (`.task(id:)`), so no stale greeting survives.
  private func playGreeting(for code: String?) async {
    greeting = nil
    lips = .idle
    guard let code, let next = SetupLanguage.greeting(for: code) else { return }
    try? await Task.sleep(for: .seconds(SetupLanguage.greetingDelay))
    guard !Task.isCancelled else { return }
    greeting = next
    if !reduceMotion { lips = .speaking(beats: next.beats) }
    try? await Task.sleep(for: .seconds(next.seconds))
    guard !Task.isCancelled else { return }
    greeting = nil
    lips = .idle
  }
}

/// The language field (mockup `[data-ui="field"]`): 52 high, at most 360 wide, centered 17-point
/// semibold text, input colors, accent focus ring, success border once a language matches.
private struct SetupLanguageField: View {
  @Binding var text: String
  let matched: Bool
  var focused: FocusState<Bool>.Binding
  let onSubmit: () -> Void

  var body: some View {
    TextField(
      "", text: $text, prompt: Text("Type a language").foregroundStyle(Color.firstRunTextTertiary)
    )
    .textFieldStyle(.plain)
    .font(.firstRunSay)
    .multilineTextAlignment(.center)
    .foregroundStyle(Color.obTextPrimary)
    .autocorrectionDisabled()
    .focused(focused)
    .onSubmit(onSubmit)
    .padding(.horizontal, DesignSpacing.xxl)
    .frame(maxWidth: SetupMetrics.buttonMaxWidth)
    .frame(height: SetupMetrics.fieldHeight)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.stInputBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 1)
    )
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl + SetupMetrics.focusRing, style: .continuous)
        .fill(focused.wrappedValue && !matched ? Color.firstRunAccentSoft : .clear)
        .padding(-SetupMetrics.focusRing)
    )
    .accessibilityLabel(Text("Your main dictation language"))
  }

  private var borderColor: Color {
    if matched { return .obSuccess }
    return focused.wrappedValue ? .obAccent : .stInputBorder
  }
}

/// The match chip (mockup `okchip`): success wash, check, the language's names.
private struct SetupMatchChip: View {
  let label: String

  var body: some View {
    HStack(spacing: DesignSpacing.sm) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.obSuccess)
        .accessibilityHidden(true)
      Text(verbatim: label)
        .font(.firstRunCaption.weight(.semibold))
        .foregroundStyle(Color.firstRunSuccessText)
    }
    .font(.firstRunCaption)
    .padding(.leading, DesignSpacing.md)
    .padding(.trailing, DesignSpacing.xl)
    .frame(height: SetupMetrics.chipHeight)
    .background(Capsule().fill(Color.obSuccessSoft))
    .accessibilityElement(children: .combine)
  }
}

/// The greeting bubble beside the lips (mockup `[data-ui="bubble"]`).
private struct SetupGreetingBubble: View {
  let text: String
  let reduceMotion: Bool

  var body: some View {
    Text(verbatim: text)
      .font(.firstRunLabel)
      .foregroundStyle(Color.obAccent)
      .fixedSize()
      .padding(.vertical, DesignSpacing.sm)
      .padding(.horizontal, DesignSpacing.xl)
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: DesignRadius.xl, bottomLeadingRadius: DesignRadius.xs,
          bottomTrailingRadius: DesignRadius.xl, topTrailingRadius: DesignRadius.xl,
          style: .continuous
        )
        .fill(Color.firstRunAccentSoft)
      )
      .transition(reduceMotion ? .identity : .scale(scale: 0.9).combined(with: .opacity))
  }
}
