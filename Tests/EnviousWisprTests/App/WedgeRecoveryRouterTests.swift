import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

/// PR8 of #763 — unit tests for `WedgeRecoveryRouter`.
@MainActor
@Suite("WedgeRecoveryRouter")
struct WedgeRecoveryRouterTests {

  @Test("init installs the three wedge callbacks on audioCapture")
  func installsWedgeCallbacks() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    #expect(audio.onCaptureStalled == nil)
    #expect(audio.onXPCReplyFailed == nil)
    #expect(audio.onCaptureSessionInterruption == nil)

    let router = WedgeRecoveryRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: { nil }
    )

    #expect(audio.onCaptureStalled != nil)
    #expect(audio.onXPCReplyFailed != nil)
    #expect(audio.onCaptureSessionInterruption != nil)
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
      whisperKitPipeline: whisperKit,
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
    audio.onXPCReplyFailed?(
      DictationRuntimeFixtures.xpcReplyFailureContext(sessionID: 8))
    audio.onCaptureSessionInterruption?(
      DictationRuntimeFixtures.captureSessionInterruptionContext(sessionID: 9))

    #expect(sessionFilterCalls == [7, 8, 9])
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
      whisperKitPipeline: whisperKit,
      isCurrentSession: { _ in true },
      resolveActiveTelemetryTarget: {
        resolverCallCount += 1
        return nil
      }
    )

    audio.onCaptureStalled?(DictationRuntimeFixtures.captureStallContext(sessionID: 1))
    audio.onXPCReplyFailed?(
      DictationRuntimeFixtures.xpcReplyFailureContext(sessionID: 1))
    audio.onCaptureSessionInterruption?(
      DictationRuntimeFixtures.captureSessionInterruptionContext(sessionID: 1))

    #expect(resolverCallCount == 3)
    withExtendedLifetime(router) {}
  }
}
