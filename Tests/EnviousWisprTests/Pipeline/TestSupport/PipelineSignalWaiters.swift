import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// Signal-based test waiters for the kernel-driver suites (#875).
//
// Replaces real-time poll loops (`pollUntil` + `Task.sleep` cadence) and
// fixed `for _ in 0..<N { await Task.yield() }` budgets — both flake under
// release-config CI optimization, where contended scheduling overshoots the
// budget and a state/count that lands in 2s locally lands past the window in
// CI (swift-patterns.md `tests-no-real-time-scheduling-precision`,
// `signal-spy-fire-and-forget-logs`; no-arbitrary-timeouts.md
// `prefer-signal-based-detection`).
//
// Both waiters mirror `SignalPipelineLogger`: the "already satisfied?" check
// and the waiter install are atomic within one isolation domain (no `await`
// between them), each waiter has a UUID so it resumes exactly once, and an
// internal timeout task guarantees the continuation always resolves so a
// never-arriving signal surfaces as a fast failure instead of a hang
// (swift-patterns.md `tests-no-unconditional-continuation-await`).

/// Awaits a mapped `PipelineState` on a `KernelDictationDriver` via its
/// `onStateChange` callback instead of polling `driver.state`. Records every
/// state the driver fires (history) and advances a cursor as each `wait(for:)`
/// consumes a match, so a test that passes through the same state more than
/// once (e.g. two recording sessions) matches each occurrence in order rather
/// than re-matching the first. Test bodies `await` sequentially, so at most one
/// waiter is parked at a time.
@MainActor
final class PipelineStateWaiter {
  private struct Waiter {
    let id: UUID
    let predicate: (PipelineState) -> Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private let driver: KernelDictationDriver
  private var history: [PipelineState] = []
  /// Index of the first history entry not yet consumed by a `wait(for:)`.
  private var cursor: Int = 0
  private var pending: Waiter?

  /// Subscribes to `driver.onStateChange`. Seeds `history` with the driver's
  /// current state so a state reached before subscription is not missed.
  init(_ driver: KernelDictationDriver) {
    self.driver = driver
    history.append(driver.state)
    driver.onStateChange = { [weak self] state in
      // `onStateChange` fires synchronously on the `@MainActor` driver, so
      // recording on the main actor is safe and keeps history ordered.
      MainActor.assumeIsolated { self?.record(state) }
    }
  }

  private func record(_ state: PipelineState) {
    history.append(state)
    guard let waiter = pending, waiter.predicate(state) else { return }
    cursor = history.count  // consume through this state
    pending = nil
    waiter.continuation.resume()
  }

  /// Await until a state matching `predicate` is observed. Consumes the first
  /// unconsumed matching state in history (immediate return) or parks until one
  /// arrives. Always resolves within `timeout` (the test then fails on its
  /// post-wait assertion rather than hanging).
  func wait(
    for predicate: @escaping (PipelineState) -> Bool,
    timeout: Duration = .seconds(5)
  ) async {
    if let index = (cursor..<history.count).first(where: { predicate(history[$0]) }) {
      cursor = index + 1
      return
    }
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.resume(id)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      pending = Waiter(id: id, predicate: predicate, continuation: continuation)
    }
    timeoutTask.cancel()
  }

  /// Convenience: await an exact state.
  func wait(for state: PipelineState, timeout: Duration = .seconds(5)) async {
    await wait(for: { $0 == state }, timeout: timeout)
  }

  private func resume(_ id: UUID) {
    guard let waiter = pending, waiter.id == id else { return }
    pending = nil
    // Reaching here means the timeout fired before any matching state — a real
    // signal failure, not a satisfied wait. Record it so the test fails instead
    // of silently proceeding past a state that never arrived.
    Issue.record("PipelineStateWaiter timed out waiting for a matching pipeline state")
    waiter.continuation.resume()
  }
}

/// Count-reached signal embedded in a test stub (actor or `@MainActor` class).
/// The owner holds the authoritative counter and calls `notify(reached:)` after
/// each increment; a waiter parks until the count reaches its target. All
/// methods must be called from the owner's isolation — that isolation provides
/// the atomicity `SignalPipelineLogger` gets from `@MainActor` (the
/// "already reached?" check, install, and `notify` never interleave). The
/// owner pairs this with a timeout task that calls `resume(id:)` so a target
/// that never arrives resolves instead of hanging.
struct CountWaiters {
  private struct Waiter {
    let id: UUID
    let target: Int
    let continuation: CheckedContinuation<Void, Never>
  }
  /// Names the observed counter for the timeout failure message.
  let label: String
  private var waiters: [Waiter] = []

  init(_ label: String) {
    self.label = label
  }

  /// Resume + remove every waiter whose target the new count has reached.
  mutating func notify(reached count: Int) {
    let ready = waiters.filter { $0.target <= count }
    waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
    for waiter in ready { waiter.continuation.resume() }
  }

  /// Park a waiter for `target`. Caller must have already checked that the
  /// current count is below `target` in the same isolated, await-free run.
  mutating func install(id: UUID, target: Int, _ continuation: CheckedContinuation<Void, Never>) {
    waiters.append(Waiter(id: id, target: target, continuation: continuation))
  }

  /// Timeout-net resume: resolve a still-pending waiter by id (resume-once —
  /// removed first so `notify` cannot also resume it). Finding a pending waiter
  /// here means the target count never arrived within the timeout — a real
  /// signal failure, so record it as a test failure instead of letting the
  /// caller proceed as if the count was reached.
  mutating func resume(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    Issue.record("CountWaiters[\(label)] timed out waiting for count to reach \(waiter.target)")
    waiter.continuation.resume()
  }
}
