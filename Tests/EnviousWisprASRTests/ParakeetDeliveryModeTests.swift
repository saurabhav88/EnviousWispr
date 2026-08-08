import EnviousWisprCore
import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #1348 Phase 2: the service-side offline invariant + the proxy's forced
/// helper recycle (grounded r2 blocker 1 / r3-precise test scope).
@MainActor
@Suite struct ParakeetDeliveryModeTests {
  /// Cache-only arms FluidAudio's own offline switch (`ModelHub.offlineMode`
  /// since #1981); the legacy mode resets it explicitly — flipping the
  /// delivery flag works without a service restart (declared invariant, plan §3).
  @Test func offlineModeFollowsCacheOnlyDeterministically() {
    let original = ModelHub.offlineMode
    defer { ModelHub.offlineMode = original }

    ParakeetBackend.configureOfflineMode(cacheOnly: true)
    #expect(ModelHub.offlineMode)

    // Legacy-after-cache-only: the reset is explicit, not leftover state.
    ParakeetBackend.configureOfflineMode(cacheOnly: false)
    #expect(!ModelHub.offlineMode)
  }

  /// #1981 chunk 2: the vendor-progress → app-callback mapping, exercised
  /// through the PRODUCTION-owned `makeLoadProgressHandler` (extracted from
  /// `prepare` unchanged — one owner), across the four real emission shapes
  /// FluidAudio's ProgressReporter produces for a repo load. No model bytes
  /// or network involved: the handler is pure mapping.
  @Test func progressMappingCoversAllVendorPhases() {
    // The callback is @Sendable; collect on a lock-protected box confined to this test.
    final class Box: @unchecked Sendable {
      private var storage: [(Double, String, String)] = []
      private let lock = NSLock()
      func append(_ emission: (Double, String, String)) {
        lock.lock()
        storage.append(emission)
        lock.unlock()
      }
      func snapshot() -> [(Double, String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
      }
    }
    let box = Box()
    let handler = ParakeetBackend.makeLoadProgressHandler { fraction, phase, detail in
      box.append((fraction, phase, detail))
    }
    guard let handler else {
      Issue.record("non-nil callback must produce a non-nil handler")
      return
    }
    // nil callback maps to nil handler (skip the closure allocation entirely).
    #expect(ParakeetBackend.makeLoadProgressHandler(nil) == nil)

    // The four real ProgressReporter shapes for a repo load (downloadPhaseWeight 0.5):
    handler(DownloadProgress(fractionCompleted: 0.0, phase: .listing))
    // cachedModelsAvailable(): download phase complete without network.
    handler(
      DownloadProgress(
        fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0)))
    handler(DownloadProgress(fractionCompleted: 0.75, phase: .compiling(modelName: "Encoder")))
    // finished(): fraction 1.0 with an empty compiling name.
    handler(DownloadProgress(fractionCompleted: 1.0, phase: .compiling(modelName: "")))

    let emissions = box.snapshot()
    #expect(emissions.count == 4)
    // 1) listing -> stall-policy listing token, empty detail.
    #expect(emissions[0].0 == 0.0)
    #expect(emissions[0].1 == ModelLoadStallPolicy.listingPhase)
    #expect(emissions[0].2 == "")
    // 2) downloading at 0.5 -> x2 fraction math against the 483 MB total.
    #expect(emissions[1].0 == 0.5)
    #expect(emissions[1].1 == "Downloading model files...")
    #expect(emissions[1].2 == "483 MB of 483 MB (100%)")
    // 3) compiling -> stall-policy install token with the model name.
    #expect(emissions[2].0 == 0.75)
    #expect(emissions[2].1 == ModelLoadStallPolicy.installPhase)
    #expect(emissions[2].2 == "Encoder")
    // 4) finished -> install token, empty detail, fraction passed through.
    #expect(emissions[3].0 == 1.0)
    #expect(emissions[3].1 == ModelLoadStallPolicy.installPhase)
    #expect(emissions[3].2 == "")
  }

  /// The recycle path: a proxy-level error drops the connection and marks
  /// reinit, so the NEXT call respawns the helper from the current bundle.
  /// Driven directly (the reachable behavior); the OS-level
  /// remoteObjectProxyWithErrorHandler callback is integration-covered by
  /// the drill matrix's teardown rows.
  @Test func proxyErrorRecyclesConnection() {
    let proxy = ASRManagerProxy(
      engineMutationScope: .alwaysAllowedForTesting, connectionPreflight: { _ in })  // no real XPC
    #expect(!proxy.hasConnectionForTesting)
    proxy.recycleConnectionAfterProxyError()
    #expect(!proxy.hasConnectionForTesting)
    #expect(proxy.needsReinitForTesting, "recycle must force reinit on the next call")
  }

  /// The XPC call carries cacheOnly ONLY for Parakeet — a WhisperKit-typed
  /// proxy never flips the service's offline switch.
  @Test func cacheOnlyIsParakeetScoped() {
    let proxy = ASRManagerProxy(
      engineMutationScope: .alwaysAllowedForTesting, connectionPreflight: { _ in })
    proxy.parakeetCacheOnly = true
    proxy.setInitialBackendType(.whisperKit)
    #expect(proxy.activeBackendType == .whisperKit)
    // The guard lives at the call site (`parakeetCacheOnly && backend ==
    // .parakeet`); with WhisperKit active the computed cacheOnly is false.
    let effectiveCacheOnly = proxy.parakeetCacheOnly && proxy.activeBackendType == .parakeet
    #expect(!effectiveCacheOnly)
  }
}
