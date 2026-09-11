import Foundation

/// #2787 — whether a vendor decode call (`transcribe` / `finalizeStreaming`)
/// is still RUNNING, independent of whether anyone is still waiting for it.
///
/// A recording session can conclude `.cancelled` while its decode is in
/// flight: the kernel honours a cancel during `.delivering(.transcribing)` and
/// returns to idle, but the vendor call it was awaiting keeps running until
/// Core ML returns — which, on the machine that motivated this, was never.
/// Nothing above the manager could see that. `isStreaming`,
/// `streamingStartInFlight` and the session generation all answer "is anyone
/// waiting"; this answers "is the engine busy", which is the question a
/// record press, a crash-recovery replay and an engine unload all need.
///
/// The count is incremented immediately before the backend call is issued and
/// decremented on every exit, thrown or returned. Cancellation of the awaiting
/// task is NOT an exit: `Task.cancel()` sets a flag the vendor call may ignore,
/// so the only release evidence is the call returning
/// (`swift-concurrency-patterns.md`, and the escape-recovery reasoning at
/// `RecordingSessionKernel.cancel`).
///
/// `awaitIdle()` resumes every waiter when the count reaches zero. It never
/// times out: a caller that needs a bound races it with its own deadline, and
/// the one production caller (`AbandonedDecodeHold`) deliberately does not —
/// the engine is held until it is actually free, and the user is told so.
@MainActor
public final class VendorDecodeOccupancy {
  public private(set) var inFlight: Int = 0
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public var isIdle: Bool { inFlight == 0 }

  /// Run one vendor decode call under occupancy accounting.
  public func track<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
    inFlight += 1
    defer { end() }
    return try await operation()
  }

  private func end() {
    inFlight -= 1
    guard inFlight == 0 else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  /// Suspends until no vendor decode is in flight. Returns immediately when
  /// already idle.
  public func awaitIdle() async {
    guard inFlight > 0 else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }
}
