import AVFoundation
import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
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

/// The editor owns the visible text. The kernel owns whether a take concluded and what was
/// delivered. History is not delivery evidence: a paste can succeed even if History fails.
struct SetupPracticeAttempt {
  private struct Start {
    let id: String
    let focused: Bool
    var edits: [(before: String, after: String)] = []
  }

  private var start: Start?
  /// A posted paste can reach TextEditor after the terminal, as with a key-event paste.
  /// Keep only the current take's expected text until the next take or route exit.
  private var awaitingEditor: (id: String, text: String, polished: Bool)?
  private var lastFinishedID: String?
  private(set) var state: SetupPracticeState = .waiting
  private(set) var result: SetupPracticeResult = .skipped
  private(set) var success: SetupPracticeResult?

  mutating func editorChanged(
    from before: String, to after: String, take: SetupPracticeTake,
    focused: Bool
  ) {
    if focused, let pending = awaitingEditor, pending.id == take.id,
      Self.received(pending.text, before: before, after: after)
    {
      awaitingEditor = nil
      markSuccess(polished: pending.polished)
      return
    }
    guard focused, start?.focused == true, start?.id == take.id, before != after,
      take.phase == .transcribing || take.phase == .polishing || take.phase == .complete
    else { return }
    start?.edits.append((before, after))
  }

  mutating func lostEditorFocus() {
    awaitingEditor = nil
  }

  mutating func observe(_ take: SetupPracticeTake, focused: Bool, mounted: Bool = false) {
    if take.phase.isActive {
      guard take.id != lastFinishedID else { return }
      if start?.id != take.id {
        awaitingEditor = nil
        // A take already running at mount chose its target before this editor existed.
        start = Start(id: take.id, focused: focused && !mounted)
      }
      return
    }
    guard let terminal = take.terminal, let attempt = start, attempt.id == take.id else {
      return
    }
    start = nil
    lastFinishedID = take.id
    switch terminal {
    case .delivered(let text, let pasted, let copied, let polished):
      if pasted,
        attempt.edits.contains(where: { Self.received(text, before: $0.before, after: $0.after) })
      {
        markSuccess(polished: polished)
      } else {
        if pasted, attempt.focused, focused {
          awaitingEditor = (take.id, text, polished)
        }
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

  private mutating func markSuccess(polished: Bool) {
    let completed = SetupPracticeResult.completed(polished: polished)
    success = completed
    state = .worked
    result = completed
  }

  /// A normal editor paste replaces one contiguous range. Require the delivered text itself
  /// and preserve the original prefix and suffix. This also works when the user selected text.
  static func received(_ text: String, before: String, after: String) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, after != before else {
      return false
    }
    var lower = after.startIndex
    while let match = after.range(of: text, options: .literal, range: lower..<after.endIndex) {
      let prefix = after[..<match.lowerBound]
      let suffix = after[match.upperBound...]
      if before.count >= prefix.count + suffix.count,
        before.hasPrefix(prefix), before.hasSuffix(suffix)
      {
        return true
      }
      lower = after.index(after: match.lowerBound)
    }
    return false
  }
}

struct SetupPracticeRoute: View {
  let model: SetupScreenModel
  let epoch: Int
  let sources: SetupPracticeSources

  @State private var text = ""
  @State private var attempt = SetupPracticeAttempt()
  @State private var editorFocused = false
  @State private var window = EGOneHostWindow()
  @State private var entered = Date()
  @State private var askedAccessibility = false

  private var editorOwnsFocus: Bool { editorFocused && window.window?.isKeyWindow == true }

  var body: some View {
    let take = sources.live.practiceTake
    let state = displayed(take)
    SetupPracticeScreen(
      state: state, text: Binding(get: { text }, set: edit),
      hasSucceeded: attempt.success != nil, key: key,
      polish: (model.state.choices.polish ?? OnboardingChoices.polishOff)
        == OnboardingChoices.polishOff ? .off : .live,
      settings: sources.settings, devices: sources.devices.availableInputDevices,
      onSucceeded: { finish(.practiceSucceeded) },
      onSkip: { finish(.skipPractice) },
      onBack: { if isCurrent && !sources.live.isDictationActive { model.send(.back) } },
      onOpenPermissions: openPermissions,
      onFocusChange: { focused in
        editorFocused = focused
        if !focused { attempt.lostEditorFocus() }
      }
    )
    .background(EGOneHostWindowReader(host: window).allowsHitTesting(false))
    .onAppear {
      entered = Date()
      attempt.observe(take, focused: false, mounted: true)
      model.screenMounted(.practice, epoch: epoch)
    }
    .onChange(of: take) { _, next in
      guard isCurrent else { return }
      attempt.observe(next, focused: editorOwnsFocus)
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

  private func edit(_ value: String) {
    let take = sources.live.practiceTake
    attempt.editorChanged(from: text, to: value, take: take, focused: editorOwnsFocus)
    text = value
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
