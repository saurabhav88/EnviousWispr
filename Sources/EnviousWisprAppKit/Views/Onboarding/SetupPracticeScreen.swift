import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

enum SetupPracticeState: Equatable {
  case preparing, waiting
  case listening(handsFree: Bool)
  case transcribing, polishing
  case worked, noSpeech
  case missedBox(copiedToClipboard: Bool)
  case pipelineFailed
  case microphoneOff, accessibilityOff

  var inFlight: Bool {
    switch self {
    case .listening, .transcribing, .polishing: true
    default: false
    }
  }

  var needsPermission: Bool { self == .microphoneOff || self == .accessibilityOff }
  var acceptsFocus: Bool { self != .preparing && !needsPermission }

  func canContinue(hasSucceeded: Bool) -> Bool {
    hasSucceeded && acceptsFocus && !inFlight
  }

  func canSkip(hasSucceeded: Bool) -> Bool {
    !hasSucceeded && !inFlight
  }

  var headline: LocalizedStringKey {
    switch self {
    case .preparing: "Almost ready"
    case .waiting: "Time for your first dictation!"
    case .listening: "Listening…"
    case .transcribing: "Transcribing…"
    case .polishing: "Polishing…"
    case .worked: "That is it. You are set."
    case .noSpeech: "Let’s try that again"
    case .missedBox: "Click the box, then talk"
    case .pipelineFailed: "One more time"
    case .microphoneOff: "Turn the microphone back on"
    case .accessibilityOff: "Turn Accessibility back on"
    }
  }

  func subtitle(key: String) -> LocalizedStringKey {
    switch self {
    case .preparing: "Getting dictation ready…"
    case .waiting: "Hold \(key) and say the line below.\nLet go when you are done."
    case .listening(handsFree: false):
      "Go ahead, say the line.\nLet go of \(key) when you are done."
    case .listening(handsFree: true):
      "Hands-free is on. Talk as long as you like.\nPress \(key) once when you are done."
    case .transcribing: "Turning your voice into text,\nright here on this Mac."
    case .polishing: "Cleaning up your words.\nAlmost there."
    case .worked:
      "Those are your words, typed for you.\nIn any other app, click into a text box first."
    case .noSpeech:
      "EnviousWispr didn’t hear any speech.\nPick another microphone, or hold \(key) and speak."
    case .missedBox(copiedToClipboard: true):
      "EnviousWispr types where your cursor is.\nThis take is saved on your clipboard."
    case .missedBox(copiedToClipboard: false):
      "EnviousWispr types where your cursor is.\nClick here and try again."
    case .pipelineFailed: "That one was on us, not you.\nHold \(key) and say it again."
    case .microphoneOff:
      "macOS has the microphone switched off for EnviousWispr.\nFlip it on and you are right back here."
    case .accessibilityOff:
      "EnviousWispr needs this switch to type your words for you.\nFlip it on and you are right back here."
    }
  }

  var lips: LipsAnimationState {
    switch self {
    case .waiting: .welcome
    case .listening: .equalizer
    case .transcribing, .polishing: .shimmer
    case .worked: .triumph
    default: .idle
    }
  }
}

enum SetupPracticePolish: Equatable {
  case live, off
  case cloudLater(providerName: String)

  var note: LocalizedStringKey? {
    switch self {
    case .live: nil
    case .off: "AI polish is off. You can turn it on in Settings."
    case .cloudLater(let provider): "Add your \(provider) key in Settings to turn on AI polish."
    }
  }
}

/// Practice receives the real editor binding. The parent decides whether a take reached that
/// editor and owns the normal overlay, readiness, recovery and flow actions.
struct SetupPracticeScreen: View {
  let state: SetupPracticeState
  @Binding var text: String
  let hasSucceeded: Bool
  let key: String
  let polish: SetupPracticePolish
  let settings: SettingsManager
  let devices: [AudioInputDevice]
  let onSucceeded: () -> Void
  let onSkip: () -> Void
  let onBack: () -> Void
  let onOpenPermissions: () -> Void
  var onFocusChange: (Bool) -> Void = { _ in }
  var editorIdentifier: String = "Your first dictation"
  var mayFocusEditor: @MainActor () -> Bool = { true }
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  @FocusState private var editorFocused: Bool
  @State private var burst = 0
  @State private var glow = false

  var body: some View {
    VStack(spacing: DesignSpacing.xl) {
      RainbowLipsView(animationState: state.lips, size: SetupMetrics.screenLips, burst: burst)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { burst += 1 } }  // mockup: a happy bounce on arrival
      VStack(spacing: DesignSpacing.md) {
        Text(state.headline)
          .font(.firstRunDisplay)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)  // a long German title wraps, never truncates
          .foregroundStyle(Color.obTextPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(state.subtitle(key: key))
          .font(.firstRunBody)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .multilineTextAlignment(.center)

      if state.needsPermission {
        permissionGuide
      } else if state.acceptsFocus {
        prompt
      }
      if state != .preparing {
        editor
      }
      if state.acceptsFocus {
        if state == .worked, let note = polish.note {
          Text(note)
            .font(.firstRunCaption)
            .foregroundStyle(Color.obTextSecondary)
            .multilineTextAlignment(.center)
        } else if state != .worked && !state.inFlight {
          MicrophoneDevicePicker(
            model: MicrophonePickerModel(settingsManager: settings, devices: devices))
        }
      }
      Spacer(minLength: 0)
      footer
    }
    .background {
      Button("Back", action: back)
        .keyboardShortcut(.cancelAction)
        .disabled(state.inFlight)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .onDisappear { onFocusChange(false) }
    .onChange(of: editorFocused) { _, focused in onFocusChange(focused) }
    .onChange(of: state) { _, new in
      if !new.acceptsFocus { editorFocused = false }
    }
  }

  private var permissionGuide: some View {
    SetupCard {
      VStack(alignment: .leading, spacing: DesignSpacing.xl) {
        SetupSettingsPreview(
          pane: state == .microphoneOff
            ? "Privacy & Security › Microphone" : "Privacy & Security › Accessibility",
          reduceMotion: reduceMotion)
        Text(
          "Flip this switch on. EnviousWispr notices by itself. If it still shows off, quit and reopen EnviousWispr."
        )
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var prompt: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      Text("Try saying")
        .font(.firstRunEyebrow)
        .textCase(.uppercase)
        .foregroundStyle(Color.obAccent)
      Text("“Um, I think we should, uh, meet tomorrow morning.”")
        .font(.firstRunSay)
        .foregroundStyle(Color.obTextPrimary)
    }
    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    .padding(DesignSpacing.xxl)
    .background(Color.firstRunAccentSoft, in: RoundedRectangle(cornerRadius: DesignRadius.xxl))
  }

  private var editor: some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.xl)
    return TextEditor(text: $text)
      .font(.firstRunSay)
      .foregroundStyle(Color.obTextPrimary)
      .scrollContentBackground(.hidden)
      .padding(DesignSpacing.md)
      .frame(height: 116)
      .background(Color.obSurface, in: shape)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text("Your words land here")
            .font(.firstRunBody)
            .foregroundStyle(Color.firstRunTextTertiary)
            .padding(DesignSpacing.xl)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
      }
      .overlay {
        shape.strokeBorder(
          state == .worked
            ? Color.firstRunSuccessText : editorFocused ? Color.obAccent : Color.firstRunRule,
          lineWidth: 1
        ).allowsHitTesting(false)
        // Mockup: the border turns green over 0.2 s on success.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state == .worked)
      }
      // Mockup obGlow 0.7 s: on success a green ring grows to 8 points and fades back.
      .background {
        shape.stroke(Color.obSuccessSoft, lineWidth: glow ? 16 : 0)
          .opacity(glow ? 1 : 0)
          .allowsHitTesting(false)
      }
      .onChange(of: state == .worked) { _, worked in
        guard worked, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.28)) { glow = true }
        withAnimation(.easeOut(duration: 0.42).delay(0.28)) { glow = false }
      }
      .background {
        SetupPracticeEditorFocus(
          canFocus: state.acceptsFocus,
          mayFocusNow: { !state.inFlight && mayFocusEditor() }
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
      .focused($editorFocused)
      .accessibilityLabel("Your first dictation")
      .accessibilityIdentifier(editorIdentifier)
  }

  private var footer: some View {
    SetupFooter(
      title: state.needsPermission ? "Open System Settings" : "Continue",
      isEnabled: state.needsPermission || state.canContinue(hasSucceeded: hasSucceeded),
      action: primary
    ) {
      if state.canSkip(hasSucceeded: hasSucceeded) {
        SetupLinkButton(title: "Skip practice", quiet: true) {
          if state.canSkip(hasSucceeded: hasSucceeded) { onSkip() }
        }
      } else if hasSucceeded && !state.inFlight && state.acceptsFocus {
        Text("Next: a few quick tips.")
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
      }
    }
  }

  private func primary() {
    if state.needsPermission {
      onOpenPermissions()
    } else if state.canContinue(hasSucceeded: hasSucceeded) {
      onSucceeded()
    }
  }

  private func back() {
    if !state.inFlight { onBack() }
  }
}
