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

  @Test("startProgressPolling schedules a live timer on the main run loop")
  func startActivates() throws {
    let proxy = ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting)
    #expect(proxy.progressPollTimerForTesting == nil)

    proxy.startProgressPolling()
    let timer = try #require(proxy.progressPollTimerForTesting)
    // The timer must be live AND actually scheduled on the main run loop. The
    // old `!= nil` flag (and even a plain `isValid` check) stayed green if
    // `RunLoop.main.add` were deleted — a stored-but-never-scheduled `Timer`
    // is still valid and non-nil, yet never fires. `CFRunLoopContainsTimer`
    // checks the scheduling deterministically and synchronously, without
    // firing the timer or touching the shared `ProgressFile` (a real-timer
    // test would need both, which `tests-no-real-time-scheduling-precision`
    // and the process-global-state guidance steer away from). Production adds
    // the timer to `RunLoop.main` `.common` modes, so check `.commonModes`.
    #expect(timer.isValid)  // not invalidated / not a dead timer
    #expect(
      CFRunLoopContainsTimer(CFRunLoopGetMain(), timer as CFRunLoopTimer, .commonModes),
      "the polling timer must be scheduled on the main run loop, not merely stored")

    proxy.stopProgressPolling()
  }

  @Test("stopProgressPolling clears the timer (the defer-cleanup invariant)")
  func stopClears() {
    let proxy = ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting)
    proxy.startProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == true)

    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("re-arming via startProgressPolling invalidates the prior timer (no leak)")
  func reArmingDoesNotLeak() {
    let proxy = ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting)
    proxy.startProgressPolling()
    let firstTimer = proxy.progressPollTimerForTesting
    #expect(firstTimer?.isValid == true)

    // Re-arm without an explicit stop. startProgressPolling's first line calls
    // stopProgressPolling(), which invalidates the prior timer before scheduling
    // a new one. Holding the prior timer reference lets us PROVE that: a leak
    // (the old timer left running on the run loop) is invisible through the
    // `!= nil` flag, which only ever sees the newest timer. If that cleanup is
    // removed, firstTimer stays valid and this reddens.
    proxy.startProgressPolling()
    let secondTimer = proxy.progressPollTimerForTesting
    #expect(firstTimer?.isValid == false, "the prior timer must be invalidated, not leaked")
    #expect(secondTimer?.isValid == true, "the re-armed timer is live")
    #expect(firstTimer !== secondTimer, "re-arm installs a distinct timer")

    proxy.stopProgressPolling()
    #expect(proxy.progressPollTimerForTesting == nil)
  }

  @Test("stopProgressPolling is idempotent — calling twice is safe")
  func stopIsIdempotent() {
    let proxy = ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting)
    proxy.startProgressPolling()
    proxy.stopProgressPolling()
    proxy.stopProgressPolling()
    #expect(proxy.isProgressPollingActiveForTesting == false)
  }

  @Test("stopProgressPolling on a never-started proxy is a no-op")
  func stopOnNeverStartedProxy() {
    let proxy = ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting)
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
    let proxy = ASRManagerProxy(
      engineMutationScope: .alwaysAllowedForTesting, connectionPreflight: { _ in })

    await #expect(throws: XPCASRTransportError.self) {
      try await proxy.loadModel()
    }

    #expect(proxy.isProgressPollingActiveForTesting == false)
  }
}
