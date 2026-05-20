import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #585 — HeartControlRecovery extracted from the former root state.
///
/// These tests assert the recovery contract via injected closures + Sentry's
/// test-only `captureErrorDelegate` hook. CancellationError must be treated as
/// a coordinated unwind (no Sentry capture, no pipeline error surface), while
/// every other error must produce the full diagnostic trail.
@Suite("HeartControlRecovery (#585)")
@MainActor
struct HeartControlRecoveryTests {

  final class FakePipeline: DictationPipeline {
    var overlayIntent: OverlayIntent = .hidden
    var setExternalErrorCalls: [String] = []
    func handle(event: PipelineEvent) async throws {}
    func setExternalError(_ message: String) { setExternalErrorCalls.append(message) }
    func clearPendingStallRecovery() {}
  }

  final class CaptureSpy: @unchecked Sendable {
    // Test-only spy. @unchecked Sendable: accessed from the synchronous test body
    // via SentryBreadcrumb.captureErrorDelegate (also @Sendable). Single-threaded.
    var calls:
      [(
        error: any Error, category: SentryBreadcrumb.ErrorCategory, stage: String,
        extra: [String: Any]?
      )] = []
  }

  private func withSentrySpy(_ body: (CaptureSpy) -> Void) {
    let spy = CaptureSpy()
    SentryBreadcrumb.captureErrorDelegate = { error, category, stage, extra in
      spy.calls.append((error, category, stage, extra))
    }
    defer { SentryBreadcrumb.captureErrorDelegate = nil }
    body(spy)
  }

  private func makeRecovery(
    hideCalls: HideCallCounter, lockedCalls: LockedCallCounter, backend: String = "parakeet"
  )
    -> HeartControlRecovery
  {
    HeartControlRecovery(
      hideOverlay: { hideCalls.count += 1 },
      setLocked: { locked in lockedCalls.values.append(locked) },
      backend: { backend })
  }

  final class HideCallCounter { var count = 0 }
  final class LockedCallCounter { var values: [Bool] = [] }

  // MARK: - logDispatchFailure

  @Test("logDispatchFailure captures non-cancellation errors with op + backend in extras")
  func logDispatchFailureCapturesNonCancellation() {
    let hide = HideCallCounter()
    let locked = LockedCallCounter()
    let recovery = makeRecovery(hideCalls: hide, lockedCalls: locked, backend: "whisperkit")
    withSentrySpy { spy in
      struct E: Error {}
      recovery.logDispatchFailure(E(), op: "stop")
      #expect(spy.calls.count == 1)
      #expect(spy.calls.first?.category == .pipelineDispatchFailed)
      #expect(spy.calls.first?.stage == "recording")
      #expect(spy.calls.first?.extra?["op"] as? String == "stop")
      #expect(spy.calls.first?.extra?["backend"] as? String == "whisperkit")
    }
    #expect(hide.count == 0, "log-only path must not touch overlay")
    #expect(locked.values.isEmpty, "log-only path must not touch lock")
  }

  @Test("logDispatchFailure swallows CancellationError silently")
  func logDispatchFailureSwallowsCancellation() {
    let hide = HideCallCounter()
    let locked = LockedCallCounter()
    let recovery = makeRecovery(hideCalls: hide, lockedCalls: locked)
    withSentrySpy { spy in
      recovery.logDispatchFailure(CancellationError(), op: "stop")
      #expect(spy.calls.isEmpty, "CancellationError must not produce a Sentry capture")
    }
    #expect(hide.count == 0)
    #expect(locked.values.isEmpty)
  }

  // MARK: - recover

  @Test(
    "recover on non-cancellation: captures + hides overlay + clears lock + surfaces pipeline message"
  )
  func recoverNonCancellationFullRecovery() {
    let hide = HideCallCounter()
    let locked = LockedCallCounter()
    let pipeline = FakePipeline()
    let recovery = makeRecovery(hideCalls: hide, lockedCalls: locked, backend: "parakeet")
    withSentrySpy { spy in
      struct BoomError: Error {}
      recovery.recover(error: BoomError(), pipeline: pipeline, op: "toggle", message: "Try again.")
      #expect(spy.calls.count == 1)
      #expect(spy.calls.first?.extra?["op"] as? String == "toggle")
      #expect(spy.calls.first?.extra?["backend"] as? String == "parakeet")
    }
    #expect(hide.count == 1, "overlay must be hidden")
    #expect(locked.values == [false], "lock must be cleared")
    #expect(pipeline.setExternalErrorCalls == ["Try again."])
  }

  @Test(
    "recover on CancellationError: hides overlay + clears lock but skips Sentry + pipeline message")
  func recoverCancellationSilentReset() {
    let hide = HideCallCounter()
    let locked = LockedCallCounter()
    let pipeline = FakePipeline()
    let recovery = makeRecovery(hideCalls: hide, lockedCalls: locked)
    withSentrySpy { spy in
      recovery.recover(
        error: CancellationError(), pipeline: pipeline, op: "toggle", message: "Try again.")
      #expect(spy.calls.isEmpty, "CancellationError must not capture to Sentry")
    }
    #expect(hide.count == 1, "overlay must still be hidden so user UI isn't stuck")
    #expect(locked.values == [false], "lock must still be cleared")
    #expect(
      pipeline.setExternalErrorCalls.isEmpty,
      "cancellation must NOT surface a user-facing error on the pipeline")
  }

  @Test("recover passes op string verbatim — distinguishes call sites at triage time")
  func recoverPassesOpVerbatim() {
    let hide = HideCallCounter()
    let locked = LockedCallCounter()
    let pipeline = FakePipeline()
    let recovery = makeRecovery(hideCalls: hide, lockedCalls: locked)
    withSentrySpy { spy in
      struct E: Error {}
      recovery.recover(
        error: E(), pipeline: pipeline, op: "toggle-from-prewarm", message: "")
      #expect(spy.calls.first?.extra?["op"] as? String == "toggle-from-prewarm")
    }
  }
}
