import AVFoundation
import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Observation
import SwiftUI

struct SetupPracticeTake: Equatable {
  let id: String
  let phase: PipelineState
  let locked: Bool
  let terminal: PracticeTakeEvidence?
}

enum SetupPracticeResult: Equatable {
  case completed(polished: Bool)
  case missedBox, noSpeech, skipped, pipelineFailed
  case microphoneDenied, accessibilityDenied
}

struct SetupPracticeSources {
  let settings: SettingsManager
  let devices: AudioDeviceList
  let live: LiveRecordingState
  var report: (SetupPracticeResult, TimeInterval) -> Void
}

/// The backend session retains this across presenter destruction, but not a route or visit reset.
@MainActor @Observable
final class SetupPracticeProgress {
  var text = ""
  var attempt = SetupPracticeAttempt()

  func reset() {
    text = ""
    attempt = SetupPracticeAttempt()
  }
}

/// Only a take-bound receipt from the synchronous, verified paste can establish success.
struct SetupPracticeAttempt {
  private var activeID: String?
  private var expectedEditor: String?
  private(set) var state: SetupPracticeState = .waiting
  private(set) var result: SetupPracticeResult = .skipped
  private(set) var success: SetupPracticeResult?

  mutating func detachEditor() {
    activeID = nil
    expectedEditor = nil
  }

  mutating func observe(_ take: SetupPracticeTake, focusedEditor: String?) {
    if take.phase.isActive {
      if activeID != take.id {
        activeID = take.id
        expectedEditor = focusedEditor
      }
      return
    }
    guard let terminal = take.terminal, activeID == take.id else { return }
    let editor = expectedEditor
    detachEditor()
    switch terminal {
    case .delivered(let verifiedEditor, let copied, let polished):
      if let editor, verifiedEditor == editor {
        success = .completed(polished: polished)
        state = .worked
        result = .completed(polished: polished)
      } else {
        state = .missedBox(copiedToClipboard: copied)
        result = .missedBox
      }
    case .noSpeech:
      state = .noSpeech
      result = .noSpeech
    case .failed:
      state = .pipelineFailed
      result = .pipelineFailed
    case .cancelled:
      break
    }
  }
}

struct SetupPracticeRoute: View {
  let model: SetupScreenModel
  let epoch: Int
  let sources: SetupPracticeSources
  @Bindable var progress: SetupPracticeProgress

  @State private var editorID = PasteService.practiceEditorIdentifierPrefix + UUID().uuidString
  private var attempt: SetupPracticeAttempt { progress.attempt }
  @State private var editorFocused = false
  @State private var window = EGOneHostWindow()
  @State private var entered = Date()
  @State private var askedAccessibility = false

  private var editorOwnsFocus: Bool { editorFocused && window.window?.isKeyWindow == true }

  var body: some View {
    let take = sources.live.practiceTake
    let state = displayed(take)
    SetupPracticeScreen(
      state: state, text: $progress.text,
      hasSucceeded: attempt.success != nil, key: key,
      polish: (model.state.choices.polish ?? OnboardingChoices.polishOff)
        == OnboardingChoices.polishOff ? .off : .live,
      settings: sources.settings, devices: sources.devices.availableInputDevices,
      onSucceeded: { finish(.practiceSucceeded) },
      onSkip: { finish(.skipPractice) },
      onBack: { if isCurrent && !sources.live.isDictationActive { model.send(.back) } },
      onOpenPermissions: openPermissions,
      onFocusChange: { editorFocused = $0 },
      editorIdentifier: editorID,
      mayFocusEditor: { isCurrent && !sources.live.isDictationActive }
    )
    .background(EGOneHostWindowReader(host: window).allowsHitTesting(false))
    .onAppear {
      entered = Date()
      progress.attempt.detachEditor()
      progress.attempt.observe(take, focusedEditor: nil)
      model.screenMounted(.practice, epoch: epoch)
    }
    .onChange(of: take) { _, next in
      guard isCurrent else { return }
      progress.attempt.observe(next, focusedEditor: editorOwnsFocus ? editorID : nil)
    }
  }

  private var isCurrent: Bool { model.routeEpoch == epoch && model.state.step == .practice }

  private var key: String {
    switch sources.settings.shortcutBindings.record {
    case .keyboard(let code, let modifiers): KeySymbols.format(keyCode: code, modifiers: modifiers)
    }
  }

  private func displayed(_ take: SetupPracticeTake) -> SetupPracticeState {
    switch take.phase {
    case .loadingModel, .transcribing: return .transcribing
    case .recording: return .listening(handsFree: take.locked)
    case .polishing: return .polishing
    case .idle, .complete, .error, .advisory: break
    }
    if let permissions = model.sources.permissions {
      if permissions.microphone() != .authorized { return .microphoneOff }
      if !permissions.accessibilityAllowed() { return .accessibilityOff }
    }
    return model.isPracticeUsable ? attempt.state : .preparing
  }

  private func finish(_ event: OnboardingEvent) {
    guard isCurrent, !sources.live.isDictationActive else { return }
    let state = displayed(sources.live.practiceTake)
    let result: SetupPracticeResult
    if event == .practiceSucceeded {
      guard state.canContinue(hasSucceeded: attempt.success != nil), let success = attempt.success
      else { return }
      result = success
    } else {
      guard state.canSkip(hasSucceeded: attempt.success != nil) else { return }
      switch state {
      case .microphoneOff: result = .microphoneDenied
      case .accessibilityOff: result = .accessibilityDenied
      default: result = attempt.result
      }
    }
    sources.report(result, max(0, Date().timeIntervalSince(entered)))
    model.send(event)
  }

  private func openPermissions() {
    guard isCurrent, let actions = model.sources.permissions?.actions else { return }
    switch displayed(sources.live.practiceTake) {
    case .microphoneOff: Task { await actions.microphone() }
    case .accessibilityOff:
      actions.accessibility(askedAccessibility)
      askedAccessibility = true
    default: break
    }
  }
}
