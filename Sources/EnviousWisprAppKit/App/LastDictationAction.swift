import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Paste or copy the newest delivered dictation again (#3106): the one owner behind the menu-bar
/// item, the Paste Last chord and the Copy Last chord. Each of those is a thin caller.
///
/// **Branches on the action FIRST.** Copy needs no target, no activation and no Accessibility: it
/// puts text on the clipboard and works even with our own window in front. Paste aims a synthetic
/// Cmd+V at another application, so every check below is Paste's alone.
///
/// **Paste never pastes into an application the user did not choose.** The target is the
/// application sampled when the user acted (the chord's PRESS, or the menu's opening), never the one
/// frontmost when the paste finally runs. If it quit, is us, or cannot be brought back to the front,
/// the action refuses and writes nothing.
///
/// **Every await is followed by the same re-checks**: recording, the target, and the row read again
/// by id. The text is never taken from a snapshot made before an await.
@MainActor
final class LastDictationAction {

  enum Action: String, CaseIterable { case paste, copy }
  enum Source: String, CaseIterable { case menu, chord }

  /// The closed outcome vocabulary of `dictation.last_reused`. `dispatched` means Cmd+V was POSTED,
  /// not that the text landed: nothing observes landing here. `copied` means the write succeeded.
  enum Outcome: String, CaseIterable {
    case dispatched
    case copied
    case dispatchFailed = "dispatch_failed"
    case clipboardBusy = "clipboard_busy"
    case noDictation = "no_dictation"
    case ownWindow = "own_window"
    case targetGone = "target_gone"
    case recording
    case axDenied = "ax_denied"
    /// The chord's modifiers were still held when the deadline passed, so no Cmd+V was posted: a
    /// held Control or Command can turn the synthetic paste into a different chord.
    case keysHeld = "keys_held"
    /// The sampled application could not be brought back to the front, so no Cmd+V was posted.
    /// Posting anyway would paste into whatever app IS in front.
    case focusLost = "focus_lost"
    /// The task running the paste was cancelled during one of its waits, so nothing was written.
    /// Distinct from `keys_held`: nothing about the user's keys is known when this is reported.
    case cancelled
  }

  /// Everything this action touches, injected so a test drives it without a desktop.
  struct Environment {
    var lastPasteable: @MainActor () -> (id: UUID, text: String)?
    var textForReuse: @MainActor (UUID) -> String?
    var isDictationActive: @MainActor () -> Bool
    var isAccessibilityTrusted: @MainActor () -> Bool
    var frontmost: @MainActor () -> NSRunningApplication?
    var isTerminated: @MainActor (NSRunningApplication) -> Bool
    /// Whether an application is this app. Asked as a question, not by comparing a pid here,
    /// because `NSRunningApplication.current` has no pid outside a launched app bundle.
    var isOwnApplication: @MainActor (NSRunningApplication) -> Bool
    var activate: @MainActor (NSRunningApplication) -> Bool
    var modifiersHeld: @MainActor () -> Bool
    var restoreClipboard: @MainActor () -> Bool
    /// `ClipboardCleanup.manualPaste` on the general board with the real Cmd+V, in production.
    var manualPaste:
      @MainActor (_ text: String, _ restore: Bool) -> ClipboardCleanup.ManualClipboardResult
    var manualCopy: @MainActor (_ text: String) -> ClipboardCleanup.ManualClipboardResult
    var openPermissions: @MainActor () -> Void
    var report: @MainActor (Action, Source, Outcome) -> Void
    var sleep: @MainActor (Duration) async -> Void
    /// A monotonic reading. The waits end when THIS says the deadline passed, not after a count of
    /// sleeps: a loaded main actor makes each sleep longer than asked.
    var now: @MainActor () -> ContinuousClock.Instant
  }

  /// How often the two waits look, and how long they may take. The poll is cheap (one flags read,
  /// one frontmost read); the deadlines are fail-safes, not expected durations, measured on `now`.
  static let pollInterval: Duration = .milliseconds(10)
  static let modifierReleaseDeadline: Duration = .seconds(1)
  static let activationDeadline: Duration = .milliseconds(500)

  private let environment: Environment

  /// The application frontmost when the Paste chord went DOWN. Taken on the press because the paste
  /// fires on the release; consumed by that release.
  private var chordTarget: NSRunningApplication?

  init(environment: Environment) {
    self.environment = environment
  }

  // MARK: Entry points

  /// The Paste Last chord went down. Samples the target now, before anything can move focus.
  func notePasteChordPressed() {
    chordTarget = environment.frontmost()
  }

  /// The Paste Last chord was released.
  func pasteFromChord() async {
    let target = chordTarget
    chordTarget = nil
    await paste(rowID: environment.lastPasteable()?.id, target: target, source: .chord)
  }

  /// The menu item was chosen. `rowID` and `target` were sampled when the menu opened.
  func pasteFromMenu(rowID: UUID?, target: NSRunningApplication?) async {
    await paste(rowID: rowID, target: target, source: .menu)
  }

  /// The Copy Last chord was pressed.
  func copyFromChord() {
    finish(.copy, .chord, copy())
  }

  // MARK: Copy

  private func copy() -> Outcome {
    guard !environment.isDictationActive() else { return .recording }
    guard let row = environment.lastPasteable(), let text = environment.textForReuse(row.id)
    else { return .noDictation }
    switch environment.manualCopy(text) {
    case .copied: return .copied
    case .clipboardBusy: return .clipboardBusy
    // `manualCopy` produces neither; mapped rather than trapped so a future change surfaces as a
    // wrong-looking outcome in telemetry instead of a crash on the user's keypress.
    case .dispatched, .dispatchFailed: return .dispatchFailed
    }
  }

  // MARK: Paste

  private func paste(rowID: UUID?, target: NSRunningApplication?, source: Source) async {
    finish(.paste, source, await pasteOutcome(rowID: rowID, target: target, source: source))
  }

  private func pasteOutcome(rowID: UUID?, target: NSRunningApplication?, source: Source) async
    -> Outcome
  {
    // Checked before anything is resolved: a recording in flight owns the clipboard's next write.
    guard !environment.isDictationActive() else { return .recording }
    // Before Accessibility: with nothing to paste, the truthful answer is that, not a permission.
    guard let rowID, environment.textForReuse(rowID) != nil else { return .noDictation }
    guard environment.isAccessibilityTrusted() else { return refuseAccessibility(source) }
    guard let target, !environment.isTerminated(target) else { return .targetGone }
    guard !environment.isOwnApplication(target) else { return .ownWindow }

    // The user's fingers may still be on the chord's modifiers when its key comes up. Wait for them
    // to be OBSERVED up, not for a guessed interval.
    switch await waitUntil(
      within: Self.modifierReleaseDeadline, { !self.environment.modifiersHeld() })
    {
    case .met: break
    case .expired: return .keysHeld
    case .cancelled: return .cancelled
    }

    // Re-checked BEFORE focus is moved: a recording may have started, the target quit or the row
    // been deleted while we waited, and activating an app for a paste that will not happen is a
    // visible side effect of its own.
    if let refusal = recheck(rowID: rowID, target: target, source: source) { return refusal }

    // Usually still in front (a chord pressed in place; a status-bar menu does not activate us).
    // When it is not, bring it back and wait for that to be observed.
    if !isFrontmost(target) {
      _ = environment.activate(target)
      switch await waitUntil(within: Self.activationDeadline, { self.isFrontmost(target) }) {
      case .met: break
      case .expired: return environment.isTerminated(target) ? .targetGone : .focusLost
      case .cancelled: return .cancelled
      }
    }

    // And again after the activation wait, the last await before the write.
    if let refusal = recheck(rowID: rowID, target: target, source: source) { return refusal }
    guard isFrontmost(target) else { return .focusLost }
    guard let text = environment.textForReuse(rowID) else { return .noDictation }

    switch environment.manualPaste(text, environment.restoreClipboard()) {
    case .dispatched: return .dispatched
    case .dispatchFailed: return .dispatchFailed
    case .clipboardBusy: return .clipboardBusy
    // `manualPaste` never copies without dispatching; mapped rather than trapped, as in `copy()`.
    case .copied: return .dispatchFailed
    }
  }

  /// Everything that can change during an await, in the order the first pass checks it.
  private func recheck(rowID: UUID, target: NSRunningApplication, source: Source) -> Outcome? {
    if environment.isDictationActive() { return .recording }
    if environment.textForReuse(rowID) == nil { return .noDictation }
    if !environment.isAccessibilityTrusted() { return refuseAccessibility(source) }
    if environment.isTerminated(target) { return .targetGone }
    return nil
  }

  /// Without Accessibility macOS drops the synthetic Cmd+V silently. From the menu the user is
  /// looking at us and can be sent to the fix; a chord has nowhere to show it. The same answer
  /// whether the permission was missing at the start or revoked during a wait.
  private func refuseAccessibility(_ source: Source) -> Outcome {
    if source == .menu { environment.openPermissions() }
    return .axDenied
  }

  private func isFrontmost(_ application: NSRunningApplication) -> Bool {
    environment.frontmost()?.processIdentifier == application.processIdentifier
  }

  private enum WaitResult { case met, expired, cancelled }

  /// Polls `condition` until it holds or `deadline` has passed on `now`.
  ///
  /// **Cancellation is checked BEFORE the condition, on entry and after every sleep, and after a
  /// sleep expiry is checked before it too.** A poll that
  /// resumes late, past the deadline, must not accept a release it only now observes: the paste
  /// would land long after the user stopped expecting it. Likewise a cancelled task never pastes.
  private func waitUntil(within deadline: Duration, _ condition: @MainActor () -> Bool) async
    -> WaitResult
  {
    let end = environment.now() + deadline
    // Even the first look: a task cancelled before it began must not paste on a condition that
    // happens to hold already.
    if Task.isCancelled { return .cancelled }
    if condition() { return .met }
    while true {
      await environment.sleep(Self.pollInterval)
      if Task.isCancelled { return .cancelled }
      if environment.now() >= end { return .expired }
      if condition() { return .met }
    }
  }

  private func finish(_ action: Action, _ source: Source, _ outcome: Outcome) {
    environment.report(action, source, outcome)
  }
}

// MARK: - Production wiring

extension LastDictationAction {

  /// The production environment. Every desktop effect is here, so nothing above reaches the real
  /// clipboard, keyboard or focus unless this is the environment it was given.
  static func live(
    transcripts: TranscriptCoordinator,
    liveRecordingState: LiveRecordingState,
    settings: SettingsManager,
    application: any ApplicationActivating,
    openPermissions: @escaping @MainActor () -> Void
  ) -> LastDictationAction {
    LastDictationAction(
      environment: Environment(
        lastPasteable: { [weak transcripts] in transcripts?.lastPasteableDictation() },
        textForReuse: { [weak transcripts] in transcripts?.lastDictationTextForReuse(id: $0) },
        isDictationActive: { [weak liveRecordingState] in
          liveRecordingState?.isDictationActive ?? true
        },
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        frontmost: { NSWorkspace.shared.frontmostApplication },
        isTerminated: { $0.isTerminated },
        isOwnApplication: { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier },
        // The AX route first, as Escape Recovery does: macOS 14+ refuses a background process the
        // foreground through `activate()`.
        activate: { app in
          application.forceActivate(processIdentifier: app.processIdentifier)
            || application.activate(app)
        },
        modifiersHeld: {
          let held = CGEventSource.flagsState(.combinedSessionState)
          return !held.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            .isEmpty
        },
        restoreClipboard: { [weak settings] in settings?.restoreClipboardAfterPaste ?? true },
        manualPaste: { text, restore in
          ClipboardCleanup.manualPaste(
            text: text, restore: restore, on: .general,
            dispatch: { PasteService.postPasteKeystroke() })
        },
        manualCopy: { ClipboardCleanup.manualCopy(text: $0, on: .general) },
        openPermissions: openPermissions,
        report: { action, source, outcome in
          TelemetryService.shared.lastDictationReused(
            action: action.rawValue, source: source.rawValue, outcome: outcome.rawValue)
          Task {
            await AppLogger.shared.log(
              "last dictation reuse: action=\(action.rawValue) source=\(source.rawValue) "
                + "outcome=\(outcome.rawValue)",
              level: .info, category: "LastDictation")
          }
        },
        sleep: { try? await Task.sleep(for: $0) },
        now: { ContinuousClock.now }))
  }
}
