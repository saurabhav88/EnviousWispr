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
