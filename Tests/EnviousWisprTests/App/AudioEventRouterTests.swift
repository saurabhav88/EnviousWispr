import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

/// PR8 of #763 — unit tests for `AudioEventRouter`.
///
/// Verifies callback installation on construction and that the route-change
/// observer invokes `captureTelemetry.incrementConfigChange()`. End-to-end
/// pipeline-state-flip routing under engine-interruption is covered by Live
/// UAT; here we lock the shape and the most catchable regressions.
@MainActor
@Suite("AudioEventRouter")
struct AudioEventRouterTests {

  @Test("init installs onEngineInterrupted, onXPCServiceError, and onVADAutoStop")
  func installsAudioCallbacks() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let telemetry = CaptureTelemetryState()

    #expect(audio.onEngineInterrupted == nil)
    #expect(audio.onXPCServiceError == nil)
    #expect(audio.onVADAutoStop == nil)

    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit,
      captureTelemetry: telemetry,
      resolveActiveCaptureBackend: { nil }
    )

    #expect(audio.onEngineInterrupted != nil)
    #expect(audio.onXPCServiceError != nil)
    #expect(audio.onVADAutoStop != nil)
    withExtendedLifetime(router) {}
  }

  @Test("AVAudioEngineConfigurationChange observer increments the config-change counter")
  func routeChangeObserverIncrementsTelemetry() async {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let telemetry = CaptureTelemetryState()

    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit,
      captureTelemetry: telemetry,
      resolveActiveCaptureBackend: { nil }
    )

    let baseline = telemetry.configurationChangeCount
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: nil)
    // The observer hops to @MainActor via Task — yield so the hop runs.
    await Task.yield()
    await Task.yield()

    #expect(telemetry.configurationChangeCount == baseline + 1)
    withExtendedLifetime(router) {}
  }

  @Test("resolveActiveCaptureBackend closure is invoked on engine interruption")
  func engineInterruptionCallsResolver() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let telemetry = CaptureTelemetryState()

    var resolverCallCount = 0
    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit,
      captureTelemetry: telemetry,
      resolveActiveCaptureBackend: {
        resolverCallCount += 1
        return nil
      }
    )

    audio.onEngineInterrupted?()

    #expect(resolverCallCount == 1)
    withExtendedLifetime(router) {}
  }
}
