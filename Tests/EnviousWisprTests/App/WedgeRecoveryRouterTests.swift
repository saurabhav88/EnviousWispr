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
