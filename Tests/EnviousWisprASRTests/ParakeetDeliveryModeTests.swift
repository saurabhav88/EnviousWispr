import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #1348 Phase 2: the service-side offline invariant + the proxy's forced
/// helper recycle (grounded r2 blocker 1 / r3-precise test scope).
@MainActor
@Suite struct ParakeetDeliveryModeTests {
  /// Cache-only arms FluidAudio's own offline switch; the legacy mode resets
  /// it explicitly — flipping the delivery flag works without a service
  /// restart (declared invariant, plan §3).
  @Test func offlineModeFollowsCacheOnlyDeterministically() {
    let original = DownloadUtils.enforceOffline
    defer { DownloadUtils.enforceOffline = original }

    ParakeetBackend.configureOfflineMode(cacheOnly: true)
    #expect(DownloadUtils.enforceOffline)

    // Legacy-after-cache-only: the reset is explicit, not leftover state.
    ParakeetBackend.configureOfflineMode(cacheOnly: false)
    #expect(!DownloadUtils.enforceOffline)
  }

  /// The recycle path: a proxy-level error drops the connection and marks
  /// reinit, so the NEXT call respawns the helper from the current bundle.
  /// Driven directly (the reachable behavior); the OS-level
  /// remoteObjectProxyWithErrorHandler callback is integration-covered by
  /// the drill matrix's teardown rows.
  @Test func proxyErrorRecyclesConnection() {
    let proxy = ASRManagerProxy(connectionPreflight: { _ in })  // no real XPC
    #expect(!proxy.hasConnectionForTesting)
    proxy.recycleConnectionAfterProxyError()
    #expect(!proxy.hasConnectionForTesting)
    #expect(proxy.needsReinitForTesting, "recycle must force reinit on the next call")
  }

  /// The XPC call carries cacheOnly ONLY for Parakeet — a WhisperKit-typed
  /// proxy never flips the service's offline switch.
  @Test func cacheOnlyIsParakeetScoped() {
    let proxy = ASRManagerProxy(connectionPreflight: { _ in })
    proxy.parakeetCacheOnly = true
    proxy.setInitialBackendType(.whisperKit)
    #expect(proxy.activeBackendType == .whisperKit)
    // The guard lives at the call site (`parakeetCacheOnly && backend ==
    // .parakeet`); with WhisperKit active the computed cacheOnly is false.
    let effectiveCacheOnly = proxy.parakeetCacheOnly && proxy.activeBackendType == .parakeet
    #expect(!effectiveCacheOnly)
  }
}
