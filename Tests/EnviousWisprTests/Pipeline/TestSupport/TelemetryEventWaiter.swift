#if DEBUG

  import EnviousWisprServices
  import Foundation

  /// Test-only waiter for `TelemetryService.testEventHook` emissions (#1283).
  ///
  /// Lets a test `await` a SPECIFIC telemetry event instead of guessing a fixed
  /// `Task.sleep` for a deferred hook to drain. Replaces the hand-rolled event
  /// boxes + `Task.sleep(5ms)` / double-`Task.yield()` drains that flaked on
  /// contended CI runners (`DualModePolishTelemetryTests`,
  /// `UpdateCoordinatorProactiveCheckTests`) and the state-proxy-then-read
  /// signal mismatches (`EngineCoordinatorTests`).
  ///
  /// `TelemetryService` is `@MainActor` (`TelemetryService.swift`) and invokes
  /// `testEventHook?(…)` SYNCHRONOUSLY from its @MainActor emit methods — never
  /// off-actor — so the hook records via `MainActor.assumeIsolated { record(_:) }`,
  /// a synchronous record with NO `Task { @MainActor }` hop. That deferring hop
  /// was the origin of the flakes this replaces; recording synchronously keeps
  /// the history as immediate as the old `@unchecked Sendable` NSLock boxes, so
  /// count/contains/negative-window reads are not regressed.
  ///
  /// Mirrors `SignalPipelineLogger`: `@MainActor` isolation makes the
  /// "already present?" check and the waiter install atomic (no `await` between);
  /// each waiter has a UUID so it resumes exactly once (removed before resume);
  /// an internal timeout task guarantees a never-arriving event surfaces as a
  /// fast failure instead of a hang (swift-patterns.md
  /// `tests-no-unconditional-continuation-await`).
  @MainActor
  final class TelemetryEventWaiter {
    private struct Waiter {
      let id: UUID
      let predicate: (CapturedTelemetryEvent) -> Bool
      let describedAs: String
      let timeoutSeconds: Double
      let continuation: CheckedContinuation<CapturedTelemetryEvent, Error>
    }

    /// Full history of recorded events — a strict superset of the hand-rolled
    /// event boxes, so `count` / `contains` reads use this directly.
    private(set) var events: [CapturedTelemetryEvent] = []
    private var waiters: [Waiter] = []

    /// Record an emitted event and resume every waiter whose predicate now
    /// matches (removed first so a later event cannot resume it twice).
    func record(_ event: CapturedTelemetryEvent) {
      events.append(event)
      let matching = waiters.filter { $0.predicate(event) }
      waiters.removeAll { waiter in matching.contains { $0.id == waiter.id } }
      for waiter in matching { waiter.continuation.resume(returning: event) }
    }

    /// Await the next event whose `name` equals `name`. Returns immediately if
    /// one is already recorded; else parks until it arrives, throwing
    /// `TelemetryWaiterTimeout` if none does within `timeout` (fail fast).
    @discardableResult
    func waitForEvent(
      named name: String,
      timeout: Duration = .seconds(5)
    ) async throws -> CapturedTelemetryEvent {
      try await waitForEvent(
        matching: { $0.name == name }, describedAs: name, timeout: timeout)
    }

    @discardableResult
    func waitForEvent(
      matching predicate: @escaping (CapturedTelemetryEvent) -> Bool,
      describedAs description: String,
      timeout: Duration = .seconds(5)
    ) async throws -> CapturedTelemetryEvent {
      if let existing = events.last(where: predicate) { return existing }

      let id = UUID()
      let seconds =
        Double(timeout.components.seconds)
        + Double(timeout.components.attoseconds) / 1e18
      return try await withCheckedThrowingContinuation { continuation in
        waiters.append(
          Waiter(
            id: id, predicate: predicate, describedAs: description,
            timeoutSeconds: seconds, continuation: continuation))
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.timeoutWaiter(id)
        }
      }
    }

    private func timeoutWaiter(_ id: UUID) {
      guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
      let waiter = waiters.remove(at: index)
      waiter.continuation.resume(
        throwing: TelemetryWaiterTimeout(
          event: waiter.describedAs, seconds: waiter.timeoutSeconds))
    }
  }

  /// Thrown when a `TelemetryEventWaiter` deadline elapses before a matching
  /// event arrives — names the awaited event so the test failure is actionable.
  struct TelemetryWaiterTimeout: Error, CustomStringConvertible {
    let event: String
    let seconds: Double
    var description: String {
      "TelemetryEventWaiter timed out after \(seconds)s waiting for event: \(event)"
    }
  }

#endif  // DEBUG
