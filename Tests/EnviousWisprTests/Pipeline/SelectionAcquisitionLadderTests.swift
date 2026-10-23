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
  .tags(.productOutcome), .serialized)
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
    var postingAuthorised = true
    var targetPresent = Replay([true])
    var copyKey: CGKeyCode? = 8
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
        copyKeyCode: { self.copyKey },
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
        })
    }

    init() {
      board.clearContents()
      board.setString("USER CLIPBOARD", forType: .string)
    }
  }

  /// The outcome, and whether a takeover was still held when the ladder returned, read BEFORE the
  /// teardown reset so the cleanup assertion observes production, not the fixture.
  private func run(_ rig: Rig) async -> (SelectionAcquisition.Outcome, heldAfter: Bool) {
    ClipboardCleanup.resetPendingForTests()
    defer { ClipboardCleanup.resetPendingForTests() }
    let outcome = await SelectionAcquisition.acquire(
      following: .noSelection,
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
    #expect(outcome.bringBack == .timedOut)
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
    #expect(outcome.bringBack == .timedOut)
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

  @Test("A layout with no copy key refuses before the wait")
  func noCopyKeyRefuses() async {
    let rig = Rig()
    rig.copyKey = nil
    let (outcome, _) = await run(rig)
    #expect(refusal(outcome) == .copyRefused)
    #expect(rig.posts == 0)
    #expect(outcome.modifierReleaseMs == nil)
    #expect(outcome.bringBack == nil)
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
}
