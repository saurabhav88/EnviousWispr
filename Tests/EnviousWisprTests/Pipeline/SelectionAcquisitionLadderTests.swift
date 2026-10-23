import AppKit
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// The copy fallback's whole ladder, entered at the real door (#3986).
///
/// When these fail, Quick Add posts a Copy at an app that is not in front, under the user's held
/// keys, at a stranger that inherited the pid, or into a password field; or it loses the shortcut
/// wait's reading on a later refusal.
///
/// Every reading is injected (clock, keys, frontmost app, secure input, posting grant, target
/// identity, the copy key) and the chord is a counting fake that writes an isolated board. Every
/// guard still runs on those readings, in production order: nothing here supplies a refusal.
/// The real AX and window-server behaviour is Live UAT's job.
@MainActor
@Suite(
  "Quick Add copy ladder, entered at the door, every guard in order (#3986)",
  .tags(.productOutcome), .serialized, .clipboardCleanupExclusive)
struct SelectionAcquisitionLadderTests {

  static let target: pid_t = 501
  static let stranger: pid_t = 999

  /// Readings replayed in call order; the last value repeats.
  @MainActor final class Replay<Value> {
    private var values: [Value]
    private(set) var reads = 0
    init(_ values: [Value]) { self.values = values }
    func next() -> Value {
      defer { reads += 1 }
      return values[min(reads, values.count - 1)]
    }
  }

  @MainActor final class Rig {
    let origin = ContinuousClock.now
    var elapsed: Duration = .zero
    var modifiers = Replay([false])
    var secureInput = Replay([false])
    var focusProbe: SelectionReader.SubroleOutcome = .subrole(nil)
    /// Cancel the running task from inside the first modifier reading (keys reported up), so the
    /// wait clears and cancellation is first seen after it.
    var cancelOnFirstModifierRead = false
    /// Cancel the running task from inside the first frontmost reading after activation.
    var cancelDuringActivationWait = false
    /// From inside the fake Copy: let a dictation claim the board and write its own payload.
    var deliveryClaimsDuringCopy = false
    /// The no-focus recovery's fresh reads, replayed in order; nil is "the frontmost app is not the
    /// sampled one" (the live reader answers nil before any AX operation).
    typealias Read = (result: SelectionReader.Result, context: SelectionReader.AcquisitionContext)
    var rereads = Replay<Read?>([nil])
    var rereadCount = 0
    var rereadTimeouts: [Float] = []
    /// How far each fresh read moves the clock (a slow provider).
    var readTakes: Duration = .zero
    /// Cancel the running task from inside the first fresh read.
    var cancelDuringRead = false
    var postingAuthorised = true
    var targetPresent = Replay([true])
    var copyKey: CGKeyCode? = 8
    /// The key the layout reports once the target has been activated (a layout switch meanwhile).
    var copyKeyAfterActivation: CGKeyCode?
    /// Frontmost before any activation; `frontAfterActivation` takes over once `activate` runs.
    var front = Replay<pid_t?>([SelectionAcquisitionLadderTests.target])
    var frontAfterActivation: (@MainActor (Duration) -> pid_t?)?
    var activatedAt: Duration?
    var activations: [pid_t] = []
    var postedPIDs: [pid_t] = []
    var postedKeys: [CGKeyCode] = []
    var posts: Int { postedPIDs.count }
    var postResult: SyntheticCopyChord.PostResult = .posted
    /// What the fake Copy puts on the board; nil writes nothing (an app that did not answer).
    var copiedText: String? = "keybinds"
    let board = NSPasteboard(name: NSPasteboard.Name("ew-test-ladder-\(UUID().uuidString)"))

    var environment: SelectionAcquisition.Environment {
      SelectionAcquisition.Environment(
        now: { self.origin + self.elapsed },
        // settle: not a wait; the fake advances the manual clock and returns at once
        sleep: { self.elapsed += $0 },
        modifiersHeld: {
          if self.cancelOnFirstModifierRead, self.modifiers.reads == 0 {
            withUnsafeCurrentTask { $0?.cancel() }
          }
          return self.modifiers.next()
        },
        secureInputActive: { self.secureInput.next() },
        secureFocusProbe: { _ in self.focusProbe },
        postingAuthorised: { self.postingAuthorised },
        targetStillPresent: { _ in self.targetPresent.next() },
        copyKeyCode: {
          if self.activatedAt != nil, let later = self.copyKeyAfterActivation { return later }
          return self.copyKey
        },
        frontmostPID: {
          if let activatedAt = self.activatedAt, let after = self.frontAfterActivation {
            if self.cancelDuringActivationWait { withUnsafeCurrentTask { $0?.cancel() } }
            return after(self.elapsed - activatedAt)
          }
          return self.front.next()
        },
        activate: { pid in
          self.activations.append(pid)
          self.activatedAt = self.elapsed
        },
        postCopy: { pid, key in
          self.postedPIDs.append(pid)
          self.postedKeys.append(key)
          if self.deliveryClaimsDuringCopy {
            ClipboardCleanup.deliveryClaimsBoard()
            self.board.clearContents()
            self.board.setString("DICTATION PAYLOAD", forType: .string)
            return self.postResult
          }
          if let text = self.copiedText {
            self.board.clearContents()
            self.board.setString(text, forType: .string)
          }
          return self.postResult
        },
        readSelection: { _, timeout, _ in
          self.rereadCount += 1
          self.rereadTimeouts.append(timeout)
          self.elapsed += self.readTakes
          if self.cancelDuringRead { withUnsafeCurrentTask { $0?.cancel() } }
          return self.rereads.next()
        })
    }

    init() {
      board.clearContents()
      board.setString("USER CLIPBOARD", forType: .string)
    }
  }

  /// The outcome, and whether a takeover was still held when the ladder returned, read BEFORE the
  /// teardown reset so the cleanup assertion observes production, not the fixture.
  private func run(
    _ rig: Rig, first: SelectionReader.Result = .noSelection
  ) async -> (SelectionAcquisition.Outcome, heldAfter: Bool) {
    ClipboardCleanup.resetPendingForTests()
    defer { ClipboardCleanup.resetPendingForTests() }
    let outcome = await SelectionAcquisition.acquire(
      following: first,
      context: .init(
        pid: Self.target, bundleIdentifier: "com.example.target", focusedSubrole: nil),
      fallbackEnabled: true, environment: rig.environment, board: rig.board)
    return (outcome, ClipboardCleanup.hasPending)
  }

  private func refusal(_ outcome: SelectionAcquisition.Outcome) -> SelectionReader.Refusal? {
    if case .refused(let why) = outcome.result { return why }
    return nil
  }

  private func boardUntouched(_ rig: Rig, from count: Int) -> Bool {
    rig.board.changeCount == count && rig.board.string(forType: .string) == "USER CLIPBOARD"
  }

  // MARK: Positive controls

  @Test("Target already in front: one Copy, no activation, the word read, the clipboard restored")
  func alreadyFrontCopiesOnce() async {
    let rig = Rig()
    let (outcome, heldAfter) = await run(rig)
    #expect(outcome.result == .text("keybinds"))
    #expect(outcome.acquired == .clipboardCopy)
    #expect(outcome.clipboardRestore == .restored)
    #expect(rig.postedPIDs == [Self.target])
    #expect(rig.postedKeys == [8])
    #expect(rig.activations.isEmpty)
    #expect(heldAfter == false)
    #expect(rig.board.string(forType: .string) == "USER CLIPBOARD")
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("Target behind another app and front 30 ms after activation: brought back, then one Copy")
  func broughtBackThenCopies() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.frontAfterActivation = { since in since >= .milliseconds(30) ? Self.target : Self.stranger }
    let (outcome, _) = await run(rig)
    #expect(rig.activations == [Self.target])
    #expect(
      rig.postedPIDs == [Self.target], "the chord goes to the sampled app, not the one in front")
    #expect(rig.postedKeys == [8])
    #expect(outcome.result == .text("keybinds"))
    #expect(outcome.bringBack == .front)
    #expect(outcome.modifierReleaseMs == 0)
  }

  // MARK: Bring-back refusals (STEP 2a)

  @Test("Target never comes to the front: copy refused, nothing posted, clipboard untouched")
  func neverFrontRefuses() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.frontAfterActivation = { _ in Self.stranger }
    let before = rig.board.changeCount
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 0)
    #expect(rig.activations == [Self.target])
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.clipboardRestore == .notTouched)
    #expect(outcome.bringBack == .timedOut)
    #expect(outcome.modifierReleaseMs == 0)
  }

  @Test("Target gone before activation: refused, no activation, nothing posted")
  func goneBeforeActivationRefuses() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    // Step 1 sees it present; the re-check before activating does not.
    rig.targetPresent = Replay([true, false])
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .targetApplicationGone)
    #expect(rig.activations.isEmpty)
    #expect(rig.posts == 0)
    #expect(outcome.bringBack == .targetGone)
  }

  @Test("Target gone while waiting to come front: refused as gone, nothing posted")
  func goneDuringActivationRefuses() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.frontAfterActivation = { _ in Self.stranger }
    rig.targetPresent = Replay([true, true, false])
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .targetApplicationGone)
    #expect(rig.posts == 0)
    #expect(outcome.bringBack == .targetGone)
  }

  @Test("A cancelled acquisition activates nothing and posts nothing")
  func cancelledDoesNothing() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    let task = Task { @MainActor in await self.run(rig) }
    task.cancel()
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .modifiersHeld)
    #expect(rig.activations.isEmpty)
    #expect(rig.posts == 0)
    #expect(outcome.modifierReleaseMs == nil)
    #expect(outcome.bringBack == nil)
  }

  // MARK: The last check before the chord (STEP 3c)

  @Test("Keys clear for the wait, then held at the last check: refused as held, nothing posted")
  func heldAtDispatchRefuses() async {
    let rig = Rig()
    rig.modifiers = Replay([false, true])
    let before = rig.board.changeCount
    let (outcome, heldAfter) = await run(rig)
    #expect(refusal(outcome) == .modifiersHeld)
    #expect(rig.posts == 0)
    #expect(heldAfter == false, "the takeover must have ended")
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.clipboardRestore == .notTouched)
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("Target in front at the bring-back step, gone from the front at the last check: refused")
  func lostFrontAtDispatchRefuses() async {
    let rig = Rig()
    rig.front = Replay([Self.target, Self.stranger])
    let before = rig.board.changeCount
    let (outcome, heldAfter) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 0)
    #expect(heldAfter == false, "the takeover must have ended")
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.bringBack == .notNeeded)
  }

  // MARK: Earlier guards refuse before posting (negative controls)

  @Test(
    "A password field in focus, or a focus nobody can read, refuses before anything is posted",
    arguments: [false, true])
  func secureOrUnreadableFocusRefuses(unreadable: Bool) async {
    let rig = Rig()
    rig.focusProbe = unreadable ? .unreadable : .subrole(kAXSecureTextFieldSubrole as String)
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .secureInputActive)
    #expect(rig.posts == 0)
    #expect(outcome.modifierReleaseMs == nil)
    #expect(outcome.bringBack == nil)
  }

  // MARK: Cancellation after the wait never reaches the activation or the chord

  @Test("Cancelled after the keys came up, target in front: refused, nothing posted")
  func cancelledAfterWaitInFront() async {
    let rig = Rig()
    rig.cancelOnFirstModifierRead = true
    let before = rig.board.changeCount
    let task = Task { @MainActor in await self.run(rig) }
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 0)
    #expect(rig.activations.isEmpty)
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == nil, "a cancellation is not a timeout")
  }

  @Test("Cancelled after the keys came up, target behind: no activation, nothing posted")
  func cancelledBeforeActivation() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.cancelOnFirstModifierRead = true
    let task = Task { @MainActor in await self.run(rig) }
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.activations.isEmpty)
    #expect(rig.posts == 0)
  }

  @Test("Cancelled during the wait for the target to come front: refused, nothing posted")
  func cancelledDuringActivationWait() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.frontAfterActivation = { _ in Self.stranger }
    rig.cancelDuringActivationWait = true
    let before = rig.board.changeCount
    let task = Task { @MainActor in await self.run(rig) }
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.activations == [Self.target])
    #expect(rig.posts == 0)
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.bringBack == nil, "a cancellation is not a timeout")
  }

  // MARK: A dictation claims the clipboard during the copy

  @Test("A dictation claims the board mid-copy: its payload survives and nothing is restored")
  func supersededByDelivery() async {
    let rig = Rig()
    rig.deliveryClaimsDuringCopy = true
    let (outcome, heldAfter) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(outcome.clipboardRestore == .supersededByDelivery)
    #expect(rig.board.string(forType: .string) == "DICTATION PAYLOAD")
    #expect(heldAfter == false)
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("No event-posting grant refuses before anything is posted")
  func postingDeniedRefuses() async {
    let rig = Rig()
    rig.postingAuthorised = false
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .eventPostingNotTrusted)
    #expect(rig.posts == 0)
  }

  @Test("A target already gone at the first check refuses before the wait")
  func missingTargetRefuses() async {
    let rig = Rig()
    rig.targetPresent = Replay([false])
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .targetApplicationGone)
    #expect(rig.posts == 0)
    #expect(outcome.modifierReleaseMs == nil)
  }

  @Test("A layout with no copy key refuses at the last check, after the takeover, posting nothing")
  func noCopyKeyRefuses() async {
    let rig = Rig()
    rig.copyKey = nil
    let before = rig.board.changeCount
    let (outcome, heldAfter) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 0)
    #expect(heldAfter == false)
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("The copy key is read right before the chord, so a layout switch meanwhile is honoured")
  func copyKeyIsReadLate() async {
    let rig = Rig()
    rig.front = Replay([Self.stranger])
    rig.frontAfterActivation = { _ in Self.target }
    rig.copyKeyAfterActivation = 9
    let (outcome, _) = await run(rig)
    #expect(rig.postedKeys == [9], "the key resolved under the old layout must not be pressed")
    #expect(rig.postedPIDs == [Self.target])
    #expect(outcome.bringBack == .front)
  }

  // MARK: The shortcut-key reading survives every later exit

  @Test("Keys held through the cap: refused as held, no reading, no bring-back")
  func heldThroughCap() async {
    let rig = Rig()
    rig.modifiers = Replay([true])
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .modifiersHeld)
    #expect(outcome.modifierReleaseMs == nil)
    #expect(outcome.bringBack == nil)
    #expect(rig.posts == 0)
  }

  @Test("Keys up at 400 ms, then a password field at the re-check: the 400 ms reading is kept")
  func laterPolicyRefusalKeepsTheReading() async {
    let rig = Rig()
    rig.modifiers = Replay([true] + Array(repeating: true, count: 49) + [false])
    rig.secureInput = Replay([false, true])
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .secureInputActive)
    #expect(outcome.modifierReleaseMs == 400)
    #expect(outcome.bringBack == .notNeeded)
    #expect(rig.posts == 0)
  }

  @Test("The app never answers the Copy: refused, clipboard untouched, both readings kept")
  func unchangedBoardKeepsReadings() async {
    let rig = Rig()
    rig.copiedText = nil
    let before = rig.board.changeCount
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 1)
    #expect(outcome.clipboardRestore == .notTouched)
    #expect(boardUntouched(rig, from: before))
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("The chord could not be built: refused, both readings kept")
  func notPostedKeepsReadings() async {
    let rig = Rig()
    rig.postResult = .notPosted
    rig.copiedText = nil
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(outcome.modifierReleaseMs == 0)
    #expect(outcome.bringBack == .notNeeded)
  }

  // MARK: No-focus recovery (#3986): Electron hides its focus while a status-item menu is open

  private static let sampled = SelectionReader.AcquisitionContext(
    pid: target, bundleIdentifier: "com.example.target", focusedSubrole: nil)
  private static let noFocus: Rig.Read = (.refused(.noFocusedElement), sampled)

  @Test("No focus, then the same app's text 250 ms later: the word is read, nothing copied")
  func recoversToText() async {
    let rig = Rig()
    // Same app, but a context the original did not have: proves the RECOVERED context is used.
    let recovered = SelectionReader.AcquisitionContext(
      pid: Self.target, bundleIdentifier: "com.example.target", focusedSubrole: "AXTextArea")
    rig.rereads = Replay(
      Array(repeating: Self.noFocus, count: 10) + [(.text("keybinds"), recovered)])
    let (outcome, heldAfter) = await run(rig, first: .refused(.noFocusedElement))
    #expect(outcome.result == .text("keybinds"))
    #expect(outcome.context == recovered)
    #expect(outcome.acquired == .accessibility)
    #expect(outcome.clipboardRestore == .notTouched)
    #expect(outcome.modifierReleaseMs == nil)
    #expect(outcome.bringBack == nil)
    #expect(rig.rereadCount == 11)
    #expect(rig.elapsed == .milliseconds(250))
    #expect(rig.posts == 0)
    #expect(heldAfter == false)
    #expect(rig.rereadTimeouts.allSatisfy { $0 > 0 && $0 <= 0.25 })
  }

  @Test("No focus, then an app that hides its selection: the copy step runs through every guard")
  func recoversToCopy() async {
    let rig = Rig()
    rig.rereads = Replay([Self.noFocus, (.noSelection, Self.sampled)])
    let (outcome, _) = await run(rig, first: .refused(.noFocusedElement))
    #expect(outcome.result == .text("keybinds"))
    #expect(outcome.acquired == .clipboardCopy)
    #expect(rig.postedPIDs == [Self.target])
    #expect(outcome.bringBack == .notNeeded)
  }

  @Test("Still no focus at the deadline: the original refusal stands and nothing is copied")
  func persistentNoFocusExpires() async {
    let rig = Rig()
    rig.rereads = Replay([Self.noFocus])
    let before = rig.board.changeCount
    let (outcome, _) = await run(rig, first: .refused(.noFocusedElement))
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(outcome.context == Self.sampled)
    #expect(rig.rereadCount == 40, "reads at 0, 25, ... 975 ms; the poll at 1 s expires unread")
    #expect(rig.posts == 0)
    #expect(boardUntouched(rig, from: before))
  }

  @Test("Another app came to the front: recovery stops at once and keeps the original refusal")
  func mismatchKeepsOriginal() async {
    let rig = Rig()
    rig.rereads = Replay([nil])
    let (outcome, _) = await run(rig, first: .refused(.noFocusedElement))
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(outcome.context == Self.sampled)
    #expect(rig.rereadCount == 1)
    #expect(rig.posts == 0)
  }

  @Test("A read that finishes past the deadline is discarded, even with text")
  func lateReadDiscarded() async {
    let rig = Rig()
    rig.readTakes = .milliseconds(1200)
    rig.rereads = Replay([(.text("keybinds"), Self.sampled)])
    let (outcome, _) = await run(rig, first: .refused(.noFocusedElement))
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(rig.rereadCount == 1)
    #expect(rig.posts == 0)
  }

  @Test("A cancellation during a read discards its answer and copies nothing")
  func cancelledDuringRead() async {
    let rig = Rig()
    rig.cancelDuringRead = true
    rig.rereads = Replay([(.noSelection, Self.sampled)])
    let task = Task { @MainActor in await self.run(rig, first: .refused(.noFocusedElement)) }
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(rig.posts == 0)
  }

  @Test("Reads near the deadline are handed a positive timeout, never zero or negative")
  func timeoutsStayPositiveNearExpiry() async {
    let rig = Rig()
    rig.readTakes = .milliseconds(30)
    rig.rereads = Replay([Self.noFocus])
    let (outcome, _) = await run(rig, first: .refused(.noFocusedElement))
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(rig.rereadTimeouts.isEmpty == false)
    #expect(rig.rereadTimeouts.allSatisfy { $0 > 0 && $0 <= 0.25 })
    #expect(
      rig.rereadTimeouts.last.map { $0 < 0.25 } == true, "the last read had under 0.25 s left")
  }

  @Test("A mismatch read that finishes late, or under cancellation, still keeps the original")
  func lateOrCancelledMismatchKeepsOriginal() async {
    let late = Rig()
    late.readTakes = .milliseconds(1200)
    late.rereads = Replay([nil])
    let (lateOutcome, _) = await run(late, first: .refused(.noFocusedElement))
    #expect(refusal(lateOutcome) == .noFocusedElement)
    #expect(lateOutcome.context == Self.sampled)
    #expect(late.posts == 0)

    let cancelled = Rig()
    cancelled.cancelDuringRead = true
    cancelled.rereads = Replay([nil])
    let task = Task { @MainActor in await self.run(cancelled, first: .refused(.noFocusedElement)) }
    let (cancelledOutcome, _) = await task.value
    #expect(refusal(cancelledOutcome) == .noFocusedElement)
    #expect(cancelledOutcome.context == Self.sampled)
    #expect(cancelled.posts == 0)
  }

  @Test("A cancelled acquisition never re-reads")
  func cancelledBeforeRecovery() async {
    let rig = Rig()
    rig.rereads = Replay([(.text("keybinds"), Self.sampled)])
    let task = Task { @MainActor in await self.run(rig, first: .refused(.noFocusedElement)) }
    task.cancel()
    let (outcome, _) = await task.value
    #expect(refusal(outcome) == .noFocusedElement)
    #expect(rig.rereadCount == 0)
  }

  @Test(
    "Refusals other than no focus are never re-read",
    arguments: [
      SelectionReader.Refusal.accessibilityNotTrusted, .ownApplication, .unreadable,
      .secureInputActive,
    ])
  func otherRefusalsDoNotReread(why: SelectionReader.Refusal) async {
    let rig = Rig()
    rig.rereads = Replay([(.text("keybinds"), Self.sampled)])
    let (outcome, _) = await run(rig, first: .refused(why))
    #expect(refusal(outcome) == why)
    #expect(rig.rereadCount == 0)
  }

}
