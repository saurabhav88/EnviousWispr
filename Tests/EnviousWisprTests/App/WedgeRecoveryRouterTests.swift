import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

/// PR8 of #763 — unit tests for `WedgeRecoveryRouter`.
@MainActor
@Suite("WedgeRecoveryRouter")
struct WedgeRecoveryRouterTests {

  @Test("init installs the capture-stall callback on audioCapture")
  func installsWedgeCallbacks() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    #expect(audio.onCaptureStalled == nil)

    let router = WedgeRecoveryRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: { nil }
    )

    #expect(audio.onCaptureStalled != nil)
    // #1578: the refusal callback rides the same funnel and must be installed
    // by the same initializer — an uninstalled one is a silent dead route.
    #expect(audio.onZeroSignalRefused != nil)
    withExtendedLifetime(router) {}
  }

  // MARK: - #1578 — the refusal callback's delivery contract
  //
  // Every exit must return the right Boolean, because `false` is what tells the
  // capture manager to KEEP the context for a terminal drain. A router that
  // returned `true` on a dropped callback would lose the observation silently,
  // which is the exact failure the void-returning stall callback above cannot
  // even detect.

  /// Records what a telemetry target actually received.
  private final class RefusalSpy: HeartPathTelemetryTarget {
    var stalls: [CaptureStallContext] = []
    var refusals: [ZeroSignalRefusalContext] = []
    func handleCaptureStall(_ ctx: CaptureStallContext) { stalls.append(ctx) }
    func handleZeroSignalRefusal(_ context: ZeroSignalRefusalContext) {
      refusals.append(context)
    }
  }

  private static func refusalContext(sessionID: UInt64) -> ZeroSignalRefusalContext {
    ZeroSignalRefusalContext(
      sessionID: sessionID,
      reason: .deviceMuted,
      transport: "usb",
      failureShape: .becameZeroMidCapture)
  }

  private static func makeRouter(
    audio: RouterTestAudioCapture,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?
  ) -> WedgeRecoveryRouter {
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    return WedgeRecoveryRouter(
      audioCapture: audio,
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store),
      whisperKitKernelDriver: DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store),
      isCurrentSession: isCurrentSession,
      resolveActiveTelemetryTarget: resolveActiveTelemetryTarget)
  }

  @Test("#1578: a stale refusal returns false without consulting the resolver")
  func staleRefusalReturnsFalse() {
    let audio = RouterTestAudioCapture()
    let spy = RefusalSpy()
    var sessionFilterCalls: [UInt64] = []
    var resolverCallCount = 0

    let router = Self.makeRouter(
      audio: audio,
      isCurrentSession: { sessionID in
        sessionFilterCalls.append(sessionID)
        return false
      },
      resolveActiveTelemetryTarget: {
        resolverCallCount += 1
        return spy
      })

    let delivered = audio.onZeroSignalRefused?(Self.refusalContext(sessionID: 7))

    #expect(delivered == false)
    #expect(sessionFilterCalls == [7])
    // The staleness check must come FIRST — resolving a target for a session
    // that has already ended is work the router should never do.
    #expect(resolverCallCount == 0)
    #expect(spy.refusals.isEmpty)
    withExtendedLifetime(router) {}
  }

  @Test("#1578: a current-session refusal with no active target returns false")
  func noTargetRefusalReturnsFalse() {
    let audio = RouterTestAudioCapture()
    var resolverCallCount = 0

    let router = Self.makeRouter(
      audio: audio,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: {
        resolverCallCount += 1
        return nil
      })

    let delivered = audio.onZeroSignalRefused?(Self.refusalContext(sessionID: 1))

    // Nothing consumed it, so the producer must keep it.
    #expect(delivered == false)
    #expect(resolverCallCount == 1)
    withExtendedLifetime(router) {}
  }

  @Test("#1578: a delivered refusal returns true and reaches the target exactly once")
  func deliveredRefusalReturnsTrue() {
    let audio = RouterTestAudioCapture()
    let spy = RefusalSpy()

    let router = Self.makeRouter(
      audio: audio,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: { spy })

    let context = Self.refusalContext(sessionID: 42)
    let delivered = audio.onZeroSignalRefused?(context)

    // `true` must mean the target's method actually ran, not merely that a
    // target existed.
    #expect(delivered == true)
    #expect(spy.refusals == [context])
    // The refusal route must not touch the stall route.
    #expect(spy.stalls.isEmpty)
    withExtendedLifetime(router) {}
  }

  @Test("isCurrentSession filter drops stale callbacks (resolver not consulted)")
  func staleCallbacksDropped() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    var sessionFilterCalls: [UInt64] = []
    var resolverCallCount = 0

    let router = WedgeRecoveryRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
      isCurrentSession: { sessionID in
        sessionFilterCalls.append(sessionID)
        return false  // always stale
      },
      resolveActiveTelemetryTarget: {
        resolverCallCount += 1
        return nil
      }
    )

    audio.onCaptureStalled?(DictationRuntimeFixtures.captureStallContext(sessionID: 7))

    #expect(sessionFilterCalls == [7])
    #expect(resolverCallCount == 0)
    withExtendedLifetime(router) {}
  }

  @Test("isCurrentSession=true forwards to resolveActiveTelemetryTarget")
  func freshCallbacksReachResolver() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    var resolverCallCount = 0

    let router = WedgeRecoveryRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: {
        resolverCallCount += 1
        return nil
      }
    )

    audio.onCaptureStalled?(DictationRuntimeFixtures.captureStallContext(sessionID: 1))

    #expect(resolverCallCount == 1)
    withExtendedLifetime(router) {}
  }
}
