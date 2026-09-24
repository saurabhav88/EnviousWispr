import AppKit
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// MARK: - ClipboardCleanupLandingTests (#3106 PR B)
//
// A checked cleanup waits, inside the one pending task, for the paste's landing decision and keeps
// the dictation on the board when the paste was a permitted miss. Every case drives an ISOLATED
// pasteboard, never `NSPasteboard.general` (`ClipboardIsolationFreezeTests`, #2146).
//
// No case sleeps to decide anything. The decision is a fake the test publishes; "the task is now
// waiting for it" is the fake's own signal (it was asked), and "the task is done" is
// `awaitPendingCleanup()` or the awaited cancellation, both signals from the subject
// (testing-philosophy.md RULE: never-guess-when-the-subject-is-finished).

/// A landing decision the test controls: preset (decided before the cleanup woke) or published
/// while the cleanup waits for it.
@MainActor
private final class FakeLanding {
  private var preset: PasteArrivalLanding??
  private var waiter: CheckedContinuation<PasteArrivalLanding?, Never>?
  private var askedWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  private(set) var asked = false

  init(preset: PasteArrivalLanding?? = nil) { self.preset = preset }

  func decision() async -> PasteArrivalLanding? {
    asked = true
    askedWaiters.values.forEach { $0.resume(returning: true) }
    askedWaiters.removeAll()
    if let preset { return preset }
    return await withCheckedContinuation { waiter = $0 }
  }

  /// Resolves once the cleanup has asked for the decision; throws instead of hanging when it never
  /// does, so a broken subject fails the case rather than the whole run.
  func waitUntilAsked(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    if asked { return }
    let id = UUID()
    let arrived = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      askedWaiters[id] = c
      Task { @MainActor [weak self] in
        // deadline-fallback: a hang guard only; no assertion depends on this clock.
        try? await Task.sleep(for: .seconds(10))
        self?.askedWaiters.removeValue(forKey: id)?.resume(returning: false)
      }
    }
    try #require(arrived, "the cleanup never asked for the landing decision", sourceLocation: sourceLocation)
  }

  func publish(_ landing: PasteArrivalLanding?) {
    waiter?.resume(returning: landing)
    waiter = nil
  }
}

/// The cleanup's 200 ms minimum, released by the test instead of by a clock. Throws on
/// cancellation, as the production sleep does.
@MainActor
private final class WakeGate {
  private var released: Bool
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var entered = false
  private var enteredWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  /// `open`: the wait returns at once (no clock involved).
  init(open: Bool = true) { released = open }

  func wait() async throws {
    if released { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        waiters[id] = c
        entered = true
        enteredWaiters.values.forEach { $0.resume(returning: true) }
        enteredWaiters.removeAll()
      }
    } onCancel: {
      Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
  }

  /// Resolves once the cleanup is suspended in this gate; throws instead of hanging.
  func waitUntilEntered(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    if entered { return }
    let id = UUID()
    let arrived = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      enteredWaiters[id] = c
      Task { @MainActor [weak self] in
        // deadline-fallback: a hang guard only; no assertion depends on this clock.
        try? await Task.sleep(for: .seconds(10))
        self?.enteredWaiters.removeValue(forKey: id)?.resume(returning: false)
      }
    }
    try #require(arrived, "the cleanup never reached its minimum wait", sourceLocation: sourceLocation)
  }

  func release() {
    released = true
    waiters.values.forEach { $0.resume() }
    waiters.removeAll()
  }
}

/// Waits for a cleanup task to finish, or fails the case instead of hanging when it never does.
/// Resumes exactly once, from whichever comes first.
@MainActor
private func finished(
  _ task: Task<Void, Never>?, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let task = try #require(task, "no cleanup task was scheduled", sourceLocation: sourceLocation)
  final class Once { var done = false }
  let once = Once()
  let completed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
    Task { @MainActor in
      await task.value
      if !once.done { once.done = true; c.resume(returning: true) }
    }
    Task { @MainActor in
      // deadline-fallback: a hang guard only; no assertion depends on this clock.
      try? await Task.sleep(for: .seconds(10))
      if !once.done { once.done = true; c.resume(returning: false) }
    }
  }
  try #require(completed, "the cleanup task never finished", sourceLocation: sourceLocation)
}

/// Product Outcome: when these fail, a paste that went nowhere loses the user's words, or a paste
/// that landed loses the user's own clipboard.
@Suite("Clipboard cleanup keeps a missed paste (#3106 PR B)", .tags(.productOutcome), .serialized)
@MainActor
struct ClipboardCleanupLandingTests {


  private func put(_ text: String, on pb: NSPasteboard) {
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  private func snapshot(of pb: NSPasteboard) -> ClipboardSnapshot {
    ClipboardSnapshot(
      items: pb.string(forType: .string).map { [[.string: Data($0.utf8)]] } ?? [],
      changeCount: pb.changeCount)
  }

  private func board(holding text: String) -> NSPasteboard {
    let pb = NSPasteboard.withUniqueName()
    put(text, on: pb)
    return pb
  }

  private func withCleanCleanupThrowing(_ body: () async throws -> Void) async throws {
    ClipboardCleanup.resetPendingForTests()
    defer { ClipboardCleanup.resetPendingForTests() }
    try await body()
  }

  /// Records every outcome the cleanup reports.
  @MainActor
  private final class Outcomes {
    var all: [ClipboardCleanup.LandingOutcome] = []
  }

  private func check(
    _ fake: FakeLanding, legacy: String, permitted: Bool = true, into outcomes: Outcomes,
    gate: WakeGate = WakeGate()
  ) -> ClipboardCleanup.LandingCheck {
    ClipboardCleanup.LandingCheck(
      decision: { await fake.decision() },
      mayRetain: { landing in permitted && landing == .absent },
      legacyText: legacy,
      onOutcome: { outcomes.all.append($0) },
      minimumWait: { try await gate.wait() })
  }

  private static let user = "the user's own clipboard"
  private static let dictation = "the dictated sentence"
  private static let adjusted = "the dictated sentence, adjusted for context"

  /// Restore ON: the user's clipboard is photographed, our payload is written, cleanup scheduled.
  private func restoreOnPaste(
    payload: String, fake: FakeLanding, permitted: Bool = true, outcomes: Outcomes,
    gate: WakeGate = WakeGate()
  ) -> (NSPasteboard, Int) {
    let pb = board(holding: Self.user)
    let snap = snapshot(of: pb)
    put(payload, on: pb)
    let after = pb.changeCount
    ClipboardCleanup.scheduleRestore(
      snap, changeCountAfterPaste: after, tier: .cgEvent, on: pb,
      landing: check(
        fake, legacy: Self.dictation, permitted: permitted, into: outcomes, gate: gate))
    return (pb, after)
  }

  // MARK: Restore ON

  @Test("A miss decided before the cleanup woke keeps the dictation and reports the board receipt")
  func missDecidedEarlyIsKept()  async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding(preset: .some(.absent))
      let outcomes = Outcomes()
      let (pb, after) = restoreOnPaste(payload: Self.dictation, fake: fake, outcomes: outcomes)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.dictation)
      #expect(outcomes.all == [.retained(changeCount: after)])
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  @Test("A miss decided while the cleanup waits keeps the dictation")
  func missDecidedLateIsKept() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, after) = restoreOnPaste(payload: Self.dictation, fake: fake, outcomes: outcomes)
      try await fake.waitUntilAsked()
      // Still ours while it waits: the slot is held, so a manual request or Quick Add refuses.
      #expect(ClipboardCleanup.hasPending)
      #expect(pb.string(forType: .string) == Self.dictation)
      fake.publish(.absent)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.dictation)
      #expect(outcomes.all == [.retained(changeCount: after)])
    }
  }

  @Test("A context-adjusted payload is replaced by the legacy text before it is kept")
  func adjustedPayloadIsRewrittenThenKept()  async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding(preset: .some(.absent))
      let outcomes = Outcomes()
      let (pb, after) = restoreOnPaste(payload: Self.adjusted, fake: fake, outcomes: outcomes)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.dictation)
      #expect(pb.changeCount > after, "the legacy text had to be written")
      #expect(outcomes.all == [.retained(changeCount: pb.changeCount)])
    }
  }

  @Test(
    "Not a permitted miss: the user's clipboard comes back and nothing is reported",
    arguments: [
      ("found", PasteArrivalLanding?.some(.found(.sameField)), true),
      ("cannot read", .some(.cannotRead(.unsupported)), true),
      ("inconclusive", .some(.inconclusive(.cancelled)), true),
      ("no decision", nil, true),
      ("excluded route", .some(.absent), false),
    ])
  func notAPermittedMissRestores(name: String, landing: PasteArrivalLanding?, permitted: Bool)
     async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding(preset: .some(landing))
      let outcomes = Outcomes()
      let (pb, _) = restoreOnPaste(
        payload: Self.dictation, fake: fake, permitted: permitted, outcomes: outcomes)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(fake.asked, "\(name): the check was consulted")
      #expect(pb.string(forType: .string) == Self.user, "\(name)")
      #expect(outcomes.all.isEmpty, "\(name)")
    }
  }

  @Test("The user copies while the cleanup waits: their copy stays and the miss yields")
  func userCopyYields() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, _) = restoreOnPaste(payload: Self.dictation, fake: fake, outcomes: outcomes)
      try await fake.waitUntilAsked()
      put("something the user just copied", on: pb)
      fake.publish(.absent)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == "something the user just copied")
      #expect(outcomes.all == [.yielded])
    }
  }

  @Test("A newer delivery supersedes a waiting cleanup: the old one neither writes nor reports")
  func supersededCleanupIsSilent() async throws {
    try await withCleanCleanupThrowing {
      let oldFake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, _) = restoreOnPaste(payload: Self.dictation, fake: oldFake, outcomes: outcomes)
      try await oldFake.waitUntilAsked()
      let oldTask = try #require(ClipboardCleanup.pendingTaskForTests())

      // The next dictation's delivery inherits the user's clipboard and schedules its own cleanup.
      let inherited = ClipboardCleanup.snapshotForDelivery(from: pb)
      put("the next dictation", on: pb)
      let newFake = FakeLanding()
      ClipboardCleanup.scheduleRestore(
        inherited, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb,
        landing: check(newFake, legacy: "the next dictation", into: outcomes))

      oldFake.publish(.absent)
      try await finished(oldTask)
      try await newFake.waitUntilAsked()
      #expect(outcomes.all.isEmpty, "the superseded cleanup reported")
      #expect(ClipboardCleanup.hasPending, "the superseded cleanup cleared the newer slot")
      #expect(pb.string(forType: .string) == "the next dictation")

      newFake.publish(.found(.sameField))
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.user)
      #expect(outcomes.all.isEmpty)
    }
  }

  @Test("A cancelled waiting cleanup does nothing when its decision arrives")
  func cancelledCleanupIsSilent() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, _) = restoreOnPaste(payload: Self.dictation, fake: fake, outcomes: outcomes)
      try await fake.waitUntilAsked()
      let task = try #require(ClipboardCleanup.pendingTaskForTests())
      // Cancelled synchronously, exactly as a delivery that found the board moved does.
      ClipboardCleanup.resetPendingForTests()
      fake.publish(.absent)
      try await finished(task)
      #expect(outcomes.all.isEmpty)
      #expect(pb.string(forType: .string) == Self.dictation, "no restore after cancellation")
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  // MARK: Restore OFF

  /// Restore OFF: our payload is written with no snapshot; the one cleanup is a legacy rewrite.
  private func restoreOffPaste(
    payload: String, fake: FakeLanding, outcomes: Outcomes, gate: WakeGate = WakeGate()
  ) -> (NSPasteboard, Int) {
    let pb = board(holding: Self.user)
    put(payload, on: pb)
    let after = pb.changeCount
    ClipboardCleanup.scheduleLegacyRewrite(
      legacyText: Self.dictation, submittedChangeCount: after, tier: .cgEvent, on: pb,
      landing: check(fake, legacy: Self.dictation, into: outcomes, gate: gate))
    return (pb, after)
  }

  @Test("Restore off, adjusted payload: rewritten at the usual moment, then kept on a miss")
  func restoreOffAdjustedIsRewrittenThenKept() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, after) = restoreOffPaste(payload: Self.adjusted, fake: fake, outcomes: outcomes)
      try await fake.waitUntilAsked()
      // The rewrite did not wait for the decision.
      #expect(pb.string(forType: .string) == Self.dictation)
      let rewritten = pb.changeCount
      #expect(rewritten > after)
      fake.publish(.absent)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(outcomes.all == [.retained(changeCount: rewritten)])
    }
  }

  @Test("Restore off, legacy payload: nothing is written, and a miss is still reported")
  func restoreOffLegacyIsKeptWithoutAWrite() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let (pb, after) = restoreOffPaste(payload: Self.dictation, fake: fake, outcomes: outcomes)
      try await fake.waitUntilAsked()
      #expect(pb.changeCount == after, "an already-legacy board was written again")
      fake.publish(.absent)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.dictation)
      #expect(outcomes.all == [.retained(changeCount: after)])
    }
  }

  @Test("Restore off, the paste landed: the rewrite stands and nothing is reported")
  func restoreOffHitReportsNothing()  async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding(preset: .some(.found(.sameField)))
      let outcomes = Outcomes()
      let (pb, _) = restoreOffPaste(payload: Self.adjusted, fake: fake, outcomes: outcomes)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == Self.dictation)
      #expect(outcomes.all.isEmpty)
    }
  }

  @Test("Restore off, the user copied before the cleanup woke: no rewrite, and the miss yields")
  func restoreOffUserCopyYields() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding()
      let outcomes = Outcomes()
      let gate = WakeGate(open: false)
      let (pb, _) = restoreOffPaste(
        payload: Self.adjusted, fake: fake, outcomes: outcomes, gate: gate)
      put("something the user just copied", on: pb)
      gate.release()
      try await fake.waitUntilAsked()
      fake.publish(.absent)
      try await finished(ClipboardCleanup.pendingTaskForTests())
      #expect(pb.string(forType: .string) == "something the user just copied")
      #expect(outcomes.all == [.yielded])
    }
  }

  @Test("A cleanup cancelled during its minimum wait abandons: no decision asked, no board change")
  func cancelledDuringWaitAbandons() async throws {
    try await withCleanCleanupThrowing {
      let fake = FakeLanding(preset: .some(.absent))
      let outcomes = Outcomes()
      let gate = WakeGate(open: false)
      let (pb, _) = restoreOnPaste(
        payload: Self.dictation, fake: fake, outcomes: outcomes, gate: gate)
      let task = try #require(ClipboardCleanup.pendingTaskForTests())
      try await gate.waitUntilEntered()
      ClipboardCleanup.resetPendingForTests()
      try await finished(task)
      #expect(fake.asked == false)
      #expect(outcomes.all.isEmpty)
      #expect(pb.string(forType: .string) == Self.dictation, "abandoned, not restored early")
    }
  }
}
