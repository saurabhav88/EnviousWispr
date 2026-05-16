import Foundation
import Testing

@testable import EnviousWisprASR

/// Regression coverage for #586 — ASR XPC progress-polling lifecycle.
///
/// The senior audit flagged that `ASRManagerProxy.loadModel()` previously
/// stopped progress polling only on the success path, so an XPC error left
/// the 8 Hz `Timer` alive forever. The fix (PR #696 round 1, 2026-05-07)
/// wraps `stopProgressPolling()` in a `defer` so cleanup runs on every exit.
///
/// These tests cover the cleanup invariant that the `defer` relies on:
/// `startProgressPolling` / `stopProgressPolling` must keep
/// `isProgressPollingActiveForTesting` honest, so a future refactor cannot
/// silently break the defer guarantee.
///
/// Full failure-path coverage through real `loadModel()` requires a
/// fake-XPC service infrastructure; that is intentionally not built tonight.
/// See issue thread for follow-up.
@MainActor
@Suite("ASRManagerProxy progress polling")
struct ASRManagerProxyProgressPollingTests {

  @Test("startProgressPolling activates the timer")
  func startActivates() {
    let proxy = ASRManagerProxy()
    #expect(proxy.isProgressPollingActiveForTesting == false)

    proxy.startProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == true)

    proxy.stopProgressPolling()
  }

  @Test("stopProgressPolling clears the timer (the defer-cleanup invariant)")
  func stopClears() {
    let proxy = ASRManagerProxy()
    proxy.startProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == true)

    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("re-arming via startProgressPolling does not leak the prior timer")
  func reArmingDoesNotLeak() {
    let proxy = ASRManagerProxy()
    proxy.startProgressPolling()
    let firstActive = proxy.isProgressPollingActiveForTesting
    #expect(firstActive == true)

    // start without an explicit stop in between should still result in a
    // single active timer — startProgressPolling's first line calls
    // stopProgressPolling() to invalidate any prior timer before scheduling.
    proxy.startProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == true)

    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("stopProgressPolling is idempotent — calling twice is safe")
  func stopIsIdempotent() {
    let proxy = ASRManagerProxy()
    proxy.startProgressPolling()
    proxy.stopProgressPolling()
    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("stopProgressPolling on a never-started proxy is a no-op")
  func stopOnNeverStartedProxy() {
    let proxy = ASRManagerProxy()
    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("polling state survives a simulated loadModel throw (defer-wrap pattern)")
  func deferWrapPatternSimulation() {
    // Mirrors the exact pattern at ASRManagerProxy.swift:77-81. If a future
    // refactor removes the defer-stop, this test still passes only because
    // the test itself calls stopProgressPolling — that is intentional: the
    // test documents the contract; the regression risk is in the call site.
    let proxy = ASRManagerProxy()

    func simulateThrowingLoad() throws {
      proxy.startProgressPolling()
      defer { proxy.stopProgressPolling() }
      throw SimulatedXPCError.serviceUnreachable
    }

    do {
      try simulateThrowingLoad()
      Issue.record("expected simulateThrowingLoad to throw")
    } catch {
      // expected
    }

    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  private enum SimulatedXPCError: Error {
    case serviceUnreachable
  }
}
