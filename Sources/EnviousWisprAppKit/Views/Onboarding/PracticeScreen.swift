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

  @Environment(PermissionsService.self) private var permissions
  /// The SUBJECT's own in-flight signal: true while either pipeline is
  /// recording, transcribing or polishing. The screen was previously blind to a
  /// take entirely, which is what let Skip pull the target away mid-dictation
  /// and let a silent take go unacknowledged (local Codex chunk-2 review).
  @Environment(LiveRecordingState.self) private var live

  @FocusState private var boxFocused: Bool

  /// A take is in flight, so both exits are held. Leaving now would close the
  /// window the ordinary cascade is about to type into, and the words would
  /// land on the clipboard behind the same notice this feature removes — or in
  /// whatever app happened to be behind us.
  private var takeInFlight: Bool { live.isDictationActive }

  private var cannotHear: Bool {
    if case .cannotHear = viewModel.practiceState { return true }
    return false
  }

  private func grantPermission(reason: String) async {
    if reason == "mic_denied" {
      _ = await permissions.requestMicrophoneAccess()
    } else {
      _ = permissions.requestAccessibilityAccess()
    }
    permissions.refreshAccessibilityStatus()
    viewModel.applyPracticePosture(
      micGranted: permissions.hasMicrophonePermission,
      accessibilityGranted: permissions.accessibilityGranted)
  }

  private var headline: String {
    switch viewModel.practiceState {
    case .cannotHear: return "We cannot hear you"
    case .listening: return "Listening…"
    case .saidNothing: return "All quiet"
    case .worked: return "That is it. You are set."
    case .waiting: return viewModel.practiceSucceeded ? "That is it. You are set." : "Time for your first dictation!"
    }
  }

  private var subhead: String {
    switch viewModel.practiceState {
    case .cannotHear(let reason, _):
      return reason == "mic_denied"
        ? "EnviousWispr needs permission to use your microphone.\nYou can turn it on and come back, or skip ahead."
        : "EnviousWispr needs Accessibility permission to type for you.\nYou can turn it on and come back, or skip ahead."
    case .listening:
      return "Go ahead. Let go of the key when you are done."
    case .saidNothing:
      // Not an error, and never worded as one: the microphone worked, there
      // was simply nothing to hear. The prompt is drawn from the persona banks
      // so it sounds like something a person would actually say.
      return "Your microphone is working — we just did not hear anything.\nTry holding the key and saying: tell grandma I will call Sunday."
    case .worked:
      return "Those are your words, typed for you.\nIn any other app, click into a text box first."
    case .waiting:
      return viewModel.practiceSucceeded
        ? "Those are your words, typed for you.\nIn any other app, click into a text box first."
        : "Hold your shortcut and say something.\nLet go when you are done."
    }
  }

  private var footnote: String {
    if cannotHear { return " " }
    if viewModel.practiceSucceeded { return " " }
    return "Your recording indicator appears while you hold the key."
  }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(animationState: viewModel.lipsState, size: 108)
        .padding(.bottom, 14)

      Text(headline)
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(Color.obTextPrimary)
        .kerning(-0.4)
        .multilineTextAlignment(.center)
        .padding(.bottom, 6)

      Text(subhead)
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
      Text(footnote)
        .font(.obCaptionSmall)
        .foregroundStyle(Color.obTextTertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)

      // The route out. `PermissionsService` exposes request methods rather
      // than a settings opener, and the request is the better offer anyway: an
      // undetermined permission is granted in place, and a denied one lands the
      // person on the right pane instead of the top of System Settings.
      if case .cannotHear(let reason, _) = viewModel.practiceState {
        Button {
          Task { await grantPermission(reason: reason) }
        } label: {
          Text(reason == "mic_denied" ? "Turn on the microphone" : "Turn on Accessibility")
            .font(.obCaption)
            .foregroundStyle(Color.obAccent)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
      }

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
      .disabled(!viewModel.practiceSucceeded || takeInFlight)
      .keyboardShortcut(.defaultAction)

      Button(action: onFinish) {
        Text(takeInFlight ? "One moment, still working on that" : "Skip this step")
          .font(.obCaption)
          .foregroundStyle(takeInFlight ? Color.obTextTertiary : Color.obAccent)
      }
      .buttonStyle(.plain)
      .disabled(takeInFlight)
      .padding(.top, 12)
    }
    .onAppear {
      boxFocused = true
      permissions.refreshAccessibilityStatus()
      viewModel.applyPracticePosture(
        micGranted: permissions.hasMicrophonePermission,
        accessibilityGranted: permissions.accessibilityGranted)
    }
    // The take's own edges, from the subject rather than from a timer.
    .onChange(of: live.isDictationActive) { _, active in
      if active {
        viewModel.practiceTakeStarted()
      } else {
        viewModel.practiceTakeEnded()
      }
    }
    .animation(.easeInOut(duration: 0.3), value: viewModel.practiceState)
  }
}
