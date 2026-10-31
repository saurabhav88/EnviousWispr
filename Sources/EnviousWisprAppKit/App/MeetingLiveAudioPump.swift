import Foundation
import os

/// One meeting track's live audio on its way to a live-words session (#3973 plan §3.3).
///
/// **The producer side runs on the real-time capture thread** (`MeetingRecorder.liveSamples`,
/// right after the writer), so it may only copy borrowed samples into storage this pump already
/// owns: no await, task, dispatch, growth or waiting. It takes the state lock with
/// `withLockIfAvailable`; when that lock is busy, the chunk is dropped and counted with a
/// lock-free atomic add rather than waited for. Everything is allocated in `init`.
///
/// **Storage: banks of 1.6 s, owned by index.** `banks` banks of `bankSamples` samples each, in
/// one allocation. At any moment every bank is exactly one of:
/// - free (in the free list);
/// - producer-owned (the one the capture thread is filling);
/// - queued (full, in the ring, oldest first, at most `queuedBanks`);
/// - consumer-owned (taken by the consumer, being copied out; at most one).
/// A full producer bank is queued by index and the producer takes a free one. When the ring is
/// full, the OLDEST queued bank is evicted (its samples counted as dropped) and becomes the
/// producer's bank: the pump keeps the newest audio. A consumer-owned bank is never evicted.
/// `banks = queuedBanks + 2` (producer + consumer), so a free bank always exists when one is
/// needed: queued ≤ `queuedBanks` after an eviction, and the consumer owns at most one.
///
/// **Retained audio** (queued plus the producer's partial bank) is at most
/// `(queuedBanks + 1) × bankSamples` = 18 × 25,600 = 460,800 samples, 28.8 s, inside the plan's
/// 30 s (480,000) window. The consumer's bank is in transit, not retained: it is copied and
/// returned before the copy is fed.
///
/// **Consumer.** One task at a time takes the oldest queued bank (or, when nothing is queued,
/// the producer's partial bank, so short speech is never stranded), copies it OUTSIDE the lock
/// into its own array, returns the bank, and only then awaits `feed`. The array lives until that
/// `feed` returns. It polls every `cadence` when there is nothing to take. A stopped consumer
/// keeps its slot until its task physically exits, so a replacement cannot overlap it; a bank it
/// was copying when stopped goes back to the front of the ring for the next consumer.
///
/// **Sealing** (Stop, #4248) closes admission only: the running consumer keeps feeding what is
/// queued and the partial bank, in order, then exits on its own. **Retirement** (Delete, Quit,
/// or a sealed pump's discard) closes admission and cancels the consumer synchronously and
/// never waits for a `feed` that does not return; later producer calls are refused and counted.
/// Storage is freed when the last holder (the recorder's observer, the consumer task) lets go.
///
/// The producer runs on the real-time capture thread for the call sound and on the microphone
/// writer's queue for the microphone (`MeetingRecorder.liveSamples`).
final class MeetingLiveAudioPump: @unchecked Sendable {

  /// 1.6 s at 16 kHz.
  static let bankSamples = 25_600
  /// Queued full banks, at most: with the producer's partial bank, 28.8 s retained.
  static let queuedBanks = 17
  /// Queued + producer + consumer.
  static let banks = queuedBanks + 2

  /// What happened to every sample offered to `admit`, for owners and tests.
  struct Accounting: Equatable, Sendable {
    /// Copied into a bank.
    var admitted = 0
    /// Admitted, then evicted from a full ring before anyone took it.
    var evicted = 0
    /// Never admitted: the lock was busy or the pump was retired.
    var refused = 0
    /// Taken by the consumer and fed (a stopped consumer's copy is put back, not counted).
    var delivered = 0
    /// Samples a live-words session will never see.
    var dropped: Int { evicted + refused }
  }

  private struct State {
    var counts: [Int]
    var free: [Int]
    var freeCount: Int
    var ring: [Int]
    var ringHead = 0
    var ringCount = 0
    var producer: Int
    var consumerBank: Int?
    /// Which consumer may take; bumped by every stop, so a stopped loop takes nothing more.
    var consumerGeneration = 0
    /// The consumer's task, from its start until it physically exits (it clears this itself).
    var consumerTask: Task<Void, Never>?
    var open = true
    /// False once sealed: no new audio; the consumer drains what is held, then exits.
    var admitting = true
    var accounting = Accounting()

    mutating func popFree() -> Int {
      freeCount -= 1
      return free[freeCount]
    }

    mutating func pushFree(_ bank: Int) {
      counts[bank] = 0
      free[freeCount] = bank
      freeCount += 1
    }

    /// The producer's bank is full: queue it (evicting the oldest queued bank when the ring is
    /// full) and give the producer an empty bank.
    mutating func rotateProducer() {
      if ringCount == MeetingLiveAudioPump.queuedBanks { evictOldest() }
      ring[(ringHead + ringCount) % MeetingLiveAudioPump.queuedBanks] = producer
      ringCount += 1
      producer = popFree()
    }

    mutating func evictOldest() {
      let oldest = ring[ringHead]
      ringHead = (ringHead + 1) % MeetingLiveAudioPump.queuedBanks
      ringCount -= 1
      accounting.evicted += counts[oldest]
      pushFree(oldest)
    }

    /// A stopped consumer's bank goes back as the oldest queued audio. With the ring full it is
    /// the oldest anyway, so it is evicted instead.
    mutating func requeueOldest(_ bank: Int) {
      guard ringCount < MeetingLiveAudioPump.queuedBanks else {
        accounting.evicted += counts[bank]
        pushFree(bank)
        return
      }
      ringHead =
        (ringHead + MeetingLiveAudioPump.queuedBanks - 1) % MeetingLiveAudioPump.queuedBanks
      ring[ringHead] = bank
      ringCount += 1
    }
  }

  private let storage: UnsafeMutablePointer<Float>
  private let state: OSAllocatedUnfairLock<State>
  /// Samples refused while the state lock was busy. Changed and read only with
  /// `OSAtomicAdd64Barrier`: one hardware atomic add (lock-free; never waits on a lock), so every
  /// drop is counted whatever readers and other producers do at the same moment. (Swift's own `Atomic`
  /// needs macOS 15 and this app supports 14; the C11 atomics it is built on are not callable
  /// from Swift without a C module.)
  private let busyRefusals: UnsafeMutablePointer<Int64>
  private let cadence: Duration
  /// Test seam (nil in the app): runs after the consumer took a bank, before it copies it out.
  private let consumerOwnsBank: (@Sendable () -> Void)?

  init(cadence: Duration = .milliseconds(100), consumerOwnsBank: (@Sendable () -> Void)? = nil) {
    self.cadence = cadence
    self.consumerOwnsBank = consumerOwnsBank
    storage = .allocate(capacity: Self.banks * Self.bankSamples)
    storage.initialize(repeating: 0, count: Self.banks * Self.bankSamples)
    busyRefusals = .allocate(capacity: 1)
    busyRefusals.initialize(to: 0)
    // Bank 0 starts as the producer's; the rest are free.
    state = OSAllocatedUnfairLock(
      initialState: State(
        counts: [Int](repeating: 0, count: Self.banks),
        free: Array((1..<Self.banks).reversed()) + [0],
        freeCount: Self.banks - 1,
        ring: [Int](repeating: 0, count: Self.queuedBanks),
        producer: 0))
  }

  deinit {
    storage.deinitialize(count: Self.banks * Self.bankSamples)
    storage.deallocate()
    busyRefusals.deinitialize(count: 1)
    busyRefusals.deallocate()
  }

  // MARK: - Producer (capture thread)

  /// Copies a borrowed chunk into the pump, or drops it and counts it. Never waits.
  func admit(_ samples: UnsafeBufferPointer<Float>) {
    guard let source = samples.baseAddress, !samples.isEmpty else { return }
    let storage = self.storage
    let taken: Bool? = state.withLockIfAvailableUnchecked { s in
      guard s.open, s.admitting else {
        s.accounting.refused += samples.count
        return true
      }
      var offset = 0
      while offset < samples.count {
        let bank = s.producer
        let filled = s.counts[bank]
        let n = min(Self.bankSamples - filled, samples.count - offset)
        (storage + bank * Self.bankSamples + filled).update(from: source + offset, count: n)
        s.counts[bank] = filled + n
        offset += n
        if s.counts[bank] == Self.bankSamples { s.rotateProducer() }
      }
      s.accounting.admitted += samples.count
      return true
    }
    if taken == nil { OSAtomicAdd64Barrier(Int64(samples.count), busyRefusals) }
  }

  // MARK: - Consumer

  /// The next chunk, oldest first, or nil when there is nothing to take, the pump is retired,
  /// or `generation` (the calling consumer's) was stopped, including during the copy. The bank
  /// is back in the pump before this returns.
  func takeChunk(generation: Int? = nil) -> [Float]? {
    let taken: (bank: Int, count: Int)? = state.withLock { s in
      guard s.open, s.consumerBank == nil else { return nil }
      if let generation, generation != s.consumerGeneration { return nil }
      let bank: Int
      if s.ringCount > 0 {
        bank = s.ring[s.ringHead]
        s.ringHead = (s.ringHead + 1) % Self.queuedBanks
        s.ringCount -= 1
      } else if s.counts[s.producer] > 0 {
        // Nothing queued: take the partial bank so short speech is delivered now.
        bank = s.producer
        s.producer = s.popFree()
      } else {
        return nil
      }
      s.consumerBank = bank
      return (bank, s.counts[bank])
    }
    guard let taken else { return nil }
    consumerOwnsBank?()
    // Outside the lock: the producer keeps admitting into other banks meanwhile.
    let chunk = Array(
      UnsafeBufferPointer(start: storage + taken.bank * Self.bankSamples, count: taken.count))
    return state.withLock { s -> [Float]? in
      s.consumerBank = nil
      guard s.open else {
        s.pushFree(taken.bank)  // retired: nothing more is delivered
        return nil
      }
      if let generation, generation != s.consumerGeneration {
        s.requeueOldest(taken.bank)  // stopped during the copy: the next consumer gets it
        return nil
      }
      s.accounting.delivered += taken.count
      s.pushFree(taken.bank)
      return chunk
    }
  }

  /// Starts the one consumer, feeding every chunk to `feed` in order. False while a previous
  /// consumer's task has not exited yet, or once the pump is retired.
  @discardableResult
  func startConsumer(feed: @escaping @Sendable ([Float]) async -> Void) -> Bool {
    let cadence = self.cadence
    return state.withLock { s -> Bool in
      guard s.open, s.consumerTask == nil else { return false }
      let generation = s.consumerGeneration
      // Admission, generation and the slot change in this one lock step, so a retirement or
      // stop either happens before (refused) or after (it sees this task).
      s.consumerTask = Task { [self] in
        defer { state.withLock { $0.consumerTask = nil } }
        while !Task.isCancelled {
          if let chunk = takeChunk(generation: generation) {
            await feed(chunk)  // the array lives until this returns
            continue
          }
          guard isCurrent(generation) else { return }
          // Sealed and nothing left to take (queued or partial), checked in one lock step after
          // the seal: no audio admitted before the seal is left behind.
          if isSealedAndEmpty { return }
          try? await Task.sleep(for: cadence)  // nothing to take yet
        }
      }
      return true
    }
  }

  /// Stops the consumer and keeps the buffered audio for the next one (a session handoff).
  /// Returns the consumer's task, which ends once its current `feed` returns; until then a new
  /// consumer is refused. Repeated calls return the same task while it is still running.
  @discardableResult
  func stopConsumer() -> Task<Void, Never>? {
    let task = state.withLock { s -> Task<Void, Never>? in
      s.consumerGeneration += 1
      return s.consumerTask
    }
    task?.cancel()
    return task
  }

  /// Closes admission for good and lets the running consumer feed everything already held, in
  /// order, before it exits. Returns that consumer's task (nil when none runs: nothing will be
  /// fed). A later `retire` still discards and cancels. Repeatable.
  @discardableResult
  func seal() -> Task<Void, Never>? {
    state.withLock { s -> Task<Void, Never>? in
      s.admitting = false
      return s.consumerTask
    }
  }

  /// Closes admission for good and stops the consumer without waiting for it. Repeatable: each
  /// call returns the consumer's task while it has not exited.
  @discardableResult
  func retire() -> Task<Void, Never>? {
    state.withLock { $0.open = false }
    return stopConsumer()
  }

  /// Samples accounted so far.
  var accounting: Accounting {
    var snapshot = state.withLock { $0.accounting }
    snapshot.refused += Int(OSAtomicAdd64Barrier(0, busyRefusals))  // an atomic read
    return snapshot
  }

  private func isCurrent(_ generation: Int) -> Bool {
    state.withLock { $0.open && $0.consumerGeneration == generation }
  }

  private var isSealedAndEmpty: Bool {
    state.withLock { s in
      !s.admitting && s.ringCount == 0 && s.counts[s.producer] == 0 && s.consumerBank == nil
    }
  }

  #if DEBUG
    /// Holds the state lock until `release` is signalled (contention tests).
    func holdLockForTests(entered: DispatchSemaphore, release: DispatchSemaphore) {
      state.withLock { _ in
        entered.signal()
        release.wait()
      }
    }

  #endif
}
