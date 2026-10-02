import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #3338 PR-4 (plan §3.E E.3, registry K13): holds a pasted take's audio in memory for a
/// short time so a learn re-check can listen to it again, then lets it go.
///
/// Lifetime rule (single authority):
/// - Absolute expiry = the earlier of 75 s after `retain` and 60 s after `markPasted`, on
///   the learn watcher's own clock (the injected scheduler is the watcher's instance).
///   A take never marked pasted expires 75 s after `retain`.
/// - From `expiry − drainMargin` no lease is granted and every lease is cancelled; the
///   margin is the measured worst-case cancellation-to-release drain plus 20%. Without
///   a qualified margin no lease is ever granted (retention and expiry still run).
/// - Leases are only for pasted, live takes whose observation has not ended.
///   `observationEnded` stops new leases; existing ones may finish until the cutoff.
/// - At most two takes own audio, counting removed takes whose leases are still out.
///   A third take evicts the oldest take with no outstanding lease, or is refused.
/// - `discard`, `cancelAll` and expiry remove the take and cancel its leases. The hold
///   drops its reference at once; a lease drops its reference when cancelled or ended.
///   A borrower's own copies are released when its work finishes (it is signalled).
///
/// Nothing is persisted, logged as content or sent. Sink calls only update local state.
@MainActor
package final class LearnAudioHold: LearnAudioSink, LearnAudioLeasing {

  package nonisolated static let unpastedLifetimeMs = 75_000
  package nonisolated static let pastedLifetimeMs = 60_000
  package nonisolated static let capacity = 2

  /// The hold's only reference to a take's audio. Leases reference it while granted.
  package final class Storage {
    package let record: LearnTakeAudio
    init(record: LearnTakeAudio) { self.record = record }
  }

  @MainActor
  private final class Entry {
    let takeID: String
    let generation: Int
    let retainedAtMs: Int
    var pastedAtMs: Int?
    var storage: Storage?
    var observationEnded = false
    var timer: (any PastedRegionScheduledWork)?
    var leases: [Lease] = []

    init(takeID: String, generation: Int, retainedAtMs: Int, storage: Storage) {
      self.takeID = takeID
      self.generation = generation
      self.retainedAtMs = retainedAtMs
      self.storage = storage
    }

    var expiryMs: Int {
      let unpasted = retainedAtMs + LearnAudioHold.unpastedLifetimeMs
      guard let pastedAtMs else { return unpasted }
      return min(unpasted, pastedAtMs + LearnAudioHold.pastedLifetimeMs)
    }

    var outstandingLeases: Int { leases.filter { !$0.isEnded }.count }
  }

  @MainActor
  package final class Lease: LearnAudioLease {
    private weak var hold: LearnAudioHold?
    private var storage: Storage?
    private var cancelled = false
    private(set) var isEnded = false
    private var handlers: [@Sendable () -> Void] = []
    let takeID: String

    init(hold: LearnAudioHold, storage: Storage, takeID: String) {
      self.hold = hold
      self.storage = storage
      self.takeID = takeID
    }

    package func read() async -> LearnTakeAudio? {
      guard !cancelled, !isEnded, let hold, hold.isReadable(takeID: takeID) else { return nil }
      return storage?.record
    }

    package var isCancelled: Bool { get async { cancelled } }

    package func onCancel(_ handler: @escaping @Sendable () -> Void) async {
      guard !isEnded else { return }
      if cancelled {
        handler()
      } else {
        handlers.append(handler)
      }
    }

    package func end() async { endNow() }

    func endNow() {
      guard !isEnded else { return }
      isEnded = true
      storage = nil
      handlers.removeAll()
      hold?.leaseEnded(self)
    }

    func cancelNow() {
      guard !cancelled, !isEnded else { return }
      cancelled = true
      storage = nil
      let signal = handlers
      handlers.removeAll()
      for handler in signal { handler() }
    }
  }

  private let scheduler: any PastedRegionScheduling
  private let drainMarginMs: Int?
  private var entries: [String: Entry] = [:]
  /// Removed takes whose leases are still out; they count toward `capacity`.
  private var draining: [Entry] = []
  private var nextGeneration = 0
  /// Takes removed at absolute expiry while a lease was still out (a drain that
  /// overran its margin). The release tests assert this stays zero.
  package private(set) var undrainedAtExpiry = 0

  /// `qualifiedDrainMarginMs` is the measured worst-case cancellation-to-release drain
  /// plus 20%, in scheduler milliseconds; `nil` until qualified, which grants no leases.
  package init(scheduler: any PastedRegionScheduling, qualifiedDrainMarginMs: Int?) {
    self.scheduler = scheduler
    if let margin = qualifiedDrainMarginMs, margin >= 0, margin < Self.pastedLifetimeMs {
      drainMarginMs = margin
    } else {
      drainMarginMs = nil
    }
  }

  // MARK: LearnAudioSink

  package func retain(takeID: String, record: LearnTakeAudio) {
    guard !takeID.isEmpty, record.takeID == takeID, entries[takeID] == nil else { return }
    guard makeRoom() else { return }
    nextGeneration += 1
    let entry = Entry(
      takeID: takeID, generation: nextGeneration, retainedAtMs: scheduler.nowMs,
      storage: Storage(record: record))
    entries[takeID] = entry
    schedule(entry)
  }

  package func markPasted(takeID: String, atMs: Int) {
    guard let entry = entries[takeID], entry.pastedAtMs == nil else { return }
    entry.pastedAtMs = atMs
    schedule(entry)
  }

  package func discard(takeID: String) {
    guard let entry = entries[takeID] else { return }
    remove(entry, atExpiry: false)
  }

  // MARK: Lifecycle (wired by the next chunk)

  /// The learn watcher stopped observing this take: no new leases; existing ones may
  /// finish until the cutoff.
  package func observationEnded(takeID: String) {
    entries[takeID]?.observationEnded = true
  }

  /// Recording start, toggle off, sleep, memory pressure, termination: every take goes.
  package func cancelAll() {
    for entry in Array(entries.values) { remove(entry, atExpiry: false) }
  }

  // MARK: LearnAudioLeasing

  package func lease(takeID: String) async -> (any LearnAudioLease)? {
    guard drainMarginMs != nil, let entry = entries[takeID], entry.pastedAtMs != nil,
      !entry.observationEnded, let storage = entry.storage, scheduler.nowMs < cutoffMs(entry)
    else { return nil }
    let lease = Lease(hold: self, storage: storage, takeID: takeID)
    entry.leases.append(lease)
    return lease
  }

  // MARK: Internals

  fileprivate func isReadable(takeID: String) -> Bool {
    guard let entry = entries[takeID] else { return false }
    return scheduler.nowMs < cutoffMs(entry)
  }

  fileprivate func leaseEnded(_ lease: Lease) {
    draining.removeAll { $0.outstandingLeases == 0 }
  }

  private func cutoffMs(_ entry: Entry) -> Int {
    entry.expiryMs - (drainMarginMs ?? 0)
  }

  /// Ownership slots in use: live takes plus removed takes with leases still out.
  private var slotsInUse: Int {
    draining.removeAll { $0.outstandingLeases == 0 }
    return entries.count + draining.count
  }

  /// Frees a slot synchronously by evicting the oldest live take with no outstanding
  /// lease; `false` when no slot can be freed (the incoming take is refused).
  private func makeRoom() -> Bool {
    if slotsInUse < Self.capacity { return true }
    let evictable = entries.values.filter { $0.outstandingLeases == 0 }.min {
      $0.generation < $1.generation
    }
    guard let oldest = evictable else { return false }
    remove(oldest, atExpiry: false)
    return slotsInUse < Self.capacity
  }

  private func remove(_ entry: Entry, atExpiry: Bool) {
    guard entries[entry.takeID] === entry else { return }
    entries[entry.takeID] = nil
    entry.timer?.cancel()
    entry.timer = nil
    entry.storage = nil
    for lease in entry.leases { lease.cancelNow() }
    if entry.outstandingLeases > 0 {
      if atExpiry { undrainedAtExpiry += 1 }
      draining.append(entry)
    }
  }

  /// One timer per take, aimed at its next event (the lease cutoff, then expiry),
  /// re-evaluated against the clock when it fires, so a late callback or a clock jump
  /// still applies the absolute deadlines.
  private func schedule(_ entry: Entry) {
    entry.timer?.cancel()
    let now = scheduler.nowMs
    let cutoff = cutoffMs(entry)
    let next = now < cutoff ? cutoff : entry.expiryMs
    let generation = entry.generation
    let takeID = entry.takeID
    entry.timer = scheduler.schedule(afterMs: max(0, next - now)) { [weak self] in
      self?.timerFired(takeID: takeID, generation: generation)
    }
  }

  private func timerFired(takeID: String, generation: Int) {
    guard let entry = entries[takeID], entry.generation == generation else { return }
    entry.timer = nil
    let now = scheduler.nowMs
    if now >= entry.expiryMs {
      remove(entry, atExpiry: true)
      return
    }
    if now >= cutoffMs(entry) {
      for lease in entry.leases { lease.cancelNow() }
    }
    schedule(entry)
  }

  // MARK: Test seams (read-only)

  package func storageForTesting(takeID: String) -> Storage? { entries[takeID]?.storage }
  package var heldTakeIDsForTesting: Set<String> { Set(entries.keys) }
  package var slotsInUseForTesting: Int { slotsInUse }
}
