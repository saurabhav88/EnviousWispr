import EnviousWisprCore
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
@Suite("Meeting live-words pump (#3973)", .tags(.productOutcome, .localParallel))
struct MeetingLiveWordsPumpTests {

  private static let bank = MeetingLiveAudioPump.bankSamples
  private static let queued = MeetingLiveAudioPump.queuedBanks

  /// Samples whose values are their own positions (exact in Float below 2^24).
  private static func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

  /// Blocks of 1,600 samples, each filled with its block number.
  private static func blocks(_ numbers: Range<Int>) -> [[Float]] {
    numbers.map { [Float](repeating: Float($0), count: 1_600) }
  }

  /// One test's written timeline for one pump: its recording and the next written position,
  /// so consecutive offers are contiguous written audio unless a test says otherwise.
  final class Positions: Sendable {
    let recording = UUID()
    private let next = OSAllocatedUnfairLock(initialState: 0)

    /// A span naming `count` samples from `start` (default: the next position) in `run`.
    func span(count: Int, at start: Int? = nil, run: Int = 0) -> MeetingAudioSpan {
      let position = next.withLock { n -> Int in
        let at = start ?? n
        n = at + count
        return at
      }
      return MeetingAudioSpan(
        recording: recording, track: .callSound, run: run, startSample: position,
        sampleCount: count)!
    }
  }

  private static func admit(
    _ pump: MeetingLiveAudioPump, _ positions: Positions, _ samples: [Float],
    at start: Int? = nil, run: Int = 0
  ) {
    let span = positions.span(count: samples.count, at: start, run: run)
    samples.withUnsafeBufferPointer { pump.admit($0, span: span) }
  }

  private static func drain(_ pump: MeetingLiveAudioPump) -> [[Float]] {
    drainChunks(pump).map(\.samples)
  }

  private static func drainChunks(_ pump: MeetingLiveAudioPump) -> [MeetingLiveAudioChunk] {
    var chunks: [MeetingLiveAudioChunk] = []
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
    /// The chunks as fed, written positions included.
    var fedChunks: [MeetingLiveAudioChunk] { lock.withLock { full } }
    private var full: [MeetingLiveAudioChunk] = []

    @Sendable func feed(_ chunk: MeetingLiveAudioChunk) async {
      let (ready, hold) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
        chunks.append(chunk.samples)
        full.append(chunk)
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
    let positions = Positions()
    Self.admit(pump, positions, Self.ramp(0..<20_000))
    Self.admit(pump, positions, Self.ramp(20_000..<40_000))
    Self.admit(pump, positions, Self.ramp(40_000..<45_600))
    let chunks = Self.drain(pump)
    #expect(chunks.map(\.count) == [Self.bank, 45_600 - Self.bank], "one full bank, one partial")
    #expect(chunks.flatMap { $0 } == Self.ramp(0..<45_600))
    #expect(pump.accounting == .init(admitted: 45_600, evicted: 0, refused: 0, delivered: 45_600))
  }

  // MARK: - Written positions (#4355)

  /// A chunk's slices as (offset, start, count, run).
  private static func layout(_ chunk: MeetingLiveAudioChunk) -> [[Int]] {
    chunk.slices.map { [$0.offset, $0.span.startSample, $0.count, $0.span.run] }
  }

  @Test("a chunk split across banks keeps exact written positions: each bank's span advances by its samples")
  func spansAcrossBankSplit() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    Self.admit(pump, positions, Self.ramp(0..<20_000), at: 0)
    Self.admit(pump, positions, Self.ramp(20_000..<40_000), at: 20_000)
    Self.admit(pump, positions, Self.ramp(40_000..<45_600), at: 40_000)
    let chunks = Self.drainChunks(pump)
    #expect(chunks.map(Self.layout) == [[[0, 0, Self.bank, 0]], [[0, Self.bank, 45_600 - Self.bank, 0]]],
      "adjacent offers share one slice; the split moves the span with the samples")
  }

  @Test("a gap or a run break inside one bank starts a new slice; nothing is bridged")
  func gapsAndRunBreaksStayApart() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    Self.admit(pump, positions, Self.ramp(0..<1_600), at: 0)
    Self.admit(pump, positions, Self.ramp(1_600..<3_200), at: 3_200)  // 1,600 samples missing before it
    Self.admit(pump, positions, Self.ramp(3_200..<4_800), at: 4_800, run: 1)  // contiguous, but a new run
    let chunk = try? #require(pump.takeChunk())
    #expect(chunk?.samples == Self.ramp(0..<4_800))
    #expect(chunk.map(Self.layout) == [[0, 0, 1_600, 0], [1_600, 3_200, 1_600, 0], [3_200, 4_800, 1_600, 1]])
  }

  @Test("evicted audio takes its positions with it: the oldest delivered chunk names the oldest kept sample")
  func evictionMovesPositions() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    for (i, block) in Self.blocks(0..<400).enumerated() { Self.admit(pump, positions, block, at: i * 1_600) }
    let evictedBlocks = (25 - Self.queued) * 16
    let chunks = Self.drainChunks(pump)
    #expect(chunks.first?.slices.first?.span.startSample == evictedBlocks * 1_600)
    let spans = chunks.flatMap(\.slices).map(\.span)
    #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.endSample == $1.startSample })
    #expect(spans.last?.endSample == 400 * 1_600)
  }

  @Test("a full slice list never changes what audio is kept: later audio is stored without a position and counted")
  func sliceLimitKeepsAudio() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    let limit = MeetingLiveAudioPump.slicesPerBank
    // 1,200 non-adjacent offers of 10 samples: 12,000 samples, well inside one bank, and far
    // more than the 17 queued banks it would take if each full slice list queued a bank.
    let offers = 1_200
    for i in 0..<offers { Self.admit(pump, positions, [Float](repeating: Float(i % 50), count: 10), at: i * 20) }
    let chunks = Self.drainChunks(pump)
    #expect(chunks.map(\.samples.count) == [offers * 10], "one partial bank, every sample kept")
    #expect(chunks.first?.slices.count == limit)
    #expect(chunks.first?.slices.map(\.span.startSample) == (0..<limit).map { $0 * 20 })
    #expect(chunks.first?.slices.map(\.offset) == (0..<limit).map { $0 * 10 })
    #expect(
      pump.accounting
        == .init(
          admitted: offers * 10, evicted: 0, refused: 0, delivered: offers * 10,
          unpositioned: (offers - limit) * 10))
  }

  #if DEBUG
  @Test("a chunk refused by a busy lock leaves a gap between the slices around it, never a join")
  func refusalGapInPartialBank() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    Self.admit(pump, positions, Self.ramp(0..<1_600))  // a partial prefix, written 0..<1,600
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { pump.holdLockForTests(entered: entered, release: release) }
    #expect(Self.signalled(entered), "the holder took the lock")
    let refused = Self.finishes { Self.admit(pump, positions, Self.ramp(1_600..<2_400)) }
    release.signal()
    #expect(refused, "the middle offer returned while the lock was held")
    Self.admit(pump, positions, Self.ramp(2_400..<4_000))  // the suffix, written 2,400..<4,000
    let chunk = pump.takeChunk()
    #expect(chunk?.samples == Self.ramp(0..<1_600) + Self.ramp(2_400..<4_000))
    #expect(chunk.map(Self.layout) == [[0, 0, 1_600, 0], [1_600, 2_400, 1_600, 0]], "the missing range stays missing")
    #expect(pump.accounting.refused == 800)
  }
  #endif

  @Test("a short chunk is delivered at once from the partial bank, not held for a full one")
  func partialBankDelivered() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    Self.admit(pump, positions, Self.ramp(0..<1_600))
    #expect(pump.takeChunk()?.samples == Self.ramp(0..<1_600))
    #expect(pump.takeChunk()?.samples == nil, "nothing left, nothing invented")
    Self.admit(pump, positions, Self.ramp(1_600..<3_200))
    #expect(pump.takeChunk()?.samples == Self.ramp(1_600..<3_200), "the next partial follows on")
  }

  @Test("the ring and the free list wrap around many times without losing or reordering audio")
  func ringWraparound() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    var next = 0
    var out: [Float] = []
    for round in 0..<(Self.queued * 5) {
      // Two banks in, one out, then the rest out: the head moves through every slot repeatedly.
      let size = Self.bank * 2 + (round % 3) * 100
      Self.admit(pump, positions, Self.ramp(next..<(next + size)))
      next += size
      if let chunk = pump.takeChunk() { out += chunk.samples }
      out += Self.drain(pump).flatMap { $0 }
    }
    #expect(out == Self.ramp(0..<next))
    #expect(pump.accounting.dropped == 0)
  }

  @Test("before a session opens the pump keeps the newest 27.2 s of full banks and counts the rest")
  func newestAudioRetainedBeforeSession() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    // 400 blocks of 0.1 s = 25 full banks; the ring holds 17, so the oldest 8 banks are evicted.
    for block in Self.blocks(0..<400) { Self.admit(pump, positions, block) }
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
    let positions = Positions()
    for block in Self.blocks(0..<1_203) { Self.admit(pump, positions, block) }  // just over 2 minutes
    let a = pump.accounting
    let retained = a.admitted - a.evicted - a.delivered
    #expect(retained == Self.queued * Self.bank + 3 * 1_600, "17 full banks plus the partial one")
    #expect(retained <= 480_000, "inside the plan's 30 s window")
  }

  #if DEBUG
  @Test("a busy pump lock never holds up the capture thread: the chunk is dropped and counted")
  func contendedLockDrops() {
    let pump = MeetingLiveAudioPump()
    let positions = Positions()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { pump.holdLockForTests(entered: entered, release: release) }
    let held = Self.signalled(entered)
    #expect(held, "the holder took the lock")
    let returned = Self.finishes { Self.admit(pump, positions, Self.ramp(0..<800)) }
    release.signal()  // only now does the holder let go
    #expect(returned, "admit returned while the lock was still held")
    #expect(pump.accounting == .init(admitted: 0, evicted: 0, refused: 800, delivered: 0))
    Self.admit(pump, positions, Self.ramp(800..<1_600))
    #expect(pump.takeChunk()?.samples == Self.ramp(800..<1_600), "admission resumes after the holder")
  }

  #endif

  @Test("the bank the consumer is copying is never recycled, however much audio arrives")
  func consumerBankNeverRecycled() {
    let gate = CopyGate()
    defer { gate.release() }
    let pump = MeetingLiveAudioPump(consumerOwnsBank: gate.hold)
    let positions = Positions()
    Self.admit(pump, positions, [Float](repeating: 7, count: Self.bank))  // one full queued bank
    let result = OSAllocatedUnfairLock<[Float]?>(initialState: nil)
    let taking = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      let chunk = pump.takeChunk()
      result.withLock { $0 = chunk?.samples }
      taking.signal()
    }
    let owns = Self.signalled(gate.owned)
    #expect(owns, "the consumer owns the bank")
    // 30 more banks while it holds that one: the ring fills and evicts again and again.
    let flooded = Self.finishes {
      for _ in 0..<30 { Self.admit(pump, positions, [Float](repeating: 9, count: Self.bank)) }
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
    let positions = Positions()
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, positions, Self.ramp(0..<Self.bank))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    // The consumer is parked inside feed; 30 more banks still go in, evicting the oldest.
    let admitted = Self.finishes {
      for _ in 0..<30 { Self.admit(pump, positions, [Float](repeating: 5, count: Self.bank)) }
    }
    #expect(admitted)
    #expect(pump.accounting.evicted == (30 - Self.queued) * Self.bank)
    // Retirement returns while that feed is still held; later audio is refused.
    let consumer = pump.retire()
    Self.admit(pump, positions, Self.ramp(0..<500))
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
      let positions = Positions()
      weakPump = pump
      #expect(pump.startConsumer(feed: fed.feed))
      #expect(!pump.startConsumer(feed: fed.feed), "one consumer at a time")
      Self.admit(pump, positions, Self.ramp(0..<1_600))
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
    let positions = Positions()
    defer { gate.release() }
    let first = Fed()
    let second = Fed()
    Self.admit(pump, positions, Self.ramp(0..<Self.bank), at: 0)  // one full queued bank
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
    #expect(
      second.fedChunks.map(Self.layout) == [[[0, 0, Self.bank, 0]]],
      "its written positions came back with it")
    #expect(pump.accounting.delivered == Self.bank && pump.accounting.dropped == 0)
    #expect(!gate.didExpire, "every copy passed by release, none by deadline")
    pump.retire()
  }

  @Test("a consumer retired while copying feeds nothing and the pump delivers nothing more")
  func retireDuringCopy() async {
    let (pump, gate) = Self.heldConsumer()
    let positions = Positions()
    defer { gate.release() }
    let fed = Fed()
    Self.admit(pump, positions, Self.ramp(0..<Self.bank))
    #expect(pump.startConsumer(feed: fed.feed))
    let owns = await Task.detached { Self.signalled(gate.owned) }.value
    #expect(owns)
    let consumer = pump.retire()
    gate.release()
    await PreviewWait.within("the consumer's end") { await consumer?.value }
    #expect(fed.all.isEmpty)
    #expect(pump.accounting.delivered == 0)
    #expect(pump.takeChunk()?.samples == nil)
    #expect(!gate.didExpire)
  }

  @Test("a replacement consumer is refused until the stopped one has physically exited")
  func replacementWaitsForExit() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let positions = Positions()
    let first = Fed(hold: true)
    defer { first.open() }
    let second = Fed()
    #expect(pump.startConsumer(feed: first.feed))
    Self.admit(pump, positions, Self.ramp(0..<1_600))
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
    Self.admit(pump, positions, Self.ramp(1_600..<3_200))
    await PreviewWait.within("the new consumer's audio") { await second.until { $0.count == 1 } }
    #expect(second.all == [Self.ramp(1_600..<3_200)])
    #expect(first.all.count == 1)
    pump.retire()
  }

  @Test("a start racing a retirement never leaves a consumer running or feeding")
  func startRacingRetirement() async {
    for _ in 0..<100 {
      let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
      let positions = Positions()
      let fed = Fed()
      Self.admit(pump, positions, Self.ramp(0..<1_600))
      async let started = Task.detached { pump.startConsumer(feed: fed.feed) }.value
      async let retired = Task.detached { pump.retire() }.value
      _ = await (started, retired)
      // Whatever the order, the pump is retired: any consumer it had is stopping, none can start.
      let outstanding = pump.retire()
      await PreviewWait.within("any consumer's end") { await outstanding?.value }
      #expect(pump.retire() == nil, "no consumer survives")
      #expect(!pump.startConsumer(feed: fed.feed), "a retired pump starts nothing")
      let afterRetire = fed.all.count
      Self.admit(pump, positions, Self.ramp(0..<1_600))
      #expect(pump.takeChunk()?.samples == nil && fed.all.count == afterRetire, "nothing more is fed")
    }
  }

  @Test("with producers, a consumer and readers all racing, every offered sample is accounted")
  func accountingUnderConcurrency() async {
    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let positions = Positions()
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
          for _ in 0..<chunksEach { Self.admit(pump, positions, samples) }
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
    let positions = Positions()
    let first = Fed()
    let second = Fed()
    #expect(pump.startConsumer(feed: first.feed))
    Self.admit(pump, positions, Self.ramp(0..<1_600))
    await PreviewWait.within("the first session's audio") { await first.until { $0.count == 1 } }
    let stopped = pump.stopConsumer()
    await PreviewWait.within("the first consumer's end") { await stopped?.value }
    Self.admit(pump, positions, Self.ramp(1_600..<4_800))  // arrives between sessions
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
    let positions = Positions()
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, positions, Self.ramp(0..<1_600))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    // While that feed is held: two full banks and a partial bank are queued, then Stop seals.
    let held = 1_600 + 2 * Self.bank + 1_000
    Self.admit(pump, positions, Self.ramp(1_600..<held))
    let consumer = pump.seal()
    #expect(consumer != nil)
    Self.admit(pump, positions, Self.ramp(0..<500))
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
    let idlePositions = Positions()
    Self.admit(idle, idlePositions, Self.ramp(0..<1_600))
    #expect(idle.seal() == nil, "nothing will feed the held audio")
    idle.retire()

    let pump = MeetingLiveAudioPump(cadence: .milliseconds(1))
    let positions = Positions()
    let fed = Fed(hold: true)
    defer { fed.open() }
    #expect(pump.startConsumer(feed: fed.feed))
    Self.admit(pump, positions, Self.ramp(0..<1_600))
    await PreviewWait.within("the first feed", onExpiry: fed.open) {
      await fed.until { $0.count == 1 }
    }
    Self.admit(pump, positions, Self.ramp(1_600..<4_800))
    _ = pump.seal()
    // Delete after Stop: discard wins.
    let consumer = pump.retire()
    fed.open()
    await PreviewWait.within("the consumer's end", onExpiry: fed.open) { await consumer?.value }
    #expect(fed.all == [Self.ramp(0..<1_600)], "nothing queued was fed after the discard")
  }
}
