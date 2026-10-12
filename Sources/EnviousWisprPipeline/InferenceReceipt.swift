import EnviousWisprASR
import EnviousWisprCore
import Foundation

/// The first vendor-inference entry of one operation (#3546 plan §3.7 T1, live-signal
/// amendment §2.2).
///
/// Written synchronously from whichever thread or actor makes the vendor call (the main
/// actor, an ASR backend actor, the vendor's streaming actor), so it is lock-protected.
/// The lock guards only reading or assigning the first entry: nothing awaits, calls out,
/// logs or takes another lock while holding it, so it cannot deadlock; a main-actor read
/// can briefly contend with a write.
package final class InferenceReceipt<Entry: Sendable>: @unchecked Sendable {
  // Safe: `entry` is only touched under `lock`, and the lock is held for one read or
  // assignment, never across a call.
  private let lock = NSLock()
  private var entry: Entry?

  package init() {}

  /// Records `candidate` if no entry exists yet. Returns `true` only for the call that
  /// committed the first entry, after the lock is released.
  @discardableResult
  package func record(_ candidate: Entry) -> Bool {
    lock.lock()
    let won = entry == nil
    if won { entry = candidate }
    lock.unlock()
    return won
  }

  package func read() -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entry
  }
}

/// One receipt per recent session, for an engine adapter. Opened synchronously when a
/// session begins, so every operation of that session (batch decode, streaming windows,
/// rescue) captures the same receipt and the first real entry wins. Bounded: only the
/// current take and a few late ones can still be asked about; an evicted session's late
/// entry writes only its own detached receipt.
@MainActor
package final class InferenceReceiptBook {
  private var receipts: [(session: SessionID, receipt: InferenceReceipt<ASRInferenceEntry>)] = []
  private static let capacity = 4

  package init() {}

  /// Opens the receipt for a new session.
  package func open(_ session: SessionID) {
    receipts.removeAll { $0.session == session }
    receipts.append((session, InferenceReceipt<ASRInferenceEntry>()))
    if receipts.count > Self.capacity {
      receipts.removeFirst(receipts.count - Self.capacity)
    }
  }

  package func entry(for session: SessionID) -> ASRInferenceEntry? {
    receipts.last { $0.session == session }?.receipt.read()
  }

  /// A synchronous observation bound to `session`'s own receipt and the given model,
  /// for the vendor call about to be made. Only the call that commits the session's first
  /// entry schedules `notify`, once, on the main actor; readers never wait for it. `nil`
  /// when the session has no open receipt.
  package func observer(
    session: SessionID?, identity: ASRModelIdentity?,
    notify: @escaping @MainActor (SessionID) -> Void
  ) -> ASRInferenceEntryObserver? {
    guard let session, let receipt = receipts.last(where: { $0.session == session })?.receipt
    else { return nil }
    let entry = ASRInferenceEntry(session: session, identity: identity)
    return {
      if receipt.record(entry) {
        Task { @MainActor in notify(session) }
      }
    }
  }
}
