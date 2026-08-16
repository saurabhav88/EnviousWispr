import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #2108 — what the preview session handle delivers, and how big it can get.
@Suite struct WhisperPreviewSessionHandleTests {

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
    let handle = WhisperPreviewSessionHandle(
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
    await handle.end()

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
    let handle = WhisperPreviewSessionHandle(
      lookups: nil, onText: { box.delivered.append($0) })

    handle.enqueue("")
    handle.enqueue("real words")
    await waitForDelivery(box)
    await handle.end()

    // CONTROL FIRST. Without it this test passes when nothing is delivered at
    // all, which is exactly how it passed before the delivery wait was fixed.
    #expect(
      box.delivered.contains("real words"),
      "control: a real hypothesis must arrive, or the assertion below is vacuous")
    #expect(!box.delivered.contains(""), "an empty string must never reach the display")
  }

  /// `end()` is idempotent AND awaitable: a second caller waits for the same
  /// teardown rather than returning early. An early return would let the
  /// recognizer open a new decode loop over the shared WhisperKit instance while
  /// the old session's non-cancellable transcribe was still running — the
  /// decoder-state corruption `WhisperKitStreamingSession.cancel()` documents.
  @Test("end is safe and complete when called twice, from two callers")
  func endIsIdempotentAndAwaitable() async {
    let box = Box()
    let handle = WhisperPreviewSessionHandle(
      lookups: nil, onText: { box.delivered.append($0) })

    async let first: Void = handle.end()
    async let second: Void = handle.end()
    _ = await (first, second)

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
  /// for the real one sitting inside a non-cancellable WhisperKit transcribe.
  ///
  /// Held through `WhisperKitIncrementalSession` rather than the concrete type,
  /// which is the only reason a teardown that must WAIT can be observed at all.
  private final class BlockingSession: WhisperKitIncrementalSession, @unchecked Sendable {
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
  /// decode loop begins on the same cached WhisperKit instance while the old
  /// transcribe is still in it. That is the decoder-state corruption the whole
  /// turnover design exists to prevent, reached through a path that bypasses it.
  ///
  /// Mutation control: awaiting the cancel inline in `endDecoding` — the shape
  /// this replaced — makes the mid-test assertion red, because `end()` then
  /// returns while the cancel is still blocked.
  @Test("end() waits for a cap-triggered cancel that is still running")
  func cappedDecodeStopIsJoinable() async {
    let box = Box()
    let handle = WhisperPreviewSessionHandle(
      lookups: nil, onText: { box.delivered.append($0) })
    let session = BlockingSession()
    await handle.attach(session)

    // One feed over the cap. The samples are never retained — the guard caps
    // before the append — so this array is transient.
    let overCap = [Float](
      repeating: 0, count: WhisperPreviewSessionHandle.maxRetainedSamples + 1)
    async let fed: Void = handle.feed(overCap)

    // CONTROL: the cap really fired and the cancel really started. Without this
    // the wait below would pass on a run where nothing was ever cancelled.
    for _ in 0..<500 where !session.cancelEntered {
      try? await Task.sleep(for: .milliseconds(2))  // deadline-fallback: bounded poll
    }
    #expect(session.cancelEntered, "control: the cap must have started a cancel")

    let ended = Flag()
    async let endReturned: Void = {
      await handle.end()
      ended.set()
    }()

    // deadline-fallback: give an incorrect early return a real chance to land.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(
      !ended.isSet,
      "end() returned while the capped session's decode was still stopping")

    session.releaseCancel()
    _ = await (fed, endReturned)
    #expect(ended.isSet, "end() must complete once the cancel finishes")
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
    #expect(counter.done == 25)
  }
}
