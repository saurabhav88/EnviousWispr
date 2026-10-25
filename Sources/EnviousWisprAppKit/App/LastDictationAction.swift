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
  /// Where a paste was aimed (#3437): the front application, or a keyboard-focus owner that is not
  /// front (a launcher panel such as Raycast's). Logged, not sent as telemetry.
  enum Route: String, CaseIterable { case front, owner }

  /// The keyboard-focus owner sampled at the chord press (#3437): the application and the exact
  /// focused element, so the write can confirm the same field, not only the same process.
  struct KeyboardOwnerSnapshot {
    let application: NSRunningApplication
    let element: AXUIElement
  }

  /// What a Paste was aimed at when its gesture began.
  enum ChordTarget {
    /// The front application (nil when none could be read).
    case front(NSRunningApplication?)
    /// A different application holding the keyboard focus, which a post at the session tap would
    /// never reach (#3437, measured with Raycast's panel).
    case focusOwner(KeyboardOwnerSnapshot)

    var application: NSRunningApplication? {
      switch self {
      case .front(let application): application
      case .focusOwner(let snapshot): snapshot.application
      }
    }

    var route: Route {
      switch self {
      case .front: .front
      case .focusOwner: .owner
      }
    }
  }

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
    /// The task running the paste was cancelled during one of its waits, or a newer Copy Last
    /// superseded it before its write (#3135), so nothing was written. Distinct from `keys_held`:
    /// nothing about the user's keys is known when this is reported.
    case cancelled
    /// The clipboard write did not take (read back and not found), so nothing was pasted or copied.
    case writeFailed = "write_failed"
  }

  /// Everything this action touches, injected so a test drives it without a desktop.
  struct Environment {
    var lastPasteable: @MainActor () -> (id: UUID, text: String)?
    var textForReuse: @MainActor (UUID) -> String?
    var isDictationActive: @MainActor () -> Bool
    var isAccessibilityTrusted: @MainActor () -> Bool
    var frontmost: @MainActor () -> NSRunningApplication?
    /// The application and element holding the system keyboard focus, when it is an eligible
    /// application (#3437). One bounded Accessibility read per call; nil when unreadable.
    var keyboardOwner: @MainActor () -> KeyboardOwnerSnapshot?
    var isTerminated: @MainActor (NSRunningApplication) -> Bool
    /// Whether an application is this app. Asked as a question, not by comparing a pid here,
    /// because `NSRunningApplication.current` has no pid outside a launched app bundle.
    var isOwnApplication: @MainActor (NSRunningApplication) -> Bool
    var activate: @MainActor (NSRunningApplication) -> Bool
    var modifiersHeld: @MainActor () -> Bool
    var restoreClipboard: @MainActor () -> Bool
    /// The "keep dictations out of clipboard history apps" setting (#3672), read at the same moment
    /// as `restoreClipboard`, immediately before the write.
    var markTransient: @MainActor () -> Bool
    /// Whether the clipboard is still held by the last dictation's cleanup or a Quick Add takeover,
    /// so a reuse write now would be refused (#3135). `ClipboardCleanup.isBoardHeldForManualWrite`.
    var clipboardHeld: @MainActor () -> Bool
    /// Told how long a reuse waited when it found the clipboard held (#3135); DEBUG log in
    /// production, so a live check can prove it met a held board rather than a free one.
    var clipboardWaited: @MainActor (Duration) -> Void
    /// `ClipboardCleanup.manualPaste` on the general board with the real Cmd+V, in production.
    var manualPaste:
      @MainActor (_ text: String, _ restore: Bool, _ markTransient: Bool) ->
        ClipboardCleanup.ManualClipboardResult
    /// `manualPaste` with Cmd+V posted at one process (#3437), for a keyboard owner that is not
    /// front; the same clipboard transaction, restore and transient-marker contracts.
    var manualPasteAtProcess:
      @MainActor (_ text: String, _ restore: Bool, _ markTransient: Bool, _ pid: pid_t) ->
        ClipboardCleanup.ManualClipboardResult
    var manualCopy: @MainActor (_ text: String) -> ClipboardCleanup.ManualClipboardResult
    var openPermissions: @MainActor () -> Void
    /// The route is the paste's own (nil for Copy), captured when its gesture began.
    var report: @MainActor (Action, Source, Outcome, Route?) -> Void
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

  /// What the Paste chord was aimed at when it went DOWN: the front application, or a keyboard
  /// owner that is not front (#3437). Taken on the press because the paste fires on the release;
  /// consumed by that release.
  private var chordTarget: ChordTarget?

  /// The Copy Last still waiting for the clipboard, if any (#3135). Any newer reuse cancels it, a
  /// Copy at its press and a Paste immediately before its write: the latest action wins, so an older
  /// copy cannot wake afterwards and overwrite the clipboard a newer one wrote (or is pasting from).
  private var pendingCopy: Task<Void, Never>?

  /// Copy presses so far (#3135). A Paste notes the count at its press and refuses (`cancelled`)
  /// if a Copy was pressed since, immediately before its write: a paste still waiting must not wake
  /// after a newer Copy and replace the clipboard that Copy set. A newer Paste does not stop an
  /// older one; two Paste presses paste twice, as before (#3106).
  private var copyPresses = 0

  init(environment: Environment) {
    self.environment = environment
  }

  // MARK: Entry points

  /// The Paste Last chord went down. Samples the target now, before anything can move focus: the
  /// front application, and the keyboard owner (#3437). A different eligible application holding
  /// the keyboard (a launcher panel over the front app) becomes the target; otherwise the front app.
  func notePasteChordPressed() {
    let front = environment.frontmost()
    if let owner = environment.keyboardOwner(), !environment.isTerminated(owner.application),
      !environment.isOwnApplication(owner.application),
      owner.application.processIdentifier != front?.processIdentifier
    {
      chordTarget = .focusOwner(owner)
    } else {
      chordTarget = .front(front)
    }
  }

  /// The Paste Last chord was released. SYNCHRONOUS on the release turn: the press-time target and
  /// the row to paste are taken now, into this invocation's own task, so a second press arriving
  /// before that task runs cannot replace either (final review, #3106). The returned task lets a
  /// caller (a test) wait for this one invocation.
  @discardableResult
  func pasteFromChord() -> Task<Void, Never> {
    let target = chordTarget ?? .front(nil)
    chordTarget = nil
    let rowID = environment.lastPasteable()?.id
    let copiesAtPress = copyPresses
    return Task {
      await paste(rowID: rowID, target: target, source: .chord, copiesAtPress: copiesAtPress)
    }
  }

  /// The menu item was chosen. `rowID` and `target` were sampled when the menu opened. SYNCHRONOUS
  /// on the menu's turn, like the chord's release, so the Copy count is taken at the choice, not
  /// when the task first runs (#3135). The returned task lets a caller (a test) wait for it.
  @discardableResult
  func pasteFromMenu(rowID: UUID?, target: NSRunningApplication?) -> Task<Void, Never> {
    let copiesAtPress = copyPresses
    return Task {
      await paste(rowID: rowID, target: .front(target), source: .menu, copiesAtPress: copiesAtPress)
    }
  }

  /// The Copy Last chord was pressed. The recording check and the row are taken now, on the press;
  /// the copy itself may wait for the clipboard (#3135), so it runs in the returned task.
  @discardableResult
  func copyFromChord() -> Task<Void, Never> {
    let recordingAtPress = environment.isDictationActive()
    let rowID = environment.lastPasteable()?.id
    copyPresses += 1
    pendingCopy?.cancel()
    let task = Task {
      finish(
        .copy, .chord, await copy(rowID: rowID, recordingAtPress: recordingAtPress), route: nil)
    }
    pendingCopy = task
    return task
  }

  // MARK: Copy

  private func copy(rowID: UUID?, recordingAtPress: Bool) async -> Outcome {
    guard !recordingAtPress else { return .recording }
    guard let rowID, environment.textForReuse(rowID) != nil else { return .noDictation }
    if let refusal = await waitForClipboard() { return refusal }
    // Every await is followed by the re-checks: the row is read again by id, never from the press.
    guard !environment.isDictationActive() else { return .recording }
    guard let text = environment.textForReuse(rowID) else { return .noDictation }
    switch environment.manualCopy(text) {
    case .copied: return .copied
    case .clipboardBusy: return .clipboardBusy
    case .writeFailed: return .writeFailed
    // `manualCopy` produces neither; mapped rather than trapped so a future change surfaces as a
    // wrong-looking outcome in telemetry instead of a crash on the user's keypress.
    case .dispatched, .dispatchFailed: return .dispatchFailed
    }
  }

  // MARK: Paste

  private func paste(
    rowID: UUID?, target chordTarget: ChordTarget, source: Source, copiesAtPress: Int
  ) async {
    finish(
      .paste, source,
      await pasteOutcome(
        rowID: rowID, chordTarget: chordTarget, source: source, copiesAtPress: copiesAtPress),
      route: chordTarget.route)
  }

  private func pasteOutcome(
    rowID: UUID?, chordTarget: ChordTarget, source: Source, copiesAtPress: Int
  ) async -> Outcome {
    let target = chordTarget.application
    // Checked before anything is resolved: a recording in flight owns the clipboard's next write.
    guard !environment.isDictationActive() else { return .recording }
    // Before Accessibility: with nothing to paste, the truthful answer is that, not a permission.
    guard let rowID, environment.textForReuse(rowID) != nil else { return .noDictation }
    // The target before Accessibility, for the same reason: granting the permission cannot make a
    // quit app or our own window pasteable, so sending the user to Permissions would be untrue.
    guard let target, !environment.isTerminated(target) else { return .targetGone }
    guard !environment.isOwnApplication(target) else { return .ownWindow }
    guard environment.isAccessibilityTrusted() else { return refuseAccessibility(source) }

    // The user's fingers may still be on the chord's modifiers when its key comes up. Wait for them
    // to be OBSERVED up, not for a guessed interval.
    switch await DeadlinePoll.wait(
      within: Self.modifierReleaseDeadline, every: Self.pollInterval, now: environment.now,
      sleep: environment.sleep, { !self.environment.modifiersHeld() })
    {
    case .met: break
    case .expired: return .keysHeld
    case .cancelled: return .cancelled
    }

    // Before focus is moved: a paste pressed right after a dictation meets that dictation's cleanup
    // still holding the clipboard, and a write now would be refused (#3135).
    if let refusal = await waitForClipboard() { return refusal }

    // Re-checked BEFORE focus is moved: a recording may have started, the target quit or the row
    // been deleted while we waited, and activating an app for a paste that will not happen is a
    // visible side effect of its own.
    if let refusal = recheck(rowID: rowID, target: target, source: source) { return refusal }

    switch chordTarget {
    case .front:
      // Usually still in front (a chord pressed in place; a status-bar menu does not activate us).
      // When it is not, bring it back and wait for that to be observed.
      if !isFrontmost(target) {
        _ = environment.activate(target)
        switch await DeadlinePoll.wait(
          within: Self.activationDeadline, every: Self.pollInterval, now: environment.now,
          sleep: environment.sleep, { self.isFrontmost(target) })
        {
        case .met: break
        case .expired: return environment.isTerminated(target) ? .targetGone : .focusLost
        case .cancelled: return .cancelled
        }
      }

      // And again after the activation wait, the last await before the write.
      if let refusal = recheck(rowID: rowID, target: target, source: source) { return refusal }
      guard isFrontmost(target) else { return .focusLost }
    case .focusOwner(let snapshot):
      // A keyboard owner is never activated: activating it would move the focus the paste is for.
      // Its confirmation is the last Accessibility query, saved before the common rechecks so a
      // read that failed because the owner quit or the permission went reports that, not focus_lost.
      let confirmation = environment.keyboardOwner()
      if let refusal = recheck(rowID: rowID, target: target, source: source) { return refusal }
      if Task.isCancelled { return .cancelled }
      // The same process AND the same focused field: a panel that moved its focus to another of its
      // fields, or closed, must not receive this paste, and nothing falls back to the front app.
      guard let confirmation,
        confirmation.application.processIdentifier == snapshot.application.processIdentifier,
        CFEqual(confirmation.element, snapshot.element)
      else { return .focusLost }
    }
    guard let text = environment.textForReuse(rowID) else { return .noDictation }
    // Read AGAIN immediately before the write: the activation wait above can take up to 500 ms, and
    // a Control or Command pressed during it would ride into the synthetic Cmd+V (final review,
    // #3106). No await separates this read from the write, so it is the state the paste meets.
    guard !environment.modifiersHeld() else { return .keysHeld }

    // No await between these and the write. A Copy pressed since this paste's press set the
    // clipboard the user now wants; and an older Copy still waiting must not wake afterwards and
    // replace the text this paste is about to put there.
    guard copyPresses == copiesAtPress else { return .cancelled }
    pendingCopy?.cancel()
    let result: ClipboardCleanup.ManualClipboardResult
    switch chordTarget {
    case .front:
      result = environment.manualPaste(
        text, environment.restoreClipboard(), environment.markTransient())
    case .focusOwner:
      result = environment.manualPasteAtProcess(
        text, environment.restoreClipboard(), environment.markTransient(),
        target.processIdentifier)
    }
    switch result {
    case .dispatched: return .dispatched
    case .dispatchFailed: return .dispatchFailed
    case .clipboardBusy: return .clipboardBusy
    case .writeFailed: return .writeFailed
    // `manualPaste` never copies without dispatching; mapped rather than trapped, as in `copy()`.
    case .copied: return .dispatchFailed
    }
  }

  /// Everything that can change during an await, in the order the first pass checks it.
  private func recheck(rowID: UUID, target: NSRunningApplication, source: Source) -> Outcome? {
    if environment.isDictationActive() { return .recording }
    if environment.textForReuse(rowID) == nil { return .noDictation }
    if environment.isTerminated(target) { return .targetGone }
    if !environment.isAccessibilityTrusted() { return refuseAccessibility(source) }
    return nil
  }

  /// Without Accessibility macOS drops the synthetic Cmd+V silently. From the menu the user is
  /// looking at us and can be sent to the fix; a chord has nowhere to show it. The same answer
  /// whether the permission was missing at the start or revoked during a wait.
  private func refuseAccessibility(_ source: Source) -> Outcome {
    if source == .menu { environment.openPermissions() }
    return .axDenied
  }

  /// Waits, bounded, for the clipboard to be released (#3135). Nil when it is free; the refusal
  /// otherwise. The write still claims the board itself, so a hold that returns after this wait is
  /// refused there exactly as before.
  private func waitForClipboard() async -> Outcome? {
    // Before the free-board return: a task cancelled before it began (a newer Copy pressed first)
    // must not write just because the board happens to be free; `DeadlinePoll` is not reached then.
    if Task.isCancelled { return .cancelled }
    guard environment.clipboardHeld() else { return nil }
    let started = environment.now()
    let result = await DeadlinePoll.wait(
      within: ClipboardCleanup.manualWriteWaitBound, every: Self.pollInterval,
      now: environment.now, sleep: environment.sleep, { !self.environment.clipboardHeld() })
    environment.clipboardWaited(environment.now() - started)
    switch result {
    case .met: return nil
    case .expired: return .clipboardBusy
    case .cancelled: return .cancelled
    }
  }

  private func isFrontmost(_ application: NSRunningApplication) -> Bool {
    environment.frontmost()?.processIdentifier == application.processIdentifier
  }

  private func finish(_ action: Action, _ source: Source, _ outcome: Outcome, route: Route?) {
    environment.report(action, source, outcome, route)
  }
}

// MARK: - Production wiring

extension LastDictationAction {

  /// Whether `pid` shows at least one window (#3437). A launcher whose panel was closed can keep
  /// the system keyboard focus on a hidden element: measured with Raycast, after its panel was
  /// opened and closed with Escape it had zero windows and still read as the keyboard owner, so a
  /// paste aimed there landed nowhere while the front app received nothing. An owner with no
  /// window is therefore not a paste target, and the front app is. Bounded like the focus read; a
  /// failed read answers false (the front route, today's behaviour).
  static func showsAWindow(pid: pid_t) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetMessagingTimeout(
      application, Float(PasteService.keyboardFocusReadCapSeconds))
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        == .success,
      let windows = value as? [AXUIElement]
    else { return false }
    return !windows.isEmpty
  }

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
        keyboardOwner: {
          guard
            case .focused(let element, let pid) = PasteService.readKeyboardFocus(
              cap: PasteService.keyboardFocusReadCapSeconds, admit: nil),
            let application = NSRunningApplication(processIdentifier: pid),
            PasteService.isEligibleFocusOwner(
              activationPolicy: application.activationPolicy,
              isTerminated: application.isTerminated),
            showsAWindow(pid: pid)
          else { return nil }
          return KeyboardOwnerSnapshot(application: application, element: element)
        },
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
        markTransient: { [weak settings] in settings?.keepDictationsOutOfClipboardHistory ?? false
        },
        clipboardHeld: { ClipboardCleanup.isBoardHeldForManualWrite(.general) },
        clipboardWaited: { waited in
          Task {
            await AppLogger.shared.log(
              "last dictation reuse: waited for the clipboard ms=\(waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000)",
              level: .info, category: "LastDictation")
          }
        },
        manualPaste: { text, restore, markTransient in
          ClipboardCleanup.manualPaste(
            text: text, restore: restore, markTransient: markTransient, on: .general,
            dispatch: {
              PasteService.postPasteKeystroke(keyCode: SyntheticCopyChord.commandVKeyCode())
            })
        },
        manualPasteAtProcess: { text, restore, markTransient, pid in
          ClipboardCleanup.manualPaste(
            text: text, restore: restore, markTransient: markTransient, on: .general,
            dispatch: { SyntheticCopyChord.postCommandV(at: pid) })
        },
        manualCopy: { ClipboardCleanup.manualCopy(text: $0, on: .general) },
        openPermissions: openPermissions,
        report: { action, source, outcome, route in
          TelemetryService.shared.lastDictationReused(
            action: action.rawValue, source: source.rawValue, outcome: outcome.rawValue)
          let routeField = route.map { " route=\($0.rawValue)" } ?? ""
          Task {
            await AppLogger.shared.log(
              "last dictation reuse: action=\(action.rawValue) source=\(source.rawValue) "
                + "outcome=\(outcome.rawValue)\(routeField)",
              level: .info, category: "LastDictation")
          }
        },
        sleep: { try? await Task.sleep(for: $0) },
        now: { ContinuousClock.now }))
  }
}
