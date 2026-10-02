import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit

/// #3338 PR-4 chunk 4: the learn hold keeps a pasted take's audio for at most the plan's
/// lifetime and then lets go of it. When these fail, a recording stays in memory longer
/// than we tell users, more than two takes pile up, or a learn re-check reads audio
/// after it should have stopped.
///
/// Time is the watcher's fake scheduler (`PastedRegionFakeScheduler`); nothing waits 60
/// or 75 real seconds. Drain margins here are labelled FIXTURE values, not the
/// qualified production margin (which needs a measured decoder drain).
@MainActor
@Suite("Learn audio hold (#3338)", .tags(.productOutcome))
struct LearnAudioHoldTests {

  /// FIXTURE drain margin for these tests only.
  private static let fixtureMarginMs = 5_000

  private final class Window: LearnPreparedWindowHandle {}

  private func record(_ id: String, window: Window? = nil) -> LearnTakeAudio {
    LearnTakeAudio(
      takeID: id, samples: [0.1, 0.2, 0.3], decodePath: .conditionedBatch,
      sampleOrigin: .kernelASRInput,
      decodeLanguage: nil, rawText: "text", wordTimings: nil,
      preparedWindows: window.map { [$0] } ?? [])!
  }

  private func hold(margin: Int? = fixtureMarginMs) -> (LearnAudioHold, PastedRegionFakeScheduler) {
    let s = PastedRegionFakeScheduler()
    return (LearnAudioHold(scheduler: s, qualifiedDrainMarginMs: margin), s)
  }

  // MARK: Deadlines

  @Test("a take never marked pasted expires 75 s after retain")
  func unpastedExpiry() {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    weak var storage = h.storageForTesting(takeID: "a")
    s.advance(ms: 74_999)
    #expect(h.heldTakeIDsForTesting == ["a"])
    s.advance(ms: 1)
    #expect(h.heldTakeIDsForTesting.isEmpty)
    #expect(storage == nil)
  }

  @Test("pasted: expiry is the earlier of 75 s after retain and 60 s after paste")
  func bothArms() {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    s.advance(ms: 10_000)
    h.markPasted(takeID: "a", atMs: s.nowMs)  // 60 s arm: 70_000
    h.retain(takeID: "b", record: record("b"))  // retained at 10_000
    s.advance(ms: 20_000)
    h.markPasted(takeID: "b", atMs: s.nowMs)  // 75 s arm 85_000 < 60 s arm 90_000
    s.advance(ms: 39_999)  // now 69_999
    #expect(h.heldTakeIDsForTesting == ["a", "b"])
    s.advance(ms: 1)  // 70_000
    #expect(h.heldTakeIDsForTesting == ["b"])
    s.advance(ms: 14_999)  // 84_999
    #expect(h.heldTakeIDsForTesting == ["b"])
    s.advance(ms: 1)  // 85_000
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  @Test("a second paste mark or retain never extends a take's life")
  func duplicatesDoNotExtend() {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    s.advance(ms: 30_000)
    h.markPasted(takeID: "a", atMs: s.nowMs)
    h.retain(takeID: "a", record: record("a"))
    s.advance(ms: 30_000)  // 60_000
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  @Test("a mismatched take id or an unknown take is ignored")
  func mismatched() {
    let (h, _) = hold()
    h.retain(takeID: "a", record: record("b"))
    #expect(h.heldTakeIDsForTesting.isEmpty)
    h.markPasted(takeID: "zzz", atMs: 0)
    h.discard(takeID: "zzz")
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  @Test("a late callback after a clock jump still applies the absolute deadline")
  func clockJump() async {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    s.jump(ms: 80_000)  // nothing fired yet
    #expect(
      await h.lease(takeID: "a") == nil, "past expiry: no lease even before the callback runs")
    s.advance(ms: 0)
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  @Test("a stale callback from a discarded take never touches its replacement")
  func staleCallback() {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    s.advance(ms: 50_000)
    h.discard(takeID: "a")
    h.retain(takeID: "a", record: record("a"))  // retained at 50_000: expires at 125_000
    s.advance(ms: 25_000)  // 75_000: the old take's expiry
    #expect(h.heldTakeIDsForTesting == ["a"])
    s.advance(ms: 50_000)
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  // MARK: Leases

  @Test("leases only for pasted takes before the cutoff (expiry minus the drain margin)")
  func leaseCutoff() async throws {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    #expect(await h.lease(takeID: "a") == nil, "not pasted yet")
    h.markPasted(takeID: "a", atMs: 0)  // expiry 60_000, cutoff 55_000
    s.advance(ms: 54_999)
    let lease = try #require(await h.lease(takeID: "a"))
    #expect(await lease.read() != nil)
    s.advance(ms: 1)  // cutoff
    #expect(await h.lease(takeID: "a") == nil)
    #expect(await lease.isCancelled)
    #expect(await lease.read() == nil)
  }

  @Test("no qualified drain margin: no lease is ever granted, expiry still runs")
  func unqualified() async {
    let (h, s) = hold(margin: nil)
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    #expect(await h.lease(takeID: "a") == nil)
    s.advance(ms: 60_000)
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  @Test("observation end stops new leases; an existing lease keeps reading until the cutoff")
  func observationEnd() async throws {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    h.observationEnded(takeID: "a")
    #expect(await h.lease(takeID: "a") == nil)
    s.advance(ms: 30_000)
    #expect(await lease.read() != nil)
    s.advance(ms: 25_000)  // cutoff
    #expect(await lease.read() == nil)
  }

  @Test("end is idempotent, stops reads and never signals cancellation afterwards")
  func endIdempotent() async throws {
    let (h, _) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    let signals = SignalCounter()
    await lease.onCancel { signals.bump() }
    await lease.end()
    await lease.end()
    #expect(await lease.read() == nil)
    h.discard(takeID: "a")
    await lease.onCancel { signals.bump() }
    #expect(signals.count == 0)
  }

  @Test(
    "discard and cancelAll cancel leases and signal registered work; late registration signals at once"
  )
  func cancellationSignals() async throws {
    let (h, _) = hold()
    for id in ["a", "b"] {
      h.retain(takeID: id, record: record(id))
      h.markPasted(takeID: id, atMs: 0)
    }
    let la = try #require(await h.lease(takeID: "a"))
    let lb = try #require(await h.lease(takeID: "b"))
    let signals = SignalCounter()
    await la.onCancel { signals.bump() }
    h.discard(takeID: "a")
    #expect(signals.count == 1)
    #expect(await la.read() == nil)
    await la.onCancel { signals.bump() }
    #expect(signals.count == 2, "registration after cancellation signals immediately")
    await lb.onCancel { signals.bump() }
    h.cancelAll()
    #expect(signals.count == 3)
    #expect(h.heldTakeIDsForTesting.isEmpty)
  }

  // MARK: Capacity

  @Test("a third take evicts the oldest unleased take")
  func thirdEvictsOldestUnleased() {
    let (h, _) = hold()
    for id in ["a", "b", "c"] { h.retain(takeID: id, record: record(id)) }
    #expect(h.heldTakeIDsForTesting == ["b", "c"])
    #expect(h.slotsInUseForTesting == 2)
  }

  @Test("with both takes leased a third is refused; a draining removed take still uses its slot")
  func capacityWithLeases() async throws {
    let (h, _) = hold()
    for id in ["a", "b"] {
      h.retain(takeID: id, record: record(id))
      h.markPasted(takeID: id, atMs: 0)
    }
    let la = try #require(await h.lease(takeID: "a"))
    let lb = try #require(await h.lease(takeID: "b"))
    h.retain(takeID: "c", record: record("c"))
    #expect(h.heldTakeIDsForTesting == ["a", "b"], "both leased: the third is refused")
    h.discard(takeID: "a")  // removed, but its lease has not ended: still draining
    h.retain(takeID: "d", record: record("d"))
    #expect(h.heldTakeIDsForTesting == ["b"], "the draining take still holds a slot")
    await la.end()
    h.retain(takeID: "e", record: record("e"))
    #expect(h.heldTakeIDsForTesting == ["b", "e"])
    await lb.end()
  }

  // MARK: Release (weak references)

  @Test("1. ownership survives while legitimately leased, then releases at expiry")
  func releaseAfterLease() async throws {
    let (h, s) = hold()
    weak var window: Window?
    weak var storage: LearnAudioHold.Storage?
    do {
      let w = Window()
      window = w
      h.retain(takeID: "a", record: record("a", window: w))
    }
    storage = h.storageForTesting(takeID: "a")
    h.markPasted(takeID: "a", atMs: 0)
    var lease = try #require(await h.lease(takeID: "a"))
    s.advance(ms: 30_000)
    #expect(storage != nil)
    #expect(window != nil)
    await lease.end()
    lease = try #require(await h.lease(takeID: "a"))  // a second borrower
    await lease.end()
    s.advance(ms: 30_000)  // expiry
    #expect(storage == nil)
    #expect(window == nil)
    #expect(h.undrainedAtExpiry == 0)
  }

  @Test(
    "2. a cancelled consumer releases its own record and window copies after it signals completion")
  func cancelledConsumerReleases() async throws {
    let (h, _) = hold()
    weak var window: Window?
    do {
      let w = Window()
      window = w
      h.retain(takeID: "a", record: record("a", window: w))
    }
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    let consumer = Consumer()
    await consumer.start(lease)
    #expect(window != nil, "the consumer holds a copy while it works")
    h.discard(takeID: "a")
    try #require(await consumer.finished(), "the consumer was never signalled")
    await lease.end()
    #expect(window == nil, "after its completion signal the consumer kept no copy")
  }

  @Test("3. every tracked owner is released by absolute expiry when the drain fits the margin")
  func releasedByExpiry() async throws {
    let (h, s) = hold()
    weak var window: Window?
    weak var storage: LearnAudioHold.Storage?
    do {
      let w = Window()
      window = w
      h.retain(takeID: "a", record: record("a", window: w))
    }
    storage = h.storageForTesting(takeID: "a")
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    let consumer = Consumer()
    await consumer.start(lease)
    s.advance(ms: 55_000)  // cutoff: the lease is cancelled, the consumer is signalled
    // The controlled drain completes inside the margin.
    try #require(await consumer.finished(), "the cutoff never signalled the consumer")
    await lease.end()
    s.advance(ms: 5_000)  // absolute expiry
    #expect(h.heldTakeIDsForTesting.isEmpty)
    #expect(storage == nil)
    #expect(window == nil)
    #expect(h.undrainedAtExpiry == 0)
  }

  @Test("the consumer's completion wait reports false when it is never signalled")
  func consumerTimeoutControl() async throws {
    let (h, _) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    let consumer = Consumer()
    await consumer.start(lease)
    #expect(await consumer.finished(timeout: .milliseconds(50)) == false)
    await lease.end()
  }

  @Test("a lease still out at absolute expiry is detected, not hidden")
  func undrainedDetected() async throws {
    let (h, s) = hold()
    h.retain(takeID: "a", record: record("a"))
    h.markPasted(takeID: "a", atMs: 0)
    let lease = try #require(await h.lease(takeID: "a"))
    s.advance(ms: 60_000)
    #expect(h.undrainedAtExpiry == 1)
    await lease.end()
    #expect(h.slotsInUseForTesting == 0)
  }
}

/// Counts cancellation signals from a `@Sendable` handler.
private final class SignalCounter: Sendable {
  private let value = OSAllocatedUnfairLock(initialState: 0)
  var count: Int { value.withLock { $0 } }
  func bump() { value.withLock { $0 += 1 } }
}

/// A controlled borrower: copies the record, keeps it until cancelled, then drops it
/// and signals completion.
@MainActor
private final class Consumer {
  private var copy: LearnTakeAudio?
  private var done = false
  private var waiter: CheckedContinuation<Bool, Never>?

  func start(_ lease: any LearnAudioLease) async {
    copy = await lease.read()
    let gate = AsyncStream<Void>.makeStream()
    Task { @MainActor [weak self] in
      for await _ in gate.stream {}
      self?.copy = nil
      self?.complete()
    }
    await lease.onCancel { gate.continuation.finish() }
  }

  private func complete() {
    done = true
    waiter?.resume(returning: true)
    waiter = nil
  }

  /// `true` once the consumer dropped its copy; `false` if the timeout passes first.
  func finished(timeout: Duration = .seconds(10)) async -> Bool {
    if done { return true }
    let deadline = Task { @MainActor [weak self] in
      do {
        // deadline-fallback: report a consumer that was never signalled.
        try await Task.sleep(for: timeout)
      } catch { return }
      guard let self, let waiter = self.waiter else { return }
      self.waiter = nil
      waiter.resume(returning: false)
    }
    defer { deadline.cancel() }
    return await withCheckedContinuation { waiter = $0 }
  }
}
