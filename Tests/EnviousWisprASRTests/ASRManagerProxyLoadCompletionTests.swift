import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR

/// #1388 step 1 — the pending-load completion contract.
///
/// Production proved the per-call XPC error handler does NOT reliably fire for
/// a pending `loadModel` reply on invalidate/death: 119 of 126 wedge fires
/// reached no terminal outcome — the await hung and the caller's guard slot
/// leaked. The fix registers the load's one-shot continuation guard on the
/// proxy (`pendingLoadCompletion`) so EVERY completion source can resume it:
/// the XPC reply, the per-call proxy error, the invalidation/interruption
/// handlers, and an explicit `cancelInFlightLoad()`.
///
/// These tests pin the deterministic parts of that contract. The mid-flight
/// integration (kill the real ASR service during a real `loadModel`) is
/// runtime-only by nature and lives in the fault-injection drill
/// (`Tests/RuntimeUAT/faultInjection.py`, the #1388 mid-load kill scenario).
@MainActor
@Suite("ASRManagerProxy — #1388 load completion contract")
struct ASRManagerProxyLoadCompletionTests {

  @Test("cancelInFlightLoad with no load in flight is a safe no-op")
  func cancelWithNoLoadIsNoOp() {
    let proxy = ASRManagerProxy(connectionPreflight: { _ in })
    #expect(proxy.hasPendingLoadCompletionForTesting == false)
    proxy.cancelInFlightLoad()
    #expect(proxy.hasPendingLoadCompletionForTesting == false)
    #expect(proxy.isModelLoaded == false)
  }

  @Test("loadModel clears the pending completion on a thrown exit (no stale guard)")
  func pendingCompletionClearedOnThrow() async {
    // No-op preflight → nil connection → the real `serviceProxy` nil branch
    // fires `onProxyError` → the continuation resumes `serviceUnreachable`.
    // The identity-guarded defer must then clear the registered guard: a
    // stale non-nil guard here would let a LATER cancel/invalidation resume a
    // continuation that already completed (the one-shot drops it, but the
    // registration leak would still mask real pending state).
    let proxy = ASRManagerProxy(connectionPreflight: { _ in })
    await #expect(throws: XPCASRTransportError.self) {
      try await proxy.loadModel()
    }
    #expect(proxy.hasPendingLoadCompletionForTesting == false)
  }

  @Test("resume-once: the cancel cause beats a later death cause (first resume wins)")
  func firstResumeWinsCancelBeatsDeath() async {
    // The exact production ordering `cancelInFlightLoad` relies on: it resumes
    // the pending guard with the cancellation error FIRST, then invalidates
    // the connection — whose invalidation handler later attempts a duplicate
    // resume with `serviceUnreachable`. The one-shot guard must deliver the
    // FIRST cause and drop the second, or a user Cancel would surface as a
    // service death (and the adapter's transport retry would resurrect it).
    let thrown: any Error = await withCheckedContinuation { outer in
      Task { @MainActor in
        do {
          try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, any Error>) in
            let oneShot = OneShotContinuationASR(cont)
            oneShot.resume(throwing: ASRLoadCancelledError())
            oneShot.resume(throwing: XPCASRTransportError.serviceUnreachable)
          }
          Issue.record("the continuation must throw, not return")
          outer.resume(returning: CancellationError())
        } catch {
          outer.resume(returning: error)
        }
      }
    }
    #expect(
      thrown is ASRLoadCancelledError,
      "the first resume (cancel) must win; the death duplicate must be dropped")
  }

  @Test("resume-once: a death cause is delivered when it arrives first")
  func deathCauseDeliveredWhenFirst() async {
    let thrown: any Error = await withCheckedContinuation { outer in
      Task { @MainActor in
        do {
          try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, any Error>) in
            let oneShot = OneShotContinuationASR(cont)
            oneShot.resume(throwing: XPCASRTransportError.serviceUnreachable)
            oneShot.resume(throwing: ASRLoadCancelledError())
          }
          Issue.record("the continuation must throw, not return")
          outer.resume(returning: CancellationError())
        } catch {
          outer.resume(returning: error)
        }
      }
    }
    #expect(
      thrown is XPCASRTransportError,
      "a genuine death that resumes first is the true cause and must be delivered")
  }
}
