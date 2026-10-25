import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #2108, #3735: what a Universal preview session delivers, and how big it can get.
@Suite struct TranscribeCppPreviewSessionTests {

  /// Wait for the publisher task to deliver, on a bounded real-time poll.
  ///
  /// `Task.yield()` alone is not enough: the publisher consumes an `AsyncStream`
  /// on its own task, and yielding from the test does not guarantee it is
  /// scheduled. An earlier version of these tests yielded 2,000 times and
  /// delivered nothing — and the empty-hypothesis test PASSED anyway, because
  /// "no empty string arrived" is trivially true when nothing arrives at all.
  private func waitForDelivery(_ box: Box, count: Int = 1) async {
    for _ in 0..<600 where box.delivered.count < count {
      // deadline-fallback: bounded poll around a cross-task delivery that has no
      // synchronous signal to wait on.
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  final class Box: @unchecked Sendable {
    var delivered: [String] = []
  }

  private func word(_ canonical: String, alias: String) -> CustomWord {
    CustomWord(canonical: canonical, aliases: [alias])
  }

  /// The bound must survive CORRECTION, not just precede it.
  ///
  /// A custom word whose canonical is longer than the alias it replaces EXPANDS
  /// the text, so a tail already at the limit can cross it on the way out. The
  /// Apple producer applies the bound on both sides; the first version of this
  /// engine ported only the inner half, and cloud review caught it.
  @Test("a custom word that expands the text cannot push it past the bound")
  func correctionCannotExceedTheBound() async {
    let alias = "qtx"
    let canonical = String(repeating: "Qualtrics", count: 12)  // 108 chars for 3
    let lookups = WordCorrector.buildLookups(words: [word(canonical, alias: alias)])

    let box = Box()
    let handle = TranscribeCppPreviewSession(
      lookups: lookups, onText: { box.delivered.append($0) })

    // Just over the limit, so the INNER bound trims to exactly the cap, with a
    // modest number of expanding aliases scattered through filler. An earlier
    // version packed the whole 2,000 characters with aliases; correction over
    // 500 matches did not finish inside the poll budget, which looked like a
    // delivery failure and was really the fixture being unreasonable.
    var text = ""
    while text.count < LivePreviewTextBound.maxCharacters + 100 {
      text += "\(alias) filler filler filler filler filler filler filler "
    }
    handle.enqueue(text)

    await waitForDelivery(box)
    await PreviewWait.within("the session's end") { await handle.end() }

    #expect(box.delivered.first != nil, "control: something must have been delivered")
    if let text = box.delivered.first {
      // Control: correction genuinely expanded it, so the assertion below is
      // about the bound rather than about a string that was always short.
      #expect(text.contains("Qualtrics"), "control: the custom word must have been applied")
      #expect(
        text.count <= LivePreviewTextBound.maxCharacters,
        "correction expanded the text past the producer bound: \(text.count) chars")
    }
  }

  /// Empty hypotheses must not reach the display: blanking the pill mid-sentence
  /// reads to a user as the app losing what they just said.
  @Test("an empty hypothesis is not delivered")
  func emptyHypothesisIsNotDelivered() async {
    let box = Box()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onText: { box.delivered.append($0) })

    handle.enqueue("")
    handle.enqueue("real words")
    await waitForDelivery(box)
    await PreviewWait.within("the session's end") { await handle.end() }

    // CONTROL FIRST. Without it this test passes when nothing is delivered at
    // all, which is exactly how it passed before the delivery wait was fixed.
    #expect(
      box.delivered.contains("real words"),
      "control: a real hypothesis must arrive, or the assertion below is vacuous")
    #expect(!box.delivered.contains(""), "an empty string must never reach the display")
  }

  /// `end()` is idempotent AND awaitable: a second caller waits for the same
  /// teardown rather than returning early. An early return would let the
  /// recognizer open a new decode loop over the shared Whisper instance while
  /// the old session's still-returning transcribe was still running — the
  /// decoder-state corruption `Whisper streaming session.cancel()` documents.
  @Test("end is safe and complete when called twice, from two callers")
  func endIsIdempotentAndAwaitable() async {
    let box = Box()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onText: { box.delivered.append($0) })

    await PreviewWait.within("both ends") {
      async let first: Void = handle.end()
      async let second: Void = handle.end()
      _ = await (first, second)
    }

    // Both returned; nothing hung and nothing crashed. A post-end enqueue must
    // also not deliver, since the stream is finished.
    handle.enqueue("after the end")
    // deadline-fallback: give any (incorrect) delivery a real chance to land
    // before asserting it did not.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!box.delivered.contains("after the end"))
  }

  // MARK: - #2108: the ten-minute cap must not orphan a running decode

  /// A session whose `cancel()` blocks until the test lets it finish, standing in
  /// for the real one still inside a Whisper transcribe.
  ///
  /// Held through `WhisperIncrementalSession` rather than the concrete type,
  /// which is the only reason a teardown that must WAIT can be observed at all.
  private final class BlockingSession: WhisperIncrementalSession, @unchecked Sendable {
    private let mutex = NSLock()
    private var enteredCancel = false
    private var releasedCancel = false

    var cancelEntered: Bool { mutex.withLock { enteredCancel } }
    func releaseCancel() { mutex.withLock { releasedCancel = true } }

    func start(
      audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
    ) async {}
    func noteStopRequested() async {}
    func finalize(finalSamples: [Float], speechSegments: [SpeechSegment]) async
      -> IncrementalResult
    {
      fatalError("the preview never finalizes — it cancels")
    }

    func cancel() async {
      mutex.withLock { enteredCancel = true }
      while !mutex.withLock({ releasedCancel }) {
        try? await Task.sleep(for: .milliseconds(2))  // deadline-fallback: released by the test
      }
    }
  }

  /// Keeps the provider `start` was handed, so the test can pull it like the decode loop does.
  private final class ProviderSession: WhisperIncrementalSession, @unchecked Sendable {
    private let mutex = NSLock()
    private var provider: (@Sendable () async -> (samples: [Float], count: Int))?
    private var cancelled = false
    var wasCancelled: Bool { mutex.withLock { cancelled } }

    func pull() async -> (samples: [Float], count: Int)? {
      guard let provider = mutex.withLock({ provider }) else { return nil }
      return await provider()
    }
    func start(
      audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
    ) async {
      mutex.withLock { provider = audioSamplesProvider }
    }
    func noteStopRequested() async {}
    func finalize(finalSamples: [Float], speechSegments: [SpeechSegment]) async
      -> IncrementalResult
    {
      fatalError("the preview never finalizes — it cancels")
    }
    func cancel() async { mutex.withLock { cancelled = true } }
  }

  /// #2117: a Universal preview in a long meeting keeps showing live words. Before, the owner
  /// kept every sample and stopped decoding at 10 minutes, so the pill froze for the rest of
  /// the meeting. Now it keeps only what the decode loop has not released.
  /// A sample value that names its absolute position, exact in `Float` (below 2^24).
  private static func mark(_ position: Int) -> Float { Float(position % 8_000_000) }

  @Test("a 20-minute stream preserves absolute provider coordinates without capping")
  func longStreamKeepsARollingWindow() async throws {
    let handle = TranscribeCppPreviewSession(lookups: nil, onText: { _ in })
    let session = ProviderSession()
    await handle.attach(session)
    let second = 16_000
    var fed = 0
    var maxRetained = 0
    for minuteSecond in 0..<(20 * 60) {
      // Position-dependent audio, so a wrong slice cannot pass for the right one.
      await handle.feed((0..<second).map { Self.mark(fed + $0) })
      fed += second
      // The decode loop releases everything older than its last 20 s.
      handle.releaseAudio(before: fed - 20 * second)
      maxRetained = max(maxRetained, handle.retainedSampleCountForTests)
      if minuteSecond % 60 == 59 {
        let pulled = try #require(await session.pull(), "control: the session was started")
        #expect(pulled.count == fed, "count stays absolute")
        let kept = min(fed, 20 * second)
        #expect(pulled.samples.count == kept)
        #expect(pulled.samples.first == Self.mark(fed - kept), "the window is the newest audio")
        #expect(pulled.samples.last == Self.mark(fed - 1))
      }
    }
    #expect(fed > TranscribeCppPreviewSession.maxRetainedSamples, "control: past the ceiling")
    #expect(maxRetained <= 21 * second, "retained audio stays at the released window")
    #expect(session.wasCancelled == false, "the ceiling never stopped the decode loop")
    // A repeated or stale release drops nothing more.
    handle.releaseAudio(before: fed - 30 * second)
    #expect(handle.retainedSampleCountForTests == 20 * second)
    await handle.end()
    handle.releaseAudio(before: fed)
    #expect(handle.retainedSampleCountForTests == 0, "a release after end() is harmless")
  }

  private final class Flag: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = false
    var isSet: Bool { mutex.withLock { value } }
    func set() { mutex.withLock { value = true } }
  }

  /// Crossing the ten-minute cap stops the decode loop OUTSIDE `end()`, so the
  /// stop must be joinable or the recognizer's turnover releases over a decode
  /// that is still running.
  ///
  /// The failure it prevents: cap fires, the user stops and immediately starts
  /// another recording, `end()` sees no session and returns instantly, and a new
  /// decode loop begins on the same cached Whisper instance while the old
  /// transcribe is still in it. That is the decoder-state corruption the whole
  /// turnover design exists to prevent, reached through a path that bypasses it.
  ///
  /// Mutation control: awaiting the cancel inline in `endDecoding` — the shape
  /// this replaced — makes the mid-test assertion red, because `end()` then
  /// returns while the cancel is still blocked.
  @Test("end() waits for a cap-triggered cancel that is still running")
  func cappedDecodeStopIsJoinable() async {
    let box = Box()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onText: { box.delivered.append($0) })
    let session = BlockingSession()
    await PreviewWait.within("the attach", onExpiry: session.releaseCancel) {
      await handle.attach(session)
    }

    // One feed over the cap. The samples are never retained — the guard caps
    // before the append — so this array is transient.
    let overCap = [Float](
      repeating: 0, count: TranscribeCppPreviewSession.maxRetainedSamples + 1)
    let fed = Task { await handle.feed(overCap) }

    // CONTROL: the cap really fired and the cancel really started. Without this
    // the wait below would pass on a run where nothing was ever cancelled.
    for _ in 0..<500 where !session.cancelEntered {
      try? await Task.sleep(for: .milliseconds(2))  // deadline-fallback: bounded poll
    }
    #expect(session.cancelEntered, "control: the cap must have started a cancel")

    let ended = Flag()
    let ending = Task {
      await handle.end()
      ended.set()
    }

    // deadline-fallback: give an incorrect early return a real chance to land.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(
      !ended.isSet,
      "end() returned while the capped session's decode was still stopping")

    session.releaseCancel()
    await PreviewWait.within("the capped feed and end to finish", onExpiry: session.releaseCancel) {
      await fed.value
      await ending.value
    }
    #expect(ended.isSet, "end() must complete once the cancel finishes")
  }

  /// Records the order of start and cancel. `start` signals its entry and holds on a gate the
  /// test opens; every signal is a continuation the subject resumes, never a poll.
  private final class OrderedSession: WhisperIncrementalSession, @unchecked Sendable {
    private let mutex = NSLock()
    private var log: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpen = false
    let startEntered = PreviewWait.Once()
    var events: [String] { mutex.withLock { log } }

    /// Opens the start gate (idempotent; also the cleanup when a wait expires).
    func releaseStart() {
      let waiting = mutex.withLock { () -> CheckedContinuation<Void, Never>? in
        gateOpen = true
        defer { gate = nil }
        return gate
      }
      waiting?.resume()
    }

    func start(
      audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
    ) async {
      mutex.withLock { log.append("start entered") }
      startEntered.fulfil(true)
      await withCheckedContinuation { c in
        let open = mutex.withLock { () -> Bool in
          if gateOpen { return true }
          gate = c
          return false
        }
        if open { c.resume() }
      }
      mutex.withLock { log.append("start returned") }
    }
    func noteStopRequested() async {}
    func finalize(finalSamples: [Float], speechSegments: [SpeechSegment]) async
      -> IncrementalResult
    {
      fatalError("the preview never finalizes — it cancels")
    }
    func cancel() async { mutex.withLock { log.append("cancel") } }
  }

  /// **What the user sees when this fails:** after a very short recording, the preview model
  /// stays in memory (the ended handle and its session keep each other alive), or a preview
  /// keeps decoding after the recording ended.
  @Test("a session attached after end() is never started and is released")
  func attachAfterEndNeverStarts() async {
    let handle = TranscribeCppPreviewSession(lookups: nil, onText: { _ in })
    await PreviewWait.within("the end") { await handle.end() }
    let session = OrderedSession()
    session.releaseStart()
    await PreviewWait.within("the late attach") { await handle.attach(session) }
    #expect(session.events == ["cancel"], "never started, only released")
  }

  @Test("end() during a start waits for the start, then cancels it")
  func endDuringStartCancelsAfterTheStart() async {
    let teardownStarted = PreviewWait.Once()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onText: { _ in }, onTeardownStarted: { teardownStarted.fulfil(true) })
    let session = OrderedSession()
    let attaching = Task { await handle.attach(session) }
    await PreviewWait.within("the start's entry", onExpiry: session.releaseStart) {
      _ = await session.startEntered.value()
    }

    let ending = Task { await handle.end() }
    // The subject's own signal: teardown began and is now joining the held start.
    await PreviewWait.within("teardown's entry", onExpiry: session.releaseStart) {
      _ = await teardownStarted.value()
    }
    #expect(session.events == ["start entered"], "no cancel while the start is still held")

    session.releaseStart()
    await PreviewWait.within("attach and end to finish", onExpiry: session.releaseStart) {
      await attaching.value
      await ending.value
    }
    #expect(session.events == ["start entered", "start returned", "cancel"])
  }

  // MARK: - #2108: the turnover lock actually serializes

  /// Tests the PRIMITIVE, not the vendor.
  ///
  /// N tasks acquire, suspend inside the critical section, and release. Peak
  /// occupancy must be 1. A completion count runs alongside so the assertion
  /// cannot pass vacuously on a run where nothing entered — which is how a
  /// serialization test lies.
  ///
  /// The mutation that matters is the one this replaced: with actor isolation
  /// alone and no lock, peak occupancy is N.
  @Test("the turnover lock admits exactly one holder at a time")
  func turnoverLockAdmitsOneHolderAtATime() async {
    let lock = PreviewSessionTurnover()

    final class Occupancy: @unchecked Sendable {
      private let mutex = NSLock()
      private var current = 0
      private(set) var peak = 0
      private(set) var completed = 0
      func enter() {
        mutex.lock()
        current += 1
        peak = max(peak, current)
        mutex.unlock()
      }
      func leave() {
        mutex.lock()
        current -= 1
        completed += 1
        mutex.unlock()
      }
    }
    let occupancy = Occupancy()

    await PreviewWait.within("every holder to pass the lock") {
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
          group.addTask {
            await lock.acquire()
            occupancy.enter()
            // Suspend INSIDE the critical section. Without this the sections may
            // not overlap even when unprotected, and the test would pass against
            // a broken lock.
            await Task.yield()
            await Task.yield()
            occupancy.leave()
            await lock.release()
          }
        }
      }
    }

    #expect(occupancy.completed == 12, "control: every task must have entered and left")
    #expect(occupancy.peak == 1, "peak occupancy \(occupancy.peak) — the lock did not serialize")
  }

  /// FIFO hand-off: `release()` must pass ownership straight to the next waiter
  /// rather than clearing `held` and letting anyone race for it. Asserted by the
  /// absence of starvation — every waiter completes — since the internal state is
  /// private and a test that reached into it would be testing the implementation
  /// rather than the contract.
  @Test("no waiter is starved by the hand-off")
  func noWaiterIsStarved() async {
    let lock = PreviewSessionTurnover()
    final class Counter: @unchecked Sendable {
      private let mutex = NSLock()
      private(set) var done = 0
      func tick() {
        mutex.lock()
        done += 1
        mutex.unlock()
      }
    }
    let counter = Counter()

    await PreviewWait.within("every waiter to pass the lock") {
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<25 {
          group.addTask {
            await lock.acquire()
            await Task.yield()
            counter.tick()
            await lock.release()
          }
        }
      }
    }
    #expect(counter.done == 25)
  }
}

/// #3973: a Universal transcript session (EnviousMeet's live words) delivers every finalized
/// delta in order, within a queued-text budget, and ends exactly once.
///
/// **What the user sees when this fails:** the meeting's live words skip a sentence, repeat
/// one, or keep running after the track stopped; or a slow screen makes the app's memory grow.
@Suite("Universal live words transcript session (#3973)", .tags(.productOutcome))
struct LiveWordsTranscriptSessionTests {

  /// What the owner received, with waits on the count. With `holdFirst`, delivery of the first
  /// event blocks the queue's consumer until `release()`: a consumer stuck in the owner.
  final class Received: @unchecked Sendable {
    /// Recursive: waiter conditions run under it and read `all`.
    private let lock = NSRecursiveLock()
    private var events: [LiveWordsEvent] = []
    /// Each waiter's condition is checked under the lock on registration and after every event.
    private var waiters: [(([LiveWordsEvent]) -> Bool, CheckedContinuation<Void, Never>)] = []
    private var holding: Bool
    private var released = false
    private let gate = DispatchSemaphore(value: 0)
    init(holdFirst: Bool = false) { holding = holdFirst }
    var all: [LiveWordsEvent] { lock.withLock { events } }
    @Sendable func receive(_ event: LiveWordsEvent) {
      let (ready, hold) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
        events.append(event)
        let met = waiters.filter { $0.0(events) }.map(\.1)
        waiters.removeAll { $0.0(events) }
        return (met, holding && events.count == 1)
      }
      for waiter in ready { waiter.resume() }
      if hold { gate.wait() }
    }
    /// Lets the held consumer go (idempotent; also every wait's expiry cleanup).
    @Sendable func release() {
      let first = lock.withLock { () -> Bool in
        holding = false
        defer { released = true }
        return !released
      }
      // One signal: frees a consumer already waiting, or is never consumed.
      if first { gate.signal() }
    }
    func until(_ count: Int) async {
      await until { $0.count >= count }
    }
    /// Returns once `condition` holds for the events received so far: checked and registered
    /// in one lock step, so an event arriving in between cannot be missed.
    func until(_ condition: @escaping ([LiveWordsEvent]) -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if condition(events) { return true }
          waiters.append((condition, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  /// A rolling session stand-in: `start` returns at once, `cancel` is recorded.
  final class IdleSession: WhisperIncrementalSession, @unchecked Sendable {
    private let lock = NSLock()
    private var cancels = 0
    var cancelCount: Int { lock.withLock { cancels } }
    func start(
      audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
    ) async {}
    func noteStopRequested() async {}
    func finalize(finalSamples: [Float], speechSegments: [SpeechSegment]) async
      -> IncrementalResult
    {
      fatalError("the preview never finalizes — it cancels")
    }
    func cancel() async { lock.withLock { cancels += 1 } }
  }

  private static func handle(_ received: Received) -> TranscribeCppPreviewSession {
    TranscribeCppPreviewSession(lookups: nil, onEvent: received.receive)
  }

  private static func text(_ bytes: Int) -> String { String(repeating: "a", count: bytes) }

  @Test("a slow consumer receives every finalized delta in order, coalesced only between barriers")
  func orderedCoalescedDelivery() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "One.", inProgress: "two"))
    await PreviewWait.within("the consumer inside the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    // Queued behind the stuck consumer.
    handle.publish(.update(finalized: " Two.", inProgress: "three"))
    handle.publish(.update(finalized: " Three.", inProgress: "four"))
    handle.publish(.discontinuity)
    handle.publish(.update(finalized: "", inProgress: "five"))
    handle.publish(.update(finalized: " Five.", inProgress: ""))
    handle.publish(.discontinuity)
    received.release()
    await PreviewWait.within("the end", onExpiry: received.release) { await handle.end() }
    handle.publish(.update(finalized: " Late.", inProgress: ""))
    #expect(
      received.all == [
        .update(finalized: "One.", inProgress: "two"),
        .update(finalized: " Two. Three.", inProgress: "four"),
        .discontinuity,
        .update(finalized: " Five.", inProgress: ""),
        .discontinuity,
        .ended(.requested),
      ])
  }

  @Test("requested end delivers every queued final before its one terminal")
  func endDrainsBeforeTerminal() async throws {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "A.", inProgress: ""))
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    handle.publish(.discontinuity)
    handle.publish(.update(finalized: " B.", inProgress: ""))
    // What had been delivered when end() returned: an ordering record.
    let atReturn = Task { () -> [LiveWordsEvent] in
      await handle.end()
      return received.all
    }
    received.release()
    let seen = try await PreviewWait.value("the end", onExpiry: received.release) {
      await atReturn.value
    }
    let expected: [LiveWordsEvent] = [
      .update(finalized: "A.", inProgress: ""), .discontinuity,
      .update(finalized: " B.", inProgress: ""), .ended(.requested),
    ]
    #expect(seen == expected, "end() returned only after the terminal")
    await PreviewWait.within("a second end") { await handle.end() }
    #expect(received.all == expected, "exactly one terminal")
  }

  @Test("the budget admits up to 64 KB including the delivery in flight, then refuses whole")
  func budgetBoundary() async throws {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "x", inProgress: ""))  // in flight: 64 + 1
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    let inFlight = LiveWordsQueue.entryCost + 1
    let fits = LiveWordsQueue.budget - inFlight - LiveWordsQueue.entryCost
    let big = Self.text(fits)
    handle.publish(.update(finalized: big, inProgress: ""))
    // One more byte of anything is refused; a barrier costs 64.
    handle.publish(.discontinuity)
    handle.publish(.update(finalized: "never", inProgress: ""))
    received.release()
    await PreviewWait.within("the backlog terminal", onExpiry: received.release) {
      await received.until(3)
    }
    #expect(
      received.all == [
        .update(finalized: "x", inProgress: ""), .update(finalized: big, inProgress: ""),
        .ended(.failed("backlog")),
      ])
    await PreviewWait.within("the end") { await handle.end() }
    #expect(received.all.count == 3, "end() after the backlog keeps that one terminal")
  }

  @Test("queued finals merge with the assembler's spacing, never running words together")
  func coalescedFinalsKeepTheirSpace() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "First.", inProgress: ""))  // held in flight
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    handle.publish(.update(finalized: "Hello world.", inProgress: "x"))
    handle.publish(.update(finalized: "How are you?", inProgress: ""))
    received.release()
    await PreviewWait.within("the end", onExpiry: received.release) { await handle.end() }
    #expect(
      Array(received.all.prefix(2)) == [
        .update(finalized: "First.", inProgress: ""),
        .update(finalized: "Hello world. How are you?", inProgress: ""),
      ])
  }

  @Test("an oversized final is refused whole: accepted finals drain, then one backlog failure")
  func oversizedFinalRefusedWhole() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "Kept.", inProgress: ""))
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    handle.publish(.update(finalized: " Also kept.", inProgress: "x"))
    handle.publish(.update(finalized: Self.text(LiveWordsQueue.budget), inProgress: ""))
    handle.publish(.update(finalized: " After.", inProgress: ""))
    received.release()
    await PreviewWait.within("the end", onExpiry: received.release) { await handle.end() }
    #expect(
      received.all == [
        .update(finalized: "Kept.", inProgress: ""),
        .update(finalized: " Also kept.", inProgress: "x"),
        .ended(.failed("backlog")),
      ], "nothing of the oversized final, nothing after it")
  }

  @Test("alternating barriers and empty updates are charged and cannot grow without bound")
  func barriersAreCharged() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.discontinuity)  // in flight: 64
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    let room = (LiveWordsQueue.budget - LiveWordsQueue.entryCost) / LiveWordsQueue.entryCost
    for i in 0..<(room + 50) {
      handle.publish(i.isMultiple(of: 2) ? .update(finalized: "", inProgress: "") : .discontinuity)
    }
    received.release()
    await PreviewWait.within("the end", onExpiry: received.release) { await handle.end() }
    let all = received.all
    #expect(all.count == 1 + room + 1, "the first, exactly the entries that fit, one terminal")
    #expect(all.last == .ended(.failed("backlog")))
    #expect(all.filter { if case .ended = $0 { true } else { false } }.count == 1)
  }

  @Test("the retained-audio ceiling ends the session with a failure; a later end keeps it")
  func ceilingReachesTheOwner() async {
    let received = Received()
    let handle = Self.handle(received)
    let session = IdleSession()
    await PreviewWait.within("the attach") { await handle.attach(session) }
    handle.publish(.update(finalized: "Before.", inProgress: ""))
    let overCap = [Float](repeating: 0, count: TranscribeCppPreviewSession.maxRetainedSamples + 1)
    await PreviewWait.within("the capping feed") { await handle.feed(overCap) }
    await PreviewWait.within("the ceiling terminal") { await received.until(2) }
    handle.publish(.update(finalized: " After.", inProgress: ""))
    await PreviewWait.within("the end") { await handle.end() }
    #expect(
      received.all == [.update(finalized: "Before.", inProgress: ""), .ended(.failed("ceiling"))])
    #expect(session.cancelCount == 1, "decoding stopped once")
  }

  @Test("backlog, ceiling and end racing still deliver exactly one terminal and one cleanup")
  func racingTerminalsDeliverOne() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    let session = IdleSession()
    await PreviewWait.within("the attach", onExpiry: received.release) { await handle.attach(session) }
    handle.publish(.update(finalized: "First.", inProgress: ""))
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    let overCap = [Float](repeating: 0, count: TranscribeCppPreviewSession.maxRetainedSamples + 1)
    async let backlog: Void = handle.publish(
      .update(finalized: Self.text(LiveWordsQueue.budget), inProgress: ""))
    async let ceiling: Void = handle.feed(overCap)
    let ends = (0..<3).map { _ in Task { await handle.end() } }
    _ = await (backlog, ceiling)
    received.release()
    await PreviewWait.within("every end", onExpiry: received.release) {
      for end in ends { await end.value }
    }
    let terminals = received.all.filter { if case .ended = $0 { true } else { false } }
    #expect(terminals.count == 1, "one terminal: \(received.all)")
    #expect(received.all.first == .update(finalized: "First.", inProgress: ""))
    #expect(session.cancelCount == 1, "one physical cleanup")
  }

  @Test("end() during a start waits for the start, then cancels, then sends the terminal")
  func endDuringStart() async {
    let received = Received()
    let teardownStarted = PreviewWait.Once()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onEvent: received.receive,
      onTeardownStarted: { teardownStarted.fulfil(true) })
    let session = GatedStart()
    let attaching = Task { await handle.attach(session) }
    await PreviewWait.within("the start's entry", onExpiry: session.open) {
      _ = await session.entered.value()
    }
    let ending = Task { await handle.end() }
    await PreviewWait.within("teardown's entry", onExpiry: session.open) {
      _ = await teardownStarted.value()
    }
    #expect(session.log == ["start entered"], "no cancel while the start is held")
    #expect(received.all.isEmpty, "no terminal before decoding stopped")
    session.open()
    await PreviewWait.within("attach and end", onExpiry: session.open) {
      await attaching.value
      await ending.value
    }
    #expect(session.log == ["start entered", "start returned", "cancel"])
    #expect(received.all == [.ended(.requested)])
  }

  @Test("an opening that never reached its owner delivers nothing and releases its consumer")
  func discardDeliversNothing() async {
    let received = Received()
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "Unseen.", inProgress: ""))
    // discard() returns only after the queue's consumer exited, so no event can follow.
    await PreviewWait.within("the discard") { await handle.discard() }
    let afterDiscard = received.all
    handle.publish(.update(finalized: "Late.", inProgress: ""))
    await PreviewWait.within("an end after it") { await handle.end() }
    #expect(!afterDiscard.contains { if case .ended = $0 { true } else { false } })
    #expect(received.all == afterDiscard, "nothing after the discard, not even a terminal")
  }

  @Test("an update that would coalesce past the budget is refused and the queued one stays intact")
  func oversizedCoalescingRefused() async {
    let received = Received(holdFirst: true)
    let handle = Self.handle(received)
    handle.publish(.update(finalized: "x", inProgress: ""))
    await PreviewWait.within("the first delivery", onExpiry: received.release) {
      await received.until(1)
    }
    // Queued tail an oversized update would merge into.
    handle.publish(.update(finalized: " Queued.", inProgress: "held"))
    handle.publish(.update(finalized: Self.text(LiveWordsQueue.budget), inProgress: "y"))
    received.release()
    await PreviewWait.within("the end", onExpiry: received.release) { await handle.end() }
    #expect(
      received.all == [
        .update(finalized: "x", inProgress: ""),
        .update(finalized: " Queued.", inProgress: "held"),
        .ended(.failed("backlog")),
      ], "the queued update is delivered exactly as queued")
  }

  @Test("publications after end() began are refused and cannot turn the stop into a backlog")
  func publicationAfterEndRefused() async {
    let received = Received()
    let teardownStarted = PreviewWait.Once()
    let handle = TranscribeCppPreviewSession(
      lookups: nil, onEvent: received.receive,
      onTeardownStarted: { teardownStarted.fulfil(true) })
    let session = GatedStart()
    let attaching = Task { await handle.attach(session) }
    await PreviewWait.within("the start's entry", onExpiry: session.open) {
      _ = await session.entered.value()
    }
    handle.publish(.update(finalized: "Accepted.", inProgress: ""))
    let ending = Task { await handle.end() }
    // Cleanup is held behind the start: the stop has begun, decoding has not stopped yet.
    await PreviewWait.within("teardown's entry", onExpiry: session.open) {
      _ = await teardownStarted.value()
    }
    handle.publish(.update(finalized: " Late.", inProgress: ""))
    handle.publish(.update(finalized: Self.text(LiveWordsQueue.budget), inProgress: ""))
    session.open()
    await PreviewWait.within("attach and end", onExpiry: session.open) {
      await attaching.value
      await ending.value
    }
    #expect(
      received.all == [.update(finalized: "Accepted.", inProgress: ""), .ended(.requested)])
  }

  /// `start` signals entry and holds until `open()`; every signal comes from the subject.
  final class GatedStart: WhisperIncrementalSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen = false
    let entered = PreviewWait.Once()
    var log: [String] { lock.withLock { _log } }
    @Sendable func open() {
      let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        isOpen = true
        defer { gate = nil }
        return gate
      }
      waiting?.resume()
    }
    func start(
      audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
    ) async {
      lock.withLock { _log.append("start entered") }
      entered.fulfil(true)
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if isOpen { return true }
          gate = c
          return false
        }
        if now { c.resume() }
      }
      lock.withLock { _log.append("start returned") }
    }
    func noteStopRequested() async {}
    func finalize(finalSamples: [Float], speechSegments: [SpeechSegment]) async
      -> IncrementalResult
    {
      fatalError("the preview never finalizes — it cancels")
    }
    func cancel() async { lock.withLock { _log.append("cancel") } }
  }
}
