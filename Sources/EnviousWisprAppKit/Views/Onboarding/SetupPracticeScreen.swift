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

  func subtitle(key: String, microphone: String?) -> LocalizedStringKey {
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
      if let microphone {
        "EnviousWispr heard only silence from \(microphone).\nPick another microphone, or hold \(key) and speak."
      } else {
        "EnviousWispr didn’t hear any speech.\nPick another microphone, or hold \(key) and speak."
      }
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
  var showPillPicture = false

  @FocusState private var editorFocused: Bool

  var body: some View {
    let mic = MicrophonePickerModel(settingsManager: settings, devices: devices)
    VStack(spacing: DesignSpacing.xl) {
      RainbowLipsView(animationState: state.lips, size: SetupMetrics.screenLips)
        .accessibilityHidden(true)
      VStack(spacing: DesignSpacing.md) {
        Text(state.headline)
          .font(.firstRunDisplay)
          .foregroundStyle(Color.obTextPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(state.subtitle(key: key, microphone: mic.presentation.deviceName))
          .font(.firstRunBody)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .multilineTextAlignment(.center)

      if state.acceptsFocus {
        prompt
        editor
        if state == .worked, let note = polish.note {
          Text(note)
            .font(.firstRunCaption)
            .foregroundStyle(Color.obTextSecondary)
            .multilineTextAlignment(.center)
        } else if state != .worked && !state.inFlight {
          MicrophoneDevicePicker(model: mic)
        }
      }
      Spacer(minLength: 0)
      if showPillPicture { SetupPracticePillPicture(state: state) }
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
    .onAppear { editorFocused = state.acceptsFocus }
    .onDisappear { onFocusChange(false) }
    .onChange(of: editorFocused) { _, focused in onFocusChange(focused) }
    .onChange(of: state) { old, new in
      if !new.acceptsFocus {
        editorFocused = false
      } else if !old.acceptsFocus {
        editorFocused = true
      } else if case .missedBox = new {
        editorFocused = true
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
      }
      .focused($editorFocused)
      .accessibilityLabel("Your first dictation")
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
