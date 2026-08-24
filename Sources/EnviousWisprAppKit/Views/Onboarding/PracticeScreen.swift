import EnviousWisprServices
import SwiftUI

// MARK: - Screen 5: Try it out (#2196)

/// The last screen of setup, and the whole point of #2196: a real text box with
/// the cursor already in it, so a first dictation has somewhere to land.
///
/// WHY THE BOX IS THE ENTIRE FIX. `PasteCascadeExecutor` classifies the focused
/// element by AX role and `PasteService.textRoles` accepts `AXTextField`,
/// `AXTextArea`, `AXComboBox`, `AXSearchField` (`PasteService.swift:70-75`). A
/// focused SwiftUI `TextEditor` is backed by `NSTextView` and presents as
/// `AXTextArea`, which is in that set. The refusal this feature exists to fix
/// happens BECAUSE the classification is `.nonText` — our own window offered
/// nothing to type into — so supplying a text-role element removes the
/// precondition for the refusal rather than special-casing around it. Nothing in
/// the cascade special-cases our bundle: `isExpectedNonTextRefusal` special-cases
/// `com.apple.loginwindow` and nothing else (`PasteCascadeExecutor.swift:915-930`).
///
/// So this file adds NO pipeline code, no delivery route, and no new setting. It
/// adds a target.
struct PracticeScreenV2: View {
  var viewModel: OnboardingV2ViewModel

  /// Fired when the person is finished, however they got there.
  let onFinish: () -> Void

  @FocusState private var boxFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(animationState: viewModel.lipsState, size: 108)
        .padding(.bottom, 14)

      Text(viewModel.practiceSucceeded ? "That is it. You are set." : "Time for your first dictation!")
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.4)
        .multilineTextAlignment(.center)
        .padding(.bottom, 6)

      Text(
        viewModel.practiceSucceeded
          ? "Those are your words, typed for you.\nIn any other app, click into a text box first."
          : "Hold your shortcut and say something.\nLet go when you are done."
      )
      .font(.obBody)
      .foregroundStyle(Color.obTextSecondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 18)

      // The target. Focused on appear, because an unfocused box is exactly the
      // state this whole feature exists to remove.
      TextEditor(text: viewModel.practiceTextBinding)
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .padding(10)
        .frame(width: 404, height: 132)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
              viewModel.practiceSucceeded ? Color.obSuccess.opacity(0.55) : Color.obAccent.opacity(0.35),
              lineWidth: boxFocused ? 2 : 1)
        )
        .focused($boxFocused)
        .accessibilityLabel("Your first dictation")

      // Deliberately quiet while recording: the pill is NOT suppressed during
      // onboarding (nothing under App/Overlay/ reads `onboardingState`), so it
      // appears over this window and carries the recording state — which is what
      // this person will see in every other app forever after. A second waveform
      // here would teach them a UI that only exists during setup.
      Text(viewModel.practiceSucceeded ? " " : "Your recording indicator appears while you hold the key.")
        .font(.obCaptionSmall)
        .foregroundStyle(Color.obTextTertiary)
        .padding(.top, 10)

      Spacer()

      Button(action: onFinish) {
        Text("FINISH SETUP")
          .font(.system(size: 15, weight: .heavy))
          .kerning(0.3)
          .foregroundStyle(.white)
          .frame(maxWidth: 360)
          .padding(.vertical, 13)
          .background(
            viewModel.practiceSucceeded ? Color.obButtonFill : Color.obButtonFill.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.practiceSucceeded)
      .keyboardShortcut(.defaultAction)

      Button(action: onFinish) {
        Text("Skip this step")
          .font(.obCaption)
          .foregroundStyle(Color.obAccent)
      }
      .buttonStyle(.plain)
      .padding(.top, 12)
    }
    .onAppear { boxFocused = true }
    .animation(.easeInOut(duration: 0.3), value: viewModel.practiceSucceeded)
  }
}
