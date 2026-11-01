import Foundation
import Testing
import os

@testable import EnviousWisprAppKit

/// #3973 plan §3.3: the per-track pump between the meeting recorder's capture thread and a
/// live-words session. When one of these fails, live words skip or repeat audio, a slow engine
/// makes the app's memory grow, or a stuck engine holds up the recording's capture thread.
///
/// Expected samples are built from arithmetic (sample index or block number), never read back
/// through the pump.
@Suite("Meeting live-words pump (#3973)", .tags(.productOutcome))
struct MeetingLiveWordsPumpTests {

  private static let bank = MeetingLiveAudioPump.bankSamples
  private static let queued = MeetingLiveAudioPump.queuedBanks

  /// Samples whose values are their own positions (exact in Float below 2^24).
  private static func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

  /// Blocks of 1,600 samples, each filled with its block number.
  private static func blocks(_ numbers: Range<Int>) -> [[Float]] {
    numbers.map { [Float](repeating: Float($0), count: 1_600) }
  }

  private static func admit(_ pump: MeetingLiveAudioPump, _ samples: [Float]) {
    samples.withUnsafeBufferPointer { pump.admit($0) }
  }

  private static func drain(_ pump: MeetingLiveAudioPump) -> [[Float]] {
    var chunks: [[Float]] = []
    while let chunk = pump.takeChunk() { chunks.append(chunk) }
    return chunks
  }

  /// Waits for a subject's semaphore signal, bounded.
  private static func signalled(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success  // deadline-fallback: around the signal
  }

  /// Runs `work` on another thread and reports whether it finished within the bound.
  private static func finishes(_ work: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      work()
      done.signal()
    }
    return signalled(done)
  }

  /// Chunks a fake session received, with waits on them. `hold` parks every feed after recording
  /// its chunk, until `open()`.
  final class Fed: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var chunks: [[Float]] = []
    private var waiters: [(([[Float]]) -> Bool, CheckedContinuation<Void, Never>)] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var holding: Bool
    init(hold: Bool = false) { holding = hold }
    var all: [[Float]] { lock.withLock { chunks } }

    @Sendable func feed(_ chunk: [Float]) async {
      let (ready, hold) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
        chunks.append(chunk)
        let met = waiters.filter { $0.0(chunks) }.map(\.1)
        waiters.removeAll { $0.0(chunks) }
        return (met, holding)
      }
      for waiter in ready { waiter.resume() }
      guard hold else { return }
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if !holding { return true }
          parked.append(c)
          return false
        }
        if now { c.resume() }
      }
    }

    /// Lets every held feed return (idempotent; every wait's expiry cleanup).
    @Sendable func open() {
      let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        holding = false
        defer { parked = [] }
        return parked
      }
      for c in released { c.resume() }
    }

    func until(_ condition: @escaping ([[Float]]) -> Bool) async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if condition(chunks) { return true }
          waiters.append((condition, c))
          return false
        }
        if now { c.resume() }
      }
    }
  }

  @Test("samples come out in order and exactly, across a bank rollover and a partial bank")
  func orderAcrossRollover() {
    let pump = MeetingLiveAudioPump()
    Self.admit(pump, Self.ramp(0..<20_000))
    Self.admit(pump, Self.ramp(20_000..<40_000))
    Self.admit(pump, Self.ramp(40_000..<45_600))
    let chunks = Self.drain(pump)
    #expect(chunks.map(\.count) == [Self.bank, 45_600 - Self.bank], "one full bank, one partial")
    #expect(chunks.flatMap { $0 } == Self.ramp(0..<45_600))
    #expect(pump.accounting == .init(admitted: 45_600, evicted: 0, refused: 0, delivered: 45_600))
  }

  @Test("a short chunk is delivered at once from the partial bank, not held for a full one")
  func partialBankDelivered() {
    let pump = MeetingLiveAudioPump()
    Self.admit(pump, Self.ramp(0..<1_600))
    #expect(pump.takeChunk() == Self.ramp(0..<1_600))
    #expect(pump.takeChunk() == nil, "nothing left, nothing invented")
    Self.admit(pump, Self.ramp(1_600..<3_200))
    #expect(pump.takeChunk() == Self.ramp(1_600..<3_200), "the next partial follows on")
  }

  @Test("the ring and the free list wrap around many times without losing or reordering audio")
  func ringWraparound() {
    let pump = MeetingLiveAudioPump()
    var next = 0
    var out: [Float] = []
    for round in 0..<(Self.queued * 5) {
      // Two banks in, one out, then the rest out: the head moves through every slot repeatedly.
      let size = Self.bank * 2 + (round % 3) * 100
      Self.admit(pump, Self.ramp(next..<(next + size)))
      next += size
      if let chunk = pump.takeChunk() { out += chunk }
      out += Self.drain(pump).flatMap { $0 }
    }
    #expect(out == Self.ramp(0..<next))
    #expect(pump.accounting.dropped == 0)
  }

  @Test("before a session opens the pump keeps the newest 27.2 s of full banks and counts the rest")
  func newestAudioRetainedBeforeSession() {
    let pump = MeetingLiveAudioPump()
    // 400 blocks of 0.1 s = 25 full banks; the ring holds 17, so the oldest 8 banks are evicted.
    for block in Self.blocks(0..<400) { Self.admit(pump, block) }
    let evictedBlocks = (25 - Self.queued) * 16
    let delivered = Self.drain(pump).flatMap { $0 }
    #expect(
      delivered == Self.blocks(evictedBlocks..<400).flatMap { $0 }, "the newest blocks, in order")
    #expect(
      pump.accounting
        == .init(
          admitted: 400 * 1_600, evicted: evictedBlocks * 1_600, refused: 0,
          delivered: (400 - evictedBlocks) * 1_600))
  }

  @Test("retained audio never exceeds 28.8 s however long a session takes to open")
  func retainedAudioIsBounded() {
    let pump = MeetingLiveAudioPump()
    for block in Self.blocks(0..<1_203) { Self.admit(pump, block) }  // just over 2 minutes
    let a = pump.accounting
    let retained = a.admitted - a.evicted - a.delivered
    #expect(retained == Self.queued * Self.bank + 3 * 1_600, "17 full banks plus the partial one")
    #expect(retained <= 480_000, "inside the plan's 30 s window")
  }

  #if DEBUG
  @Test("a busy pump lock never holds up the capture thread: the chunk is dropped and counted")
  func contendedLockDrops() {
    let pump = MeetingLiveAudioPump()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { pump.holdLockForTests(entered: entered, release: release) }
    let held = Self.signalled(entered)
    #expect(held, "the holder took the lock")
    let returned = Self.finishes { Self.admit(pump, Self.ramp(0..<800)) }
    release.signal()  // only now does the holder let go
    #expect(returned, "admit returned while the lock was still held")
    #expect(pump.accounting == .init(admitted: 0, evicted: 0, refused: 800, delivered: 0))
    Self.admit(pump, Self.ramp(800..<1_600))
    #expect(pump.takeChunk() == Self.ramp(800..<1_600), "admission resumes after the holder")
  }

  #endif

  @Test("the bank the consumer is copying is never recycled, however much audio arrives")
  func consumerBankNeverRecycled() {
    let gate = CopyGate()
    defer { gate.release() }
    let pump = MeetingLiveAudioPump(consumerOwnsBank: gate.hold)
    Self.admit(pump, [Float](repeating: 7, count: Self.bank))  // one full queued bank
    let result = OSAllocatedUnfairLock<[Float]?>(initialState: nil)
    let taking = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let chunk = pump.takeChunk()
      result.withLock { $0 = chunk }
      taking.signal()
    }
    let owns = Self.signalled(gate.owned)
    #expect(owns, "the consumer owns the bank")
    // 30 more banks while it holds that one: the ring fills and evicts again and again.
    let flooded = Self.finishes {
      for _ in 0..<30 { Self.admit(pump, [Float](repeating: 9, count: Self.bank)) }
    }
    gate.release()
    #expect(flooded)
    #expect(Self.signalled(taking))
    #expect(!gate.didExpire)
    #expect(result.withLock { $0 } == [Float](repeating: 7, count: Self.bank), "never overwritten")
    #expect(pump.accounting.evicted == (30 - Self.queued) * Self.bank)
  }

  @Test("a stuck feed never stops admission, eviction or retirement, and keeps its own array")
  func stuckFeed() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, Self.ramp(0..<Self.bank))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    // The consumer is parked inside feed; 30 more banks still go in, evicting the oldest.
    let admitted = Self.finishes {
      for _ in 0..<30 { Self.admit(pump, [Float](repeating: 5, count: Self.bank)) }
    }
    #expect(admitted)
    #expect(pump.accounting.evicted == (30 - Self.queued) * Self.bank)
    // Retirement returns while that feed is still held; later audio is refused.
    let consumer = pump.retire()
    Self.admit(pump, Self.ramp(0..<500))
    #expect(pump.accounting.refused == 500)
    fed.open()
    await PreviewWait.within("the consumer's end", onExpiry: fed.open) { await consumer?.value }
    #expect(fed.all.count == 1, "nothing fed after retirement")
    #expect(fed.all.first == Self.ramp(0..<Self.bank), "the in-flight array stayed intact")
  }

  @Test("retiring twice is safe, a retired pump starts no consumer, and its storage is released")
  func repeatedRetirementReleases() async {
    weak var weakPump: MeetingLiveAudioPump?
    let fed = Fed(hold: true)
    defer { fed.open() }
    var consumer: Task<Void, Never>?
    do {
      let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
      weakPump = pump
      #expect(pump.startConsumer(feed: fed.feed))
      #expect(!pump.startConsumer(feed: fed.feed), "one consumer at a time")
      Self.admit(pump, Self.ramp(0..<1_600))
      await PreviewWait.within("the feed", onExpiry: fed.open) { await fed.until { $0.count == 1 } }
      consumer = pump.retire()
      #expect(consumer != nil)
      #expect(pump.retire() == consumer, "a second retirement returns the same outstanding work")
      #expect(!pump.startConsumer(feed: fed.feed))
    }
    fed.open()
    await PreviewWait.within("the consumer's end", onExpiry: fed.open) { [consumer] in
      await consumer?.value
    }
    consumer = nil
    #expect(weakPump == nil, "storage released once the consumer and holders let go")
  }

  /// Holds the FIRST consumer copy (after the bank is taken, before it is copied out) until
  /// `release()`; once released it stays open, so later copies pass by signal, not by deadline.
  /// A deadline that expires is recorded and fails the test; it is never a pass.
  final class CopyGate: @unchecked Sendable {
    let owned = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private var expired = false
    var didExpire: Bool { lock.withLock { expired } }

    @Sendable func hold() {
      guard !lock.withLock({ released }) else { return }
      owned.signal()
      // deadline-fallback: released by the test; expiry is recorded as a failure below
      if resume.wait(timeout: .now() + 10) == .timedOut { lock.withLock { expired = true } }
    }

    @Sendable func release() {
      let first = lock.withLock { () -> Bool in
        defer { released = true }
        return !released
      }
      if first { resume.signal() }
    }
  }

  /// A pump whose first consumer copy waits on `gate`.
  private static func heldConsumer() -> (pump: MeetingLiveAudioPump, gate: CopyGate) {
    let gate = CopyGate()
    return (MeetingLiveAudioPump(cadence: .milliseconds(1), consumerOwnsBank: gate.hold), gate)
  }

  @Test("a consumer stopped while copying feeds nothing, and its bank reaches the next consumer")
  func stopDuringCopy() async {
    let (pump, gate) = Self.heldConsumer()
    defer { gate.release() }
    let first = Fed()
    let second = Fed()
    Self.admit(pump, Self.ramp(0..<Self.bank))  // one full queued bank
    #expect(pump.startConsumer(feed: first.feed))
    let owns = await Task.detached { Self.signalled(gate.owned) }.value
    #expect(owns, "the consumer owns the bank")
    let stopped = pump.stopConsumer()
    gate.release()
    await PreviewWait.within("the stopped consumer's end") { await stopped?.value }
    #expect(first.all.isEmpty, "no feed after the stop")
    #expect(pump.startConsumer(feed: second.feed))
    await PreviewWait.within("the next consumer's audio") { await second.until { $0.count == 1 } }
    #expect(second.all == [Self.ramp(0..<Self.bank)], "the same bank, intact")
    #expect(pump.accounting.delivered == Self.bank && pump.accounting.dropped == 0)
    #expect(!gate.didExpire, "every copy passed by release, none by deadline")
    pump.retire()
  }

  @Test("a consumer retired while copying feeds nothing and the pump delivers nothing more")
  func retireDuringCopy() async {
    let (pump, gate) = Self.heldConsumer()
    defer { gate.release() }
    let fed = Fed()
    Self.admit(pump, Self.ramp(0..<Self.bank))
    #expect(pump.startConsumer(feed: fed.feed))
    let owns = await Task.detached { Self.signalled(gate.owned) }.value
    #expect(owns)
    let consumer = pump.retire()
    gate.release()
    await PreviewWait.within("the consumer's end") { await consumer?.value }
    #expect(fed.all.isEmpty)
    #expect(pump.accounting.delivered == 0)
    #expect(pump.takeChunk() == nil)
    #expect(!gate.didExpire)
  }

  @Test("a replacement consumer is refused until the stopped one has physically exited")
  func replacementWaitsForExit() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let first = Fed(hold: true)
    defer { first.open() }
    let second = Fed()
    #expect(pump.startConsumer(feed: first.feed))
    Self.admit(pump, Self.ramp(0..<1_600))
    await PreviewWait.within("the held feed", onExpiry: first.open) {
      await first.until { $0.count == 1 }
    }
    let stopped = pump.stopConsumer()
    #expect(stopped != nil)
    #expect(pump.stopConsumer() == stopped, "repeated stops keep the outstanding work")
    #expect(!pump.startConsumer(feed: second.feed), "the old consumer is still inside feed")
    first.open()
    await PreviewWait.within("the old consumer's end") { await stopped?.value }
    #expect(pump.startConsumer(feed: second.feed), "allowed once it exited")
    Self.admit(pump, Self.ramp(1_600..<3_200))
    await PreviewWait.within("the new consumer's audio") { await second.until { $0.count == 1 } }
    #expect(second.all == [Self.ramp(1_600..<3_200)])
    #expect(first.all.count == 1)
    pump.retire()
  }

  @Test("a start racing a retirement never leaves a consumer running or feeding")
  func startRacingRetirement() async {
    for _ in 0..<100 {
      let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
      let fed = Fed()
      Self.admit(pump, Self.ramp(0..<1_600))
      async let started = Task.detached { pump.startConsumer(feed: fed.feed) }.value
      async let retired = Task.detached { pump.retire() }.value
      _ = await (started, retired)
      // Whatever the order, the pump is retired: any consumer it had is stopping, none can start.
      let outstanding = pump.retire()
      await PreviewWait.within("any consumer's end") { await outstanding?.value }
      #expect(pump.retire() == nil, "no consumer survives")
      #expect(!pump.startConsumer(feed: fed.feed), "a retired pump starts nothing")
      let afterRetire = fed.all.count
      Self.admit(pump, Self.ramp(0..<1_600))
      #expect(pump.takeChunk() == nil && fed.all.count == afterRetire, "nothing more is fed")
    }
  }

  @Test("with producers, a consumer and readers all racing, every offered sample is accounted")
  func accountingUnderConcurrency() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let fed = Fed()
    #expect(pump.startConsumer(feed: fed.feed))
    let producers = 4
    let chunksEach = 400
    let chunk = 320
    // Producers and readers race on other threads; drops from a busy lock are expected here.
    await withTaskGroup(of: Void.self) { group in
      for p in 0..<producers {
        group.addTask {
          let samples = [Float](repeating: Float(p), count: chunk)
          for _ in 0..<chunksEach { samples.withUnsafeBufferPointer { pump.admit($0) } }
        }
      }
      for _ in 0..<3 {
        group.addTask { for _ in 0..<500 { _ = pump.accounting } }
      }
    }
    let consumer = pump.retire()
    await PreviewWait.within("the consumer's end") { await consumer?.value }
    let a = pump.accounting
    let offered = producers * chunksEach * chunk
    #expect(a.admitted + a.refused == offered, "every offered sample admitted or refused: \(a)")
    let fedSamples = fed.all.reduce(0) { $0 + $1.count }
    #expect(a.delivered == fedSamples, "delivered is exactly what was fed")
    #expect(a.admitted >= a.delivered + a.evicted, "nothing delivered or evicted twice")
  }

  @Test("a session handoff keeps the pump and the audio buffered between sessions")
  func handoffKeepsBufferedAudio() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let first = Fed()
    let second = Fed()
    #expect(pump.startConsumer(feed: first.feed))
    Self.admit(pump, Self.ramp(0..<1_600))
    await PreviewWait.within("the first session's audio") { await first.until { $0.count == 1 } }
    let stopped = pump.stopConsumer()
    await PreviewWait.within("the first consumer's end") { await stopped?.value }
    Self.admit(pump, Self.ramp(1_600..<4_800))  // arrives between sessions
    #expect(pump.startConsumer(feed: second.feed))
    await PreviewWait.within("the second session's audio") {
      await second.until { $0.flatMap { $0 }.count == 3_200 }
    }
    #expect(first.all == [Self.ramp(0..<1_600)], "nothing reached the stopped session")
    #expect(second.all.flatMap { $0 } == Self.ramp(1_600..<4_800))
    pump.retire()
  }

  // MARK: - Seal and drain (#4248)

  @Test("a sealed pump feeds every held sample in order, queued and partial, then its consumer exits")
  func sealDrainsHeldAudio() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, Self.ramp(0..<1_600))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    // While that feed is held: two full banks and a partial bank are queued, then Stop seals.
    let held = 1_600 + 2 * Self.bank + 1_000
    Self.admit(pump, Self.ramp(1_600..<held))
    let consumer = pump.seal()
    #expect(consumer != nil)
    Self.admit(pump, Self.ramp(0..<500))
    #expect(pump.accounting.refused == 500, "a sealed pump admits nothing new")
    fed.open()
    await PreviewWait.within("the drain", onExpiry: fed.open) { await consumer?.value }
    #expect(fed.all.flatMap { $0 } == Self.ramp(0..<held), "every held sample, once, in order")
    #expect(pump.accounting.delivered == held)
    #expect(pump.accounting.dropped == 500)
  }

  @Test("a sealed pump with no consumer returns no drain, and retire still discards")
  func sealWithoutConsumerAndDiscard() async {
    let idle = MeetingLiveAudioPump(cadence: .milliseconds(1))
    Self.admit(idle, Self.ramp(0..<1_600))
    #expect(idle.seal() == nil, "nothing will feed the held audio")
    idle.retire()

    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, Self.ramp(0..<1_600))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    Self.admit(pump, Self.ramp(1_600..<4_800))
    _ = pump.seal()
    // Delete after Stop: discard wins.
    let consumer = pump.retire()
    fed.open()
    await PreviewWait.within("the consumer's end", onExpiry: fed.open) { await consumer?.value }
    #expect(fed.all == [Self.ramp(0..<1_600)], "nothing queued was fed after the discard")
  }
}
