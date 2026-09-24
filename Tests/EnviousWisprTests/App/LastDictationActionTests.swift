import AppKit
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// What Paste Last and Copy Last Dictation actually do when invoked (#3106).
///
/// When one of these fails, the user's words are pasted into the wrong app or into our own window,
/// a cancelled or deleted row is pasted, a paste fires with Control and Command still held, or the
/// clipboard is written for a paste that was never going to happen.
///
/// Every desktop effect is a fake: nothing here activates an app, posts a key or touches a real
/// clipboard. The `NSRunningApplication` values are real objects read from the workspace and are
/// only compared, never activated.
@MainActor
@Suite("Paste and Copy Last Dictation: the action (#3106)", .tags(.productOutcome))
struct LastDictationActionTests {

  private final class Fake {
    var row: (id: UUID, text: String)? = (UUID(), "Send the draft to Maya.") {
      didSet { if let row { history[row.id] = row.text } }
    }
    /// Every row ever shown, by id, as History keeps them: a newer dictation does not remove an older
    /// one, so a reuse that captured an id can still read it (#3135 R2-1).
    var history: [UUID: String] = [:]
    /// How many polls report the clipboard still held by a cleanup; `Int.max` means never released.
    var clipboardHeldPolls = 0
    /// Whether a sleep really suspends (yields the main actor), so another action can run inside a
    /// wait. Off by default: most tests want a wait to run to its end in one go.
    var yieldOnSleep = false
    var deleted = false
    var dictationActive = false
    var axTrusted = true
    var frontmost: NSRunningApplication?
    var terminated: Set<pid_t> = []
    var activationSucceeds = true
    var activated: [pid_t] = []
    /// Which application stands in for this app. The test process is not a launched bundle, so
    /// `NSRunningApplication.current` has no pid to compare.
    var own: NSRunningApplication?
    /// How many polls report the modifiers still held; `Int.max` means never released.
    var heldPolls = 0
    var sleeps = 0
    var pasteResult: ClipboardCleanup.ManualClipboardResult = .dispatched
    var copyResult: ClipboardCleanup.ManualClipboardResult = .copied
    var pastes: [(text: String, restore: Bool)] = []
    var copies: [String] = []
    var permissionsOpened = 0
    var reports: [(LastDictationAction.Action, LastDictationAction.Source, String)] = []
    /// Runs on every sleep, so a test can change the world mid-wait.
    var duringWait: (() -> Void)?
    /// The monotonic clock the waits read. Each sleep advances it by what was asked plus `lag`, so a
    /// loaded main actor is a positive `lag`.
    var clock = ContinuousClock.now
    var lag: Duration = .zero
    /// Runs when the target is activated, so a test can change the world during that wait.
    var duringActivation: (() -> Void)?

    init() {
      if let row { history[row.id] = row.text }
    }
  }

  private static let own = ProcessInfo.processInfo.processIdentifier

  /// Two real, running applications that are not this process. Compared only.
  private static func twoOtherApps() throws -> (NSRunningApplication, NSRunningApplication) {
    // Any running application object will do (Finder, Dock and friends in a login session, which
    // the hosted runners have); the action only compares them.
    let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != own }
    let first = try #require(others.first, "no other application is running")
    let second = try #require(others.dropFirst().first, "needs two other applications")
    return (first, second)
  }

  private func makeAction(_ fake: Fake) -> LastDictationAction {
    LastDictationAction(
      environment: .init(
        lastPasteable: { fake.row },
        textForReuse: { id in
          guard !fake.deleted else { return nil }
          return fake.history[id]
        },
        isDictationActive: { fake.dictationActive },
        isAccessibilityTrusted: { fake.axTrusted },
        frontmost: { fake.frontmost },
        isTerminated: { fake.terminated.contains($0.processIdentifier) },
        isOwnApplication: { app in fake.own.map { $0 === app } ?? false },
        activate: { app in
          fake.activated.append(app.processIdentifier)
          fake.duringActivation?()
          if fake.activationSucceeds { fake.frontmost = app }
          return fake.activationSucceeds
        },
        modifiersHeld: {
          guard fake.heldPolls > 0 else { return false }
          if fake.heldPolls != Int.max { fake.heldPolls -= 1 }
          return true
        },
        restoreClipboard: { true },
        clipboardHeld: {
          guard fake.clipboardHeldPolls > 0 else { return false }
          if fake.clipboardHeldPolls != Int.max { fake.clipboardHeldPolls -= 1 }
          return true
        },
        manualPaste: { text, restore in
          fake.pastes.append((text, restore))
          return fake.pasteResult
        },
        manualCopy: { text in
          fake.copies.append(text)
          return fake.copyResult
        },
        openPermissions: { fake.permissionsOpened += 1 },
        report: { action, source, outcome in fake.reports.append((action, source, outcome.rawValue))
        },
        sleep: { duration in
          fake.sleeps += 1
          fake.clock += duration + fake.lag
          fake.duringWait?()
          if fake.yieldOnSleep { await Task.yield() }
        },
        now: { fake.clock }))
  }

  private func outcomes(_ fake: Fake) -> [String] { fake.reports.map(\.2) }

  // MARK: Copy

  @Test("Copy needs no target and no Accessibility, and works with our own window in front")
  func copyNeedsNothingButARow() async {
    let fake = Fake()
    fake.axTrusted = false
    fake.frontmost = NSRunningApplication.current
    await makeAction(fake).copyFromChord().value
    #expect(fake.copies == ["Send the draft to Maya."])
    #expect(outcomes(fake) == ["copied"])
    #expect(fake.reports.first?.0 == .copy && fake.reports.first?.1 == .chord)
    #expect(fake.activated.isEmpty)
  }

  @Test("Copy refuses while a dictation is in flight, and with nothing to reuse")
  func copyRefusals() async {
    let fake = Fake()
    fake.dictationActive = true
    await makeAction(fake).copyFromChord().value
    fake.dictationActive = false
    fake.row = nil
    await makeAction(fake).copyFromChord().value
    #expect(fake.copies.isEmpty)
    #expect(outcomes(fake) == ["recording", "no_dictation"])
  }

  // MARK: Paste refusals before anything is written

  @Test("Paste into our own window, a quit app, or with no app sampled writes nothing")
  func pasteTargetRefusals() async throws {
    let (a, us) = try Self.twoOtherApps()
    let fake = Fake()
    fake.own = us
    let action = makeAction(fake)
    await action.pasteFromMenu(rowID: fake.row?.id, target: us)
    fake.terminated = [a.processIdentifier]
    await action.pasteFromMenu(rowID: fake.row?.id, target: a)
    await action.pasteFromMenu(rowID: fake.row?.id, target: nil)
    #expect(outcomes(fake) == ["own_window", "target_gone", "target_gone"])
    #expect(fake.pastes.isEmpty)
    #expect(fake.activated.isEmpty)
  }

  @Test("No reusable row, or a row deleted after the menu rendered, pastes nothing")
  func pasteRowRefusals() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    let rendered = fake.row?.id
    fake.deleted = true
    await makeAction(fake).pasteFromMenu(rowID: rendered, target: a)
    fake.row = nil  // imported-only History: nothing eligible at all
    await makeAction(fake).pasteFromMenu(rowID: nil, target: a)
    #expect(outcomes(fake) == ["no_dictation", "no_dictation"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("Recording in flight and missing Accessibility refuse; only the menu opens Permissions")
  func pasteRecordingAndAccessibility() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.dictationActive = true
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    fake.dictationActive = false
    fake.axTrusted = false
    let action = makeAction(fake)
    await action.pasteFromMenu(rowID: fake.row?.id, target: a)
    action.notePasteChordPressed()
    await action.pasteFromChord().value
    #expect(outcomes(fake) == ["recording", "ax_denied", "ax_denied"])
    #expect(fake.permissionsOpened == 1, "the chord has nowhere to show the fix")
    #expect(fake.pastes.isEmpty)
  }

  // MARK: The happy path, and the clipboard's answer

  @Test("A chord pressed in place pastes without activating anything")
  func pasteInPlace() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    let action = makeAction(fake)
    action.notePasteChordPressed()
    await action.pasteFromChord().value
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.pastes.map(\.text) == ["Send the draft to Maya."])
    #expect(fake.pastes.first?.restore == true, "the user's clipboard setting is passed through")
    #expect(fake.activated.isEmpty)
  }

  @Test("A busy clipboard and a Cmd+V that could not be posted are reported as such")
  func clipboardOutcomes() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.pasteResult = .clipboardBusy
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    fake.pasteResult = .dispatchFailed
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(outcomes(fake) == ["clipboard_busy", "dispatch_failed"])
  }

  // MARK: Press-time target

  @Test("The chord pastes into the app in front at PRESS time, not the one in front at release")
  func pressTimeTargetWins() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    let action = makeAction(fake)
    action.notePasteChordPressed()
    fake.frontmost = b  // focus moved between press and release
    await action.pasteFromChord().value
    #expect(fake.activated == [a.processIdentifier], "brought A back; never pasted into B")
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.pastes.count == 1)
  }

  @Test("If the press-time app cannot be brought back, nothing is written")
  func focusLostRefuses() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.activationSucceeds = false
    let action = makeAction(fake)
    action.notePasteChordPressed()
    fake.frontmost = b
    await action.pasteFromChord().value
    #expect(outcomes(fake) == ["focus_lost"])
    #expect(fake.pastes.isEmpty)
  }

  // MARK: Modifier release

  @Test("Paste waits for the modifiers to be observed up, then pastes")
  func waitsForModifierRelease() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = 3
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.sleeps == 3, "exactly as many polls as the keys stayed down")
    #expect(outcomes(fake) == ["dispatched"])
  }

  @Test("Modifiers still held at the deadline: no clipboard write at all")
  func modifiersNeverReleased() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = Int.max
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(outcomes(fake) == ["keys_held"])
    #expect(fake.pastes.isEmpty)
    #expect(
      fake.sleeps
        == Int(LastDictationAction.modifierReleaseDeadline / LastDictationAction.pollInterval))
  }

  @Test("The deadline is elapsed time, not a count of polls: slow polls give up sooner")
  func deadlineIsElapsedTime() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = Int.max
    fake.lag = .milliseconds(490)  // each 10 ms poll actually takes half a second
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.sleeps == 2, "one second of wall time, however few polls fit in it")
    #expect(outcomes(fake) == ["keys_held"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("A release first observed on a poll that resumed past the deadline is not accepted")
  func lateReleaseRefuses() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = 2  // held at the start and after the first poll; up on the second
    fake.lag = .milliseconds(490)  // and the second poll resumes one full second in
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.sleeps == 2)
    #expect(outcomes(fake) == ["keys_held"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("A wait cancelled as the keys come up reports cancelled and writes nothing")
  func cancelledWaitRefuses() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = 1  // released by the first poll, the same poll the task is cancelled in
    fake.duringWait = { withUnsafeCurrentTask { $0?.cancel() } }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.sleeps == 1)
    #expect(outcomes(fake) == ["cancelled"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("A task cancelled before the paste began writes nothing, even with the keys already up")
  func alreadyCancelledRefuses() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    let action = makeAction(fake)
    let rowID = fake.row?.id
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      await action.pasteFromMenu(rowID: rowID, target: a)
    }
    await task.value
    #expect(fake.sleeps == 0)
    #expect(outcomes(fake) == ["cancelled"])
    #expect(fake.pastes.isEmpty)
  }

  // MARK: Final review fixes (#3106)

  @Test("Two whole Paste gestures before either task runs: each keeps its own press-time target")
  func overlappingGesturesKeepTheirTargets() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    let action = makeAction(fake)
    action.notePasteChordPressed()
    let first = action.pasteFromChord()  // released in A; its task has not run yet
    fake.frontmost = b
    action.notePasteChordPressed()
    let second = action.pasteFromChord()  // then pressed and released in B
    await first.value
    await second.value
    #expect(fake.activated == [a.processIdentifier, b.processIdentifier], "A for the first, B for the second")
    #expect(outcomes(fake) == ["dispatched", "dispatched"])
  }

  @Test("Copy takes the row present at the press, whatever happens after")
  func copyUsesTheRowAtThePress() async {
    let fake = Fake()
    let pressed = fake.row?.text
    let action = makeAction(fake)
    let copying = action.copyFromChord()
    fake.row = (UUID(), "A newer dictation.")
    await copying.value
    #expect(fake.copies == [pressed].compactMap { $0 })
  }

  @Test("A modifier pressed during the activation wait stops the paste before any write")
  func modifierHeldDuringActivationRefuses() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b  // the target must be brought forward
    fake.duringActivation = { fake.heldPolls = Int.max }  // the user presses Control meanwhile
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.activated == [a.processIdentifier])
    #expect(outcomes(fake) == ["keys_held"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("A clipboard write that did not take is reported, for Paste and for Copy")
  func writeFailedIsReported() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.pasteResult = .writeFailed
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    fake.copyResult = .writeFailed
    await makeAction(fake).copyFromChord().value
    #expect(outcomes(fake) == ["write_failed", "write_failed"])
  }

  // MARK: The clipboard is still held by the last dictation (#3135)

  @Test("A paste pressed while the last dictation's cleanup holds the clipboard waits, then pastes")
  func pasteWaitsForTheClipboard() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b  // the target must be brought forward, so activation order is visible
    fake.clipboardHeldPolls = 30  // about 300 ms of a pending landing decision
    var activatedWhileHeld = false
    fake.duringActivation = { activatedWhileHeld = fake.clipboardHeldPolls > 0 }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.pastes.map(\.text) == ["Send the draft to Maya."])
    #expect(fake.clipboardHeldPolls == 0, "every held poll was consumed before the write")
    #expect(!activatedWhileHeld, "focus is moved only once the clipboard is free")
    #expect(fake.sleeps >= 30)
  }

  @Test("A hold that outlasts the bound refuses as clipboard_busy, without moving focus or writing")
  func pasteGivesUpAtTheBound() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b
    fake.clipboardHeldPolls = Int.max
    let started = fake.clock
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(outcomes(fake) == ["clipboard_busy"])
    #expect(fake.pastes.isEmpty && fake.activated.isEmpty)
    // Measured on the monotonic clock: the bound, not a count of sleeps.
    #expect(fake.clock - started >= ClipboardCleanup.manualWriteWaitBound)
    #expect(ClipboardCleanup.manualWriteWaitBound == .milliseconds(3500))
  }

  @Test("A free clipboard adds no wait")
  func freeClipboardAddsNoWait() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.sleeps == 0)
  }

  @Test("Copy waits for the clipboard too, and a recording that starts meanwhile stops it")
  func copyWaitsForTheClipboard() async {
    let fake = Fake()
    fake.clipboardHeldPolls = 20
    await makeAction(fake).copyFromChord().value
    #expect(outcomes(fake) == ["copied"])
    #expect(fake.copies == ["Send the draft to Maya."])

    fake.clipboardHeldPolls = 20
    fake.duringWait = { fake.dictationActive = true }
    await makeAction(fake).copyFromChord().value
    #expect(outcomes(fake).last == "recording")
    #expect(fake.copies.count == 1, "no second write")
  }

  @Test("A newer Copy pressed WHILE an older one waits cancels it, so the older cannot overwrite it")
  func newerCopyWins() async {
    let fake = Fake()
    fake.clipboardHeldPolls = 20
    let action = makeAction(fake)
    var newer: Task<Void, Never>?
    // Pressed during the older copy's first sleep, so the older is already inside its wait.
    fake.duringWait = {
      guard newer == nil else { return }
      fake.row = (UUID(), "A newer dictation.")
      newer = action.copyFromChord()
    }
    await action.copyFromChord().value
    await newer?.value
    #expect(newer != nil)
    #expect(fake.copies == ["A newer dictation."], "only the latest press writes")
    #expect(outcomes(fake).sorted() == ["cancelled", "copied"])
  }

  @Test("A Paste Last that writes cancels an older Copy still waiting")
  func pasteCancelsWaitingCopy() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.clipboardHeldPolls = Int.max
    fake.yieldOnSleep = true
    let action = makeAction(fake)
    let copying = action.copyFromChord()  // waits: the clipboard stays held
    while fake.sleeps == 0 { await Task.yield() }  // the copy is inside its wait
    fake.clipboardHeldPolls = 0  // released; the paste goes straight through
    await action.pasteFromMenu(rowID: fake.row?.id, target: a)
    await copying.value
    #expect(fake.pastes.count == 1)
    #expect(fake.copies.isEmpty, "the older copy did not wake and overwrite the pasted text")
    #expect(outcomes(fake).sorted() == ["cancelled", "dispatched"])
  }

  @Test("Copy refuses on a recording in flight at the press even if it ends before the task runs")
  func copyRecordingAtThePress() async {
    let fake = Fake()
    fake.dictationActive = true
    let copying = makeAction(fake).copyFromChord()
    fake.dictationActive = false
    await copying.value
    #expect(outcomes(fake) == ["recording"])
    #expect(fake.copies.isEmpty)
  }

  // MARK: Re-checks after the awaits

  @Test("With nothing to paste, that is the answer even when Accessibility is also missing")
  func noDictationBeforeAccessibility() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.row = nil
    fake.axTrusted = false
    let action = makeAction(fake)
    action.notePasteChordPressed()
    await action.pasteFromChord().value
    #expect(outcomes(fake) == ["no_dictation"])
    #expect(fake.permissionsOpened == 0)
  }

  @Test("Without Accessibility, a quit target or our own window says so and opens nothing")
  func targetRefusalsBeforeAccessibility() async throws {
    let (a, us) = try Self.twoOtherApps()
    let fake = Fake()
    fake.own = us
    fake.frontmost = a
    fake.axTrusted = false
    fake.terminated = [a.processIdentifier]
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    fake.terminated = []
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: us)
    #expect(outcomes(fake) == ["target_gone", "own_window"])
    #expect(fake.permissionsOpened == 0, "granting Accessibility would not make either pasteable")
    #expect(fake.pastes.isEmpty)
  }

  @Test("What changes during the modifier wait is checked BEFORE focus is moved")
  func recheckBeforeActivation() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b  // the target is not in front, so a paste would activate it
    fake.heldPolls = 1
    fake.duringWait = { fake.dictationActive = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)

    fake.dictationActive = false
    fake.heldPolls = 1
    fake.duringWait = { fake.terminated = [a.processIdentifier] }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)

    fake.terminated = []
    fake.heldPolls = 1
    fake.duringWait = { fake.axTrusted = false }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)

    #expect(outcomes(fake) == ["recording", "target_gone", "ax_denied"])
    #expect(fake.permissionsOpened == 1, "revoked during a MENU wait: sent to the fix, as at the start")
    #expect(fake.activated.isEmpty, "no app was brought forward for a paste that will not happen")
    #expect(fake.pastes.isEmpty)
  }

  @Test("And checked again after the activation, the last await before the write")
  func recheckAfterActivation() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b
    fake.duringActivation = { fake.dictationActive = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)
    #expect(fake.activated == [a.processIdentifier])
    #expect(outcomes(fake) == ["recording"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("A recording that starts, or a row deleted, during the wait stops the paste")
  func rechecksAfterAwaits() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = 1
    fake.duringWait = { fake.dictationActive = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)

    fake.dictationActive = false
    fake.heldPolls = 1
    fake.duringWait = { fake.deleted = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a)

    #expect(outcomes(fake) == ["recording", "no_dictation"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("The pasted text is read after the waits, never taken from before them")
  func textIsReadFresh() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = 1
    let id = try #require(fake.row?.id)
    fake.duringWait = { fake.row = (id, "Edited after the menu opened.") }
    await makeAction(fake).pasteFromMenu(rowID: id, target: a)
    #expect(fake.pastes.map(\.text) == ["Edited after the menu opened."])
  }
}
