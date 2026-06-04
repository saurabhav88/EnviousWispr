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
/// `loadModelClearsPollingOnTransportError` (#899) drives the *real*
/// `loadModel()` to its `serviceUnreachable` throw via the connection-preflight
/// seam, so deleting the production `defer { self.stopProgressPolling() }` makes
/// it red. (It supersedes the old `deferWrapPatternSimulation`, which only
/// re-implemented the pattern locally and passed because the test itself called
/// `stopProgressPolling`.)
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

  @Test(
    "loadModel stops progress polling when the XPC transport is unreachable",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/586",
      "XPC error leaks progress timer"
    )
  )
  func loadModelClearsPollingOnTransportError() async {
    // No-op connection preflight: the real XPC connection is never established,
    // so production's real `serviceProxy` nil-connection branch fires
    // `onProxyError` → `serviceUnreachable`. That drives the *real*
    // `defer { self.stopProgressPolling() }` inside `loadModel()` — the #586
    // leak guard. Deleting that defer leaves the timer alive after the awaited
    // throw, so this test goes red.
    let proxy = ASRManagerProxy(connectionPreflight: { _ in })

    await #expect(throws: XPCASRTransportError.self) {
      try await proxy.loadModel()
    }

    #expect(proxy.isProgressPollingActiveForTesting == false)
  }
}
