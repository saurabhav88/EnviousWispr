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
    /// Resumed by the first sleep, so a test can await "an action is now inside its wait" instead
    /// of guessing with a number of yields.
    var sleepEntered: CheckedContinuation<Void, Never>?
    /// Set when a Paste first reads the modifiers, its first step after its press. Lets a test
    /// hold the clipboard exactly until a newer Paste has started, whatever order the tasks run in.
    var pasteStarted = false
    /// Replaces the `clipboardHeldPolls` countdown when set.
    var clipboardHeldOverride: (() -> Bool)?
    /// Every wait a reuse reported for a held clipboard.
    var clipboardWaits: [Duration] = []
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
    /// The "keep dictations out of clipboard history apps" value (#3672) the paste is asked to use,
    /// and the value each paste was handed.
    var markTransient = false
    var pasteMarks: [Bool] = []
    var copies: [String] = []
    var permissionsOpened = 0
    var reports: [(LastDictationAction.Action, LastDictationAction.Source, String)] = []
    /// Each report's route (#3437), nil for Copy.
    var routes: [LastDictationAction.Route?] = []
    /// The keyboard owner each read returns, in order (#3437); the last answer repeats. Empty
    /// means "unreadable" on every read.
    var ownerReads: [LastDictationAction.KeyboardOwnerSnapshot?] = []
    var ownerReadCount = 0
    /// Runs on each owner read, so a test can change the world during the final confirmation.
    var duringOwnerRead: (() -> Void)?
    /// Pastes posted at a process (#3437): text, restore, transient marker and the pid.
    var processPastes: [(text: String, restore: Bool, mark: Bool, pid: pid_t)] = []
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
        keyboardOwner: {
          fake.ownerReadCount += 1
          fake.duringOwnerRead?()
          guard !fake.ownerReads.isEmpty else { return nil }
          return fake.ownerReads.count > 1 ? fake.ownerReads.removeFirst() : fake.ownerReads[0]
        },
        isTerminated: { fake.terminated.contains($0.processIdentifier) },
        isOwnApplication: { app in fake.own.map { $0 === app } ?? false },
        activate: { app in
          fake.activated.append(app.processIdentifier)
          fake.duringActivation?()
          if fake.activationSucceeds { fake.frontmost = app }
          return fake.activationSucceeds
        },
        modifiersHeld: {
          fake.pasteStarted = true
          guard fake.heldPolls > 0 else { return false }
          if fake.heldPolls != Int.max { fake.heldPolls -= 1 }
          return true
        },
        restoreClipboard: { true },
        markTransient: { fake.markTransient },
        clipboardHeld: {
          if let override = fake.clipboardHeldOverride { return override() }
          guard fake.clipboardHeldPolls > 0 else { return false }
          if fake.clipboardHeldPolls != Int.max { fake.clipboardHeldPolls -= 1 }
          return true
        },
        clipboardWaited: { fake.clipboardWaits.append($0) },
        manualPaste: { text, restore, markTransient in
          fake.pastes.append((text, restore))
          fake.pasteMarks.append(markTransient)
          return fake.pasteResult
        },
        manualPasteAtProcess: { text, restore, markTransient, pid in
          fake.processPastes.append((text, restore, markTransient, pid))
          return fake.pasteResult
        },
        manualCopy: { text in
          fake.copies.append(text)
          return fake.copyResult
        },
        openPermissions: { fake.permissionsOpened += 1 },
        report: { action, source, outcome, route in
          fake.reports.append((action, source, outcome.rawValue))
          fake.routes.append(route)
        },
        sleep: { duration in
          fake.sleeps += 1
          fake.clock += duration + fake.lag
          fake.duringWait?()
          if let entered = fake.sleepEntered {
            fake.sleepEntered = nil
            entered.resume()
          }
          if fake.yieldOnSleep { await Task.yield() }
        },
        now: { fake.clock }))
  }

  private func outcomes(_ fake: Fake) -> [String] { fake.reports.map(\.2) }

  /// Returns once some action has entered a wait (its first sleep). The suites run these under a
  /// time limit, so an action that never sleeps fails the test rather than hanging it.
  private func actionEnteredWait(_ fake: Fake) async {
    if fake.sleeps > 0 { return }
    await withCheckedContinuation { fake.sleepEntered = $0 }
  }

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
    await action.pasteFromMenu(rowID: fake.row?.id, target: us).value
    fake.terminated = [a.processIdentifier]
    await action.pasteFromMenu(rowID: fake.row?.id, target: a).value
    await action.pasteFromMenu(rowID: fake.row?.id, target: nil).value
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
    await makeAction(fake).pasteFromMenu(rowID: rendered, target: a).value
    fake.row = nil  // imported-only History: nothing eligible at all
    await makeAction(fake).pasteFromMenu(rowID: nil, target: a).value
    #expect(outcomes(fake) == ["no_dictation", "no_dictation"])
    #expect(fake.pastes.isEmpty)
  }

  @Test("Recording in flight and missing Accessibility refuse; only the menu opens Permissions")
  func pasteRecordingAndAccessibility() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.dictationActive = true
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    fake.dictationActive = false
    fake.axTrusted = false
    let action = makeAction(fake)
    await action.pasteFromMenu(rowID: fake.row?.id, target: a).value
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

  @Test("The clipboard-history setting is read at the press and passed to the paste (#3672)")
  func pasteForwardsTheClipboardHistorySetting() async throws {
    for setting in [false, true] {
      let (a, _) = try Self.twoOtherApps()
      let fake = Fake()
      fake.frontmost = a
      fake.markTransient = setting
      let action = makeAction(fake)
      action.notePasteChordPressed()
      await action.pasteFromChord().value
      #expect(fake.pasteMarks == [setting])
    }
  }

  @Test("A busy clipboard and a Cmd+V that could not be posted are reported as such")
  func clipboardOutcomes() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.pasteResult = .clipboardBusy
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    fake.pasteResult = .dispatchFailed
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    #expect(fake.sleeps == 3, "exactly as many polls as the keys stayed down")
    #expect(outcomes(fake) == ["dispatched"])
  }

  @Test("Modifiers still held at the deadline: no clipboard write at all")
  func modifiersNeverReleased() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.heldPolls = Int.max
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    // Cancelled before it first runs: the menu entry returns its task synchronously (#3135).
    let task = action.pasteFromMenu(rowID: rowID, target: a)
    task.cancel()
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
    #expect(
      fake.activated == [a.processIdentifier, b.processIdentifier],
      "A for the first, B for the second")
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.pastes.map(\.text) == ["Send the draft to Maya."])
    #expect(fake.clipboardHeldPolls == 0, "every held poll was consumed before the write")
    #expect(!activatedWhileHeld, "focus is moved only once the clipboard is free")
    #expect(fake.clipboardWaits.count == 1, "the wait on a held board is reported once")
    #expect(fake.sleeps == 29, "30 held reads: the entry check, then one per sleep until free")
  }

  @Test("A hold that outlasts the bound refuses as clipboard_busy, without moving focus or writing")
  func pasteGivesUpAtTheBound() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b
    fake.clipboardHeldPolls = Int.max
    let started = fake.clock
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.sleeps == 0)
    #expect(fake.clipboardWaits.isEmpty, "a free board reports no wait")
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

  @Test(
    "A newer Copy pressed WHILE an older one waits cancels it, so the older cannot overwrite it")
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

  @Test("A newer Copy cancels an older one that has not started, even with the clipboard free")
  func newerCopyWinsOnAFreeBoard() async {
    let fake = Fake()
    let action = makeAction(fake)
    let older = action.copyFromChord()  // not yet run
    fake.row = (UUID(), "A newer dictation.")
    let newer = action.copyFromChord()
    await older.value
    await newer.value
    #expect(fake.copies == ["A newer dictation."], "the cancelled copy did not write")
    #expect(outcomes(fake).sorted() == ["cancelled", "copied"])
  }

  @Test("A Paste Last that writes cancels an older Copy still waiting", .timeLimit(.minutes(1)))
  func pasteCancelsWaitingCopy() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.yieldOnSleep = true
    // Held until the newer Paste has started, then free: the Paste goes straight through while the
    // Copy is still asleep in its wait, whichever task the main actor runs first.
    fake.clipboardHeldOverride = { !fake.pasteStarted }
    let action = makeAction(fake)
    let copying = action.copyFromChord()
    await actionEnteredWait(fake)  // the copy is inside its clipboard wait
    await action.pasteFromMenu(rowID: fake.row?.id, target: a).value
    await copying.value
    #expect(fake.pastes.count == 1)
    #expect(fake.copies.isEmpty, "the older copy did not wake and overwrite the pasted text")
    #expect(outcomes(fake).sorted() == ["cancelled", "dispatched"])
  }

  @Test(
    "A newer Copy supersedes an older Paste still waiting, so the paste cannot replace it",
    .timeLimit(.minutes(1)))
  func copySupersedesWaitingPaste() async throws {
    let (a, _) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = a
    fake.clipboardHeldPolls = Int.max
    fake.yieldOnSleep = true
    let action = makeAction(fake)
    action.notePasteChordPressed()
    let pasting = action.pasteFromChord()  // waits: the clipboard stays held
    await actionEnteredWait(fake)  // the paste is inside its clipboard wait
    fake.row = (UUID(), "A newer dictation.")
    fake.clipboardHeldPolls = 0
    await action.copyFromChord().value  // the newer action: copies B
    await pasting.value
    #expect(fake.copies == ["A newer dictation."])
    #expect(fake.pastes.isEmpty, "the older paste did not wake and replace the copy")
    #expect(outcomes(fake).sorted() == ["cancelled", "copied"])
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
    fake.terminated = []
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: us).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value

    fake.dictationActive = false
    fake.heldPolls = 1
    fake.duringWait = { fake.terminated = [a.processIdentifier] }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value

    fake.terminated = []
    fake.heldPolls = 1
    fake.duringWait = { fake.axTrusted = false }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value

    #expect(outcomes(fake) == ["recording", "target_gone", "ax_denied"])
    #expect(
      fake.permissionsOpened == 1, "revoked during a MENU wait: sent to the fix, as at the start")
    #expect(fake.activated.isEmpty, "no app was brought forward for a paste that will not happen")
    #expect(fake.pastes.isEmpty)
  }

  @Test("And checked again after the activation, the last await before the write")
  func recheckAfterActivation() async throws {
    let (a, b) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = b
    fake.duringActivation = { fake.dictationActive = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value
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
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value

    fake.dictationActive = false
    fake.heldPolls = 1
    fake.duringWait = { fake.deleted = true }
    await makeAction(fake).pasteFromMenu(rowID: fake.row?.id, target: a).value

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
    await makeAction(fake).pasteFromMenu(rowID: id, target: a).value
    #expect(fake.pastes.map(\.text) == ["Edited after the menu opened."])
  }

  // MARK: A keyboard owner that is not front (#3437)

  /// A snapshot of `app` holding the keyboard with a given element; the element is a real AX
  /// object used only for identity.
  private static func owner(
    _ app: NSRunningApplication, element: AXUIElement? = nil
  ) -> LastDictationAction.KeyboardOwnerSnapshot {
    .init(
      application: app, element: element ?? AXUIElementCreateApplication(app.processIdentifier))
  }

  @Test("a chord with a launcher panel holding the keyboard pastes at the panel, never activating")
  func ownerRoutePastesAtTheOwner() async throws {
    let (front, panel) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = front
    let snapshot = Self.owner(panel)
    fake.ownerReads = [snapshot]
    fake.markTransient = true
    let action = makeAction(fake)
    action.notePasteChordPressed()
    await action.pasteFromChord().value
    #expect(outcomes(fake) == ["dispatched"])
    #expect(fake.routes == [.owner])
    #expect(fake.processPastes.count == 1)
    #expect(fake.processPastes.first?.pid == panel.processIdentifier)
    #expect(fake.processPastes.first?.text == "Send the draft to Maya.")
    #expect(fake.processPastes.first?.restore == true)
    #expect(fake.processPastes.first?.mark == true)
    #expect(fake.pastes.isEmpty, "nothing posted at the front app")
    #expect(fake.activated.isEmpty, "the panel is never activated")
    #expect(fake.ownerReadCount == 2, "one read at the press, one confirmation before the write")
  }

  @Test("the owner route refuses when the panel's focused field or owner changed, with no fallback")
  func ownerRouteRefusesAChangedField() async throws {
    let (front, panel) = try Self.twoOtherApps()
    for confirmation: LastDictationAction.KeyboardOwnerSnapshot? in [
      Self.owner(panel, element: AXUIElementCreateSystemWide()),  // same process, other field
      Self.owner(front),  // another process
      nil,  // unreadable
    ] {
      let fake = Fake()
      fake.frontmost = front
      fake.ownerReads = [Self.owner(panel), confirmation]
      let action = makeAction(fake)
      action.notePasteChordPressed()
      await action.pasteFromChord().value
      #expect(outcomes(fake) == ["focus_lost"])
      #expect(fake.processPastes.isEmpty && fake.pastes.isEmpty)
      #expect(fake.activated.isEmpty)
    }
  }

  @Test("an owner that quits or Accessibility revoked during the confirmation reports that")
  func ownerRouteKeepsRefusalPrecedence() async throws {
    let (front, panel) = try Self.twoOtherApps()
    let quit = Fake()
    quit.frontmost = front
    quit.ownerReads = [Self.owner(panel), nil]
    let quitAction = makeAction(quit)
    quitAction.notePasteChordPressed()
    quit.duringOwnerRead = { quit.terminated = [panel.processIdentifier] }
    await quitAction.pasteFromChord().value
    #expect(outcomes(quit) == ["target_gone"])

    let revoked = Fake()
    revoked.frontmost = front
    revoked.ownerReads = [Self.owner(panel), nil]
    let revokedAction = makeAction(revoked)
    revokedAction.notePasteChordPressed()
    revoked.duringOwnerRead = { revoked.axTrusted = false }
    await revokedAction.pasteFromChord().value
    #expect(outcomes(revoked) == ["ax_denied"])
    #expect(quit.processPastes.isEmpty && revoked.processPastes.isEmpty)
  }

  @Test("an owner that is the front app, our own window or unreadable keeps the front route")
  func frontRouteWhenTheOwnerIsNotAnotherApp() async throws {
    let (front, us) = try Self.twoOtherApps()
    for reads: [LastDictationAction.KeyboardOwnerSnapshot?] in [
      [Self.owner(front)], [Self.owner(us)], [],
    ] {
      let fake = Fake()
      fake.frontmost = front
      fake.own = us
      fake.ownerReads = reads
      let action = makeAction(fake)
      action.notePasteChordPressed()
      await action.pasteFromChord().value
      #expect(outcomes(fake) == ["dispatched"])
      #expect(fake.routes == [.front])
      #expect(fake.pastes.count == 1 && fake.processPastes.isEmpty)
      #expect(fake.ownerReadCount == 1, "no confirmation read on the front route")
    }
  }

  @Test("the menu and Copy never read the keyboard owner")
  func menuAndCopyDoNotReadTheOwner() async throws {
    let (front, panel) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = front
    fake.ownerReads = [Self.owner(panel)]
    let action = makeAction(fake)
    await action.pasteFromMenu(rowID: fake.row?.id, target: front).value
    await action.copyFromChord().value
    #expect(fake.ownerReadCount == 0)
    #expect(fake.routes == [.front, nil])
    #expect(fake.processPastes.isEmpty)
  }

  @Test("each chord keeps the target it pressed on")
  func overlappingChordsKeepTheirOwnTargets() async throws {
    let (front, panel) = try Self.twoOtherApps()
    let fake = Fake()
    fake.frontmost = front
    // Reads in order: first press (the panel), second press (the front app: front route, no
    // confirmation), then the first paste's confirmation (the panel again).
    fake.ownerReads = [Self.owner(panel), Self.owner(front), Self.owner(panel)]
    let action = makeAction(fake)
    action.notePasteChordPressed()
    let first = action.pasteFromChord()
    action.notePasteChordPressed()
    let second = action.pasteFromChord()
    await first.value
    await second.value
    #expect(Set(fake.routes.compactMap { $0 }) == [.owner, .front])
    #expect(fake.processPastes.count == 1 && fake.pastes.count == 1)
  }
}
