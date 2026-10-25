import EnviousWisprASR
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// A Universal transcript session's ordered event queue (#3973 plan §3.1): the meeting's live
/// words, where dictation's preview keeps only the latest text.
///
/// The decode actor only enqueues (`publish` takes the lock, never waits); one consumer task
/// corrects Custom Words and delivers in order. Nothing cumulative is kept: entries leave the
/// queue as they are delivered.
///
/// **Bounded by bytes, not by coalescing.** Consecutive updates merge (finalized deltas joined
/// in order, the latest in-progress text kept), but a stalled consumer could still let finals
/// pile up, so admission checks a queued-text budget. An event that does not fit is refused
/// whole (never truncated) and closes the queue: the accepted entries still drain, then exactly
/// one `.ended(.failed("backlog"))`. The terminal itself needs no budget.
///
/// Accounting, in bytes: each entry costs `entryCost` plus the UTF-8 length of its texts; a
/// discontinuity or an empty update costs `entryCost` alone, so alternating barriers cannot
/// grow without bound. The entry the consumer is delivering stays charged until its delivery
/// returns, so a consumer stuck inside `onEvent` holds its share. Custom Words run on the
/// consumer after an entry leaves the queue, so a longer canonical never adds to queued text;
/// the in-flight charge is the entry's size as queued.
final class LiveWordsQueue: @unchecked Sendable {

  /// The queued-text budget (plan §3.1, R3 finding 5): 64 KB.
  static let budget = 64 * 1024
  /// Per-entry storage charge on top of its text.
  static let entryCost = 64

  private enum Entry {
    case update(finalized: String, inProgress: String)
    case discontinuity

    var cost: Int {
      switch self {
      case .update(let finalized, let inProgress):
        LiveWordsQueue.entryCost + finalized.utf8.count + inProgress.utf8.count
      case .discontinuity:
        LiveWordsQueue.entryCost
      }
    }
  }

  private enum Next {
    case entry(Entry)
    case terminal(LiveWordsEnd)
    case silenced
  }

  private struct State {
    var entries: [Entry] = []
    /// Bytes charged for `entries`.
    var queued = 0
    /// Bytes charged for the entry being delivered.
    var inFlight = 0
    var accepting = true
    /// The one terminal, chosen by whichever stop came first.
    var terminal: LiveWordsEnd?
    /// An opening that never reached its owner: exit without delivering anything.
    var silenced = false
    var waiter: CheckedContinuation<Void, Never>?
  }

  private let state: OSAllocatedUnfairLock<State>
  private let consumer: Task<Void, Never>

  init(lookups: WordCorrector.Lookups?, onEvent: @escaping @Sendable (LiveWordsEvent) -> Void) {
    let state = OSAllocatedUnfairLock(initialState: State())
    self.state = state
    self.consumer = Task {
      let corrector = WordCorrector()
      func corrected(_ text: String) -> String {
        guard let lookups, !text.isEmpty else { return text }
        return corrector.correct(text, using: lookups).corrected
      }
      while true {
        switch await Self.next(state) {
        case .silenced:
          return
        case .entry(.update(let finalized, let inProgress)):
          onEvent(.update(finalized: corrected(finalized), inProgress: corrected(inProgress)))
        case .entry(.discontinuity):
          onEvent(.discontinuity)
        case .terminal(let end):
          onEvent(.ended(end))
          return
        }
        state.withLock { $0.inFlight = 0 }
      }
    }
  }

  /// The runtime's transcript callback, on the decode actor. Enqueue only.
  func publish(_ event: TranscriptEvent) {
    let wake = state.withLock { s -> CheckedContinuation<Void, Never>? in
      guard s.accepting else { return nil }
      // The charge after admission, computed from byte counts BEFORE any text is built: a
      // refused event allocates nothing and leaves the queue exactly as it was.
      var merging: String?
      var charge = s.queued + s.inFlight
      switch event {
      case .update(let finalized, let inProgress):
        if case .update(let earlier, let replaced)? = s.entries.last {
          // Coalesce: the deltas in order, the newest in-progress text replacing the old.
          merging = earlier
          charge += finalized.utf8.count + inProgress.utf8.count - replaced.utf8.count
        } else {
          charge += Self.entryCost + finalized.utf8.count + inProgress.utf8.count
        }
      case .discontinuity:
        charge += Self.entryCost
      }
      guard charge <= Self.budget else {
        // Refused whole: what was accepted before still drains, then the backlog terminal.
        s.accepting = false
        if s.terminal == nil { s.terminal = .failed("backlog") }
        return Self.takeWaiter(&s)
      }
      switch event {
      case .update(let finalized, let inProgress):
        if merging != nil { s.entries.removeLast() }
        s.entries.append(
          .update(finalized: (merging ?? "") + finalized, inProgress: inProgress))
      case .discontinuity:
        s.entries.append(.discontinuity)
      }
      s.queued = charge - s.inFlight
      return Self.takeWaiter(&s)
    }
    wake?.resume()
  }

  /// Stops accepting transcript output; accepted entries still drain. The terminal is chosen
  /// later by `fail` or `finish`, unless the backlog already chose it.
  func closeInput() {
    state.withLock { $0.accepting = false }
  }

  /// Ends with `.failed(reason)` after the accepted entries, unless a terminal was already
  /// chosen. Does not wait.
  func fail(_ reason: String) {
    end(.failed(reason))
  }

  /// Ends with `.requested` after the accepted entries, unless a terminal was already chosen,
  /// and returns once the consumer delivered the terminal.
  func finish() async {
    end(.requested)
    await consumer.value
  }

  /// An opening its owner never received: delivers nothing more, not even a terminal, and
  /// returns once the consumer exited.
  func silence() async {
    let wake = state.withLock { s -> CheckedContinuation<Void, Never>? in
      s.accepting = false
      s.silenced = true
      return Self.takeWaiter(&s)
    }
    wake?.resume()
    await consumer.value
  }

  private func end(_ terminal: LiveWordsEnd) {
    let wake = state.withLock { s -> CheckedContinuation<Void, Never>? in
      s.accepting = false
      if s.terminal == nil { s.terminal = terminal }
      return Self.takeWaiter(&s)
    }
    wake?.resume()
  }

  private static func takeWaiter(_ s: inout State) -> CheckedContinuation<Void, Never>? {
    defer { s.waiter = nil }
    return s.waiter
  }

  /// The consumer's next step: accepted entries first, then the terminal.
  private static func next(_ state: OSAllocatedUnfairLock<State>) async -> Next {
    while true {
      let found = state.withLock { s -> Next? in
        if s.silenced { return .silenced }
        if !s.entries.isEmpty {
          let entry = s.entries.removeFirst()
          s.queued -= entry.cost
          s.inFlight = entry.cost
          return .entry(entry)
        }
        return s.terminal.map(Next.terminal)
      }
      if let found { return found }
      await withCheckedContinuation { c in
        let ready = state.withLock { s -> Bool in
          if s.silenced || !s.entries.isEmpty || s.terminal != nil { return true }
          s.waiter = c
          return false
        }
        if ready { c.resume() }
      }
    }
  }
}
