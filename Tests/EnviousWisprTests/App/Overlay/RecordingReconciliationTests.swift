import CoreGraphics
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **The bounded bridge reconciliation** (#2375 Phase 3, chunk C3a).
///
/// RESOLVE routes `.recordingStateChanged(true)` before COMMIT, because the
/// effect must precede the capability read. If COMMIT then discards the token,
/// Live Preview has been told a recording started and no recording definition
/// ever became current — the bridge is left active with nothing behind it.
///
/// The fix has to converge without spinning: routing calls back into the same
/// boundary that created the hazard, so reading the answer before the call proves
/// nothing about the answer after it, while an unbounded synchronous loop would
/// spin on the RECORDING path.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingReconciliationTests {

  /// A scheduler that queues rather than running, so the BOUND is observable
  /// before anything drains it.
  private final class Queue {
    var pending: [() -> Void] = []
    var enqueued = 0

    func schedule(_ work: @escaping () -> Void) {
      enqueued += 1
      pending.append(work)
    }

    /// Run everything currently queued, once. Work scheduled BY that work lands
    /// back in `pending` for the next drain, which is what lets a test watch the
    /// chain advance one turn at a time.
    @discardableResult
    func drainOnce() -> Int {
      let batch = pending
      pending = []
      batch.forEach { $0() }
      return batch.count
    }
  }

  /// Drives a fresh recording whose COMMIT is guaranteed to be discarded, by
  /// reentering a winning event from inside the capability read — the exact
  /// window §3.4 opens.
  private static func makeDirector(
    queue: Queue,
    bridge: @escaping (Bool) -> Void,
    host: any OverlayWindowHosting = WindowlessOverlayHost(),
    announce: @escaping @MainActor (OverlayAnnouncement) -> Void = { _ in },
    selections: @escaping @MainActor () -> PillDesignSelections = { .shipped },
    // **The capability is a parameter because #2376 C4 made it the only way two
    // transitions can resolve to different designs.** Before that a fixture could
    // hand out mismatched selections — a with-words design under a without-words
    // capability — and the director would install it, which is precisely the
    // combination C4 now refuses. A test that still did it would be asserting on
    // a state the product cannot reach.
    capability: @escaping () -> Bool = { false },
    onCapabilityRead: @escaping () -> Void
  ) -> OverlayDirector {
    OverlayDirector(
      host: host,
      position: { .top },
      announce: announce,
      livePreview: LivePreviewBridge(
        recordingDidChange: bridge,
        isEnabledForGeometry: {
          onCapabilityRead()
          return capability()
        },
        // Derived from this fixture's own verdict, never stated beside it.
        wordsCapability: { capability() ? .available : .previewOff },
        display: { .off }),
      grantAccessibility: {},
      openMicrophoneSettings: {},
      selections: selections,
      firstRenderSchedule: { $0() },
      scheduleReconciliation: { queue.schedule($0) })
  }

  /// **Each churn step must present something DIFFERENT.** The reducer's dedup
  /// guard drops a repeated intent, so presenting the same warning twice moves
  /// the slot once and the loop converges on the second attempt — the churn stops
  /// churning and the bound is never reached. A row that cannot exercise the
  /// behaviour it names is worse than no row: it passes, and reads as coverage.
  private static let churnEvents: [PillRequest] = [
    .warning(reason: .polishFailed),
    .error(reason: .asrFailed),
    .interruption(reason: .deviceRemoved),
    .advisory(reason: .zeroSignal),
    .warning(reason: .historySaveFailed(reason: "x")),
    .engineReady,
  ]

  private static func record(_ d: OverlayDirector) {
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0, audioLevelProvider: { 0 },
          recordingElapsedProvider: { nil }, isLocked: false)))
  }

  // MARK: - A discarded transition still tells the bridge the truth

  /// **Assert the BRIDGE, not only the reducer.** A test that checks reducer and
  /// host state alone passes while Live Preview is left running behind nothing.
  @Test("a discarded recording followed by a non-recording winner ends with the bridge told false")
  func discardedTransitionReconcilesTheBridgeToFalse() {
    let queue = Queue()
    var bridge: [Bool] = []
    var announcements: [OverlayAnnouncement] = []
    var capabilityReads = 0
    let host = WindowlessOverlayHost()
    var director: OverlayDirector?
    // A local rather than a static: a `static var` here is shared mutable state
    // across every run of the suite, so a second run would find it already
    // spent and the reentrant winner would never fire.
    var winnerFired = false

    let d = Self.makeDirector(
      queue: queue,
      bridge: { bridge.append($0) },
      host: host,
      announce: { announcements.append($0) },
      onCapabilityRead: {
        capabilityReads += 1
        // The reentrant winner: a terminal notice takes the slot while the
        // recording is still resolving. Fired ONCE, so the reconciliation
        // converges rather than churning.
        guard let director, !winnerFired else { return }
        winnerFired = true
        _ = director.present(.error(reason: .asrFailed))
      })
    director = d

    Self.record(d)

    // **The whole SEQUENCE, not just its last element.** `bridge.last == false`
    // is also true of a discard that skipped reconciliation entirely and simply
    // never told the bridge anything after the winner took the slot. The sequence
    // names what happened: the prepared recording's effect, then exactly one
    // reconciliation route to the winner — which also binds the stable-path rule
    // that reconciliation stops after its first unchanged read-route-reread pass.
    #expect(
      bridge == [true, false],
      "expected the prepared recording effect followed by one reconciliation to the winner")
    #expect(
      d.renderModel.state.presentation?.recordingDesign == nil,
      "the stale recording reached the screen")

    // **The discarded definition is commit-free, render-free, announcement-free
    // and retry-free**, and each of those is a claim the plan makes that nothing
    // was binding. Not "mint-free": RESOLVE already asked the catalog for the
    // definition, which is what makes the discard cheap rather than absent. A
    // discard that quietly retried, or that spoke, would have passed the three
    // assertions above.
    #expect(capabilityReads == 1, "the stale transaction was retried")
    #expect(host.presented.count == 1, "the stale recording reached the host")
    #expect(
      announcements.map(\.text) == ["Error: Transcription error. Try again."],
      "the discarded recording announced, or displaced the winner's announcement")
  }

  /// **The other direction, and a suite with only the first half is half a
  /// claim.** A discarded transition followed by a newer NON-RECORDING winner must
  /// end with the bridge told false; followed by a newer RECORDING winner it must
  /// end told true. A reconciliation that simply always said false would pass the
  /// case above and leave Live Preview dark through a live dictation.
  @Test("a discarded recording followed by a newer recording leaves the bridge true")
  func newerRecordingWins() {
    let queue = Queue()
    var bridge: [Bool] = []
    var director: OverlayDirector?
    var reentered = false
    var capabilityReads = 0

    // **The two transitions must be DISTINGUISHABLE, and an earlier version made
    // them identical.** Both were fresh recordings under the shipped selections,
    // so both resolved to the same design — and if the stale outer transition
    // overwrote the newer inner one the test still saw a recording and a `true`
    // bridge. It could not tell which one survived, which is the only thing it
    // exists to say.
    //
    // The INNER transition resolves first, to reading well; the stale outer one
    // resolves second, to classic. The design on screen names the winner.
    //
    // **The two are told apart by the CAPABILITY, not by mismatched selections**
    // (#2376 C4). An earlier version handed the first read a with-words design
    // under a without-words capability, which C4 now refuses and substitutes — so
    // both transitions resolved to classic and the discriminator quietly
    // vanished. Varying the capability keeps the shipped pair on both reads and
    // asks for two legal answers.
    //
    // The counter increments on RETURN rather than on entry, which is what makes
    // the inner transition read `1`: the outer call is the one that triggers
    // reentrancy, so it starts first and returns last.
    let d = Self.makeDirector(
      queue: queue,
      bridge: { bridge.append($0) },
      capability: {
        capabilityReads += 1
        return capabilityReads == 1
      },
      onCapabilityRead: {
        // The reentrant winner is another RECORDING, so the slot ends up holding
        // one even though the first transition was discarded.
        guard let director, !reentered else { return }
        reentered = true
        Self.record(director)
      })
    director = d

    Self.record(d)

    // Both recording effects, then the discriminating reconciliation route. The
    // THIRD element is the one that proves reconciliation ran at all: without it
    // the first two alone already leave `bridge.last == true`, so a discard that
    // skipped reconciliation entirely would have passed.
    #expect(
      bridge == [true, true, true],
      "expected both recording effects followed by reconciliation to the newer recording")
    #expect(capabilityReads == 2, "both transitions were not resolved")
    #expect(
      d.renderModel.state.presentation?.recordingDesign == .readingWell,
      "the stale outer recording overwrote the newer recording")
  }

  // MARK: - The bound

  /// **The counts are asserted BEFORE the queue is drained, and that ordering is
  /// what makes the case discriminating.** Drained first, a bounded and an
  /// unbounded implementation both end up converged and both pass; checked first,
  /// the unbounded one has already run the third route synchronously while the
  /// bounded one shows two attempts and one queued continuation.
  @Test("sustained churn yields after two synchronous attempts with exactly one continuation")
  func theLoopIsBounded() {
    let queue = Queue()
    var routes = 0
    var bridge: [Bool] = []
    var director: OverlayDirector?
    var churnBudget = 4

    let d = Self.makeDirector(
      queue: queue,
      bridge: { value in
        routes += 1
        bridge.append(value)
        // **The FIRST bridge call is the recording effect itself, not a
        // reconciliation route, and it must not spend a churn step.** It did, so
        // only two churn steps survived: the loop hit its bound, queued one
        // continuation, and that continuation found the world already still. The
        // unstable-continuation path — the one that re-enqueues — was never
        // executed, and the test passed.
        //
        // Every route after that changes the slot again, each with a DIFFERENT
        // request, or the dedup guard drops the repeat and the churn stops before
        // the bound is reached.
        guard routes > 1, let director, churnBudget > 0 else { return }
        _ = director.present(Self.churnEvents[churnBudget % Self.churnEvents.count])
        churnBudget -= 1
      },
      onCapabilityRead: {
        guard let director else { return }
        _ = director.present(.error(reason: .asrFailed))
      })
    director = d

    Self.record(d)

    // BEFORE draining.
    #expect(
      routes == 3,
      "expected the initial effect plus two synchronous attempts, saw \(routes) routes")
    #expect(
      queue.enqueued == 1,
      "expected exactly one queued continuation, saw \(queue.enqueued) — an unbounded loop would have run them all synchronously and queued none"
    )
    #expect(queue.pending.count == 1, "a duplicate continuation was enqueued")

    // **The FIRST drain must leave another continuation queued**, which is what
    // proves the unstable path re-enqueues rather than giving up. Without this
    // the chain's own recursion is never executed.
    queue.drainOnce()
    #expect(
      queue.pending.count == 1,
      "the continuation found the world still moving and did not schedule a successor")

    var turns = 0
    while !queue.pending.isEmpty, turns < 8 {
      queue.drainOnce()
      turns += 1
    }
    #expect(queue.pending.isEmpty, "the reconciliation never converged")
    // And the last thing the bridge heard matches what is actually on screen.
    #expect(
      bridge.last == (d.renderModel.state.presentation?.recordingDesign != nil),
      "the bridge and the screen disagree about whether a recording is up")
  }

  /// **A pass that CONVERGES must not reopen the gate while a continuation is
  /// still queued**, which is the one thing the coalescing flag exists to
  /// prevent.
  ///
  /// Three discards, and the THIRD is the discriminating one: the first queues a
  /// continuation, the second converges synchronously — which is where the old
  /// implementation wrongly cleared the flag — and the third is what observes
  /// whether the gate was reopened.
  ///
  /// This case exists because the review that found the flag defect could not be
  /// bound by anything already here: every other case stages ONE discard, and the
  /// defect needs a second one arriving inside the window where a continuation is
  /// pending. A fix nothing can fail is a fix nobody can keep.
  ///
  /// The defect it pins: the synchronous pass used to clear the flag on
  /// convergence even when it had not set it, and the continuation used to clear
  /// it before recursing — either leaves the guard open with work still queued.
  @Test("a converged reconciliation cannot reopen the gate while a continuation is queued")
  func aConvergedPassDoesNotReopenTheGate() {
    let queue = Queue()
    var routes = 0
    var director: OverlayDirector?
    var churnBudget = 4

    let d = Self.makeDirector(
      queue: queue,
      bridge: { _ in
        routes += 1
        guard routes > 1, let director, churnBudget > 0 else { return }
        _ = director.present(Self.churnEvents[churnBudget % Self.churnEvents.count])
        churnBudget -= 1
      },
      onCapabilityRead: {
        // Every fresh recording is overtaken, so every one of them discards.
        guard let director else { return }
        _ = director.present(.error(reason: .asrFailed))
      })
    director = d

    Self.record(d)
    #expect(queue.pending.count == 1, "the first discard did not queue a continuation")
    let afterFirst = queue.enqueued

    // **A SECOND discard that CONVERGES synchronously, and the convergence is the
    // whole point.** My first version made this one churn too, so the old
    // implementation never reached the line that wrongly cleared the flag — the
    // case passed against the very defect it was written to bind. The old
    // synchronous pass cleared on convergence, so this is where it opened the
    // gate while the first continuation was still queued.
    churnBudget = 0
    routes = 0
    Self.record(d)

    // A THIRD discard, which would find the gate open if the second reopened it.
    _ = d.present(.engineReady)
    churnBudget = 4
    routes = 0
    Self.record(d)

    #expect(
      queue.pending.count == 1,
      "a duplicate continuation was enqueued while one was already pending")
    #expect(
      queue.enqueued == afterFirst,
      "the third discard enqueued again — the converged second reconciliation reopened the gate")

    var turns = 0
    while !queue.pending.isEmpty, turns < 12 {
      queue.drainOnce()
      turns += 1
    }
    #expect(queue.pending.isEmpty, "the chain never converged")
  }

  /// **Then close the flag.** Without this the suite passes against a flag that is
  /// set once and never cleared — precisely the permanent mute the state machine
  /// exists to prevent. Asserted as an OUTCOME: a second, independent
  /// reconciliation must be able to enqueue and complete.
  @Test("after convergence a second reconciliation can still enqueue and complete")
  func theFlagClosesAfterConvergence() {
    let queue = Queue()
    var director: OverlayDirector?
    var churnBudget = 3

    let d = Self.makeDirector(
      queue: queue,
      bridge: { _ in
        guard let director, churnBudget > 0 else { return }
        _ = director.present(Self.churnEvents[churnBudget % Self.churnEvents.count])
        churnBudget -= 1
      },
      onCapabilityRead: {
        guard let director else { return }
        _ = director.present(.error(reason: .asrFailed))
      })
    director = d

    Self.record(d)
    var turns = 0
    while !queue.pending.isEmpty, turns < 8 {
      queue.drainOnce()
      turns += 1
    }
    let afterFirst = queue.enqueued
    #expect(queue.pending.isEmpty, "the first reconciliation never converged")

    // A SECOND, independent churn.
    churnBudget = 3
    Self.record(d)

    #expect(
      queue.enqueued > afterFirst,
      "a second reconciliation could not enqueue — the coalescing flag was never cleared, so it is a permanent mute rather than coalescing"
    )

    turns = 0
    while !queue.pending.isEmpty, turns < 8 {
      queue.drainOnce()
      turns += 1
    }
    #expect(queue.pending.isEmpty, "the second reconciliation never converged")
  }

  // MARK: - The receipt names what the slot holds

  /// **A discarded recording must not be handed the winner's receipt**
  /// (#2404 cloud review, P2).
  ///
  /// `admit` refuses to return the incumbent's receipt for a stated reason: a
  /// caller holding a receipt calls `isCurrent` about it and dismisses it, so
  /// naming somebody else's pill lets one presenter dismiss another's. The
  /// recording arm was written as an exception to that guard, justified by a
  /// same-id MORPH keeping the identity it was created with. That is true of a
  /// morph and false of a recording that never committed — and the discard staged
  /// by the rest of this suite is exactly such a recording.
  ///
  /// The assertion is on WHICH pill the receipt names. A receipt naming the
  /// recording would be correct; the defect is a receipt naming the terminal
  /// notice that won the slot, which the recording caller can then dismiss.
  @Test("a discarded recording is not handed the winner's receipt")
  func discardedRecordingDoesNotInheritTheWinnersReceipt() throws {
    let queue = Queue()
    var director: OverlayDirector?
    var winnerFired = false
    var winnerReceipt: PillReceipt?

    let d = Self.makeDirector(
      queue: queue,
      bridge: { _ in },
      onCapabilityRead: {
        guard let director, !winnerFired else { return }
        winnerFired = true
        winnerReceipt = director.present(.error(reason: .asrFailed))
      })
    director = d

    var results: [PillPresentationResult] = []
    let recordingReceipt = d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0, audioLevelProvider: { 0 },
          recordingElapsedProvider: { nil }, isLocked: false)),
      onResult: { results.append($0) })

    // **The fixture asserts it reached its subject before the claim is read.**
    // A recording that quietly committed would leave a recording pill current,
    // and every assertion below would then be about the wrong scenario.
    #expect(winnerFired, "the reentrant winner never fired, so nothing was discarded")
    // A terminal notice renders as `.notice`; a committed recording would render
    // as `.recording`. This is the line that separates "the recording was
    // discarded" from "the recording quietly won", and every claim below is
    // about the wrong scenario without it.
    guard case .notice? = d.renderModel.state.presentation?.content else {
      Issue.record(
        "the winner did not take the slot, so the recording was never discarded: \(String(describing: d.renderModel.state.presentation?.content))"
      )
      return
    }
    let winner = try #require(
      winnerReceipt, "the winner was itself refused, so it owns no receipt to inherit")
    #expect(
      d.renderModel.state.presentation?.id == winner.presentationID,
      "the pill on screen is not the winner, so this fixture is staging something else")

    #expect(
      recordingReceipt == nil,
      "the discarded recording was handed a receipt naming \(String(describing: recordingReceipt?.presentationID))"
    )
    #expect(results == [.notPresented], "the discarded recording was told it was presented")
  }

  /// The paired accepted case, in the same rig with the winner disarmed. Without
  /// it, a director that returned nil for every recording receipt would satisfy
  /// the case above.
  @Test("an accepted recording still receives its own receipt")
  func acceptedRecordingStillReceivesItsOwnReceipt() throws {
    let queue = Queue()
    let d = Self.makeDirector(queue: queue, bridge: { _ in }, onCapabilityRead: {})

    var results: [PillPresentationResult] = []
    let receipt = try #require(
      d.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0, audioLevelProvider: { 0 },
            recordingElapsedProvider: { nil }, isLocked: false)),
        onResult: { results.append($0) }))

    guard case .recording? = d.renderModel.state.presentation?.content else {
      Issue.record("no recording pill reached the screen, so the receipt names something else")
      return
    }
    #expect(results == [.presented(receipt)], "an accepted recording was not reported presented")
  }
}
