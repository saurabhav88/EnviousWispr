import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// PR8 of #763 — unit tests for `ASREventRouter`.
@MainActor
@Suite("ASREventRouter")
struct ASREventRouterTests {

  @Test("init installs onServiceInterrupted on the ASR manager")
  func installsServiceInterruptedCallback() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetPipeline(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    #expect(asr.onServiceInterrupted == nil)

    let router = ASREventRouter(
      asrManager: asr,
      pipeline: parakeet,
      whisperKitPipeline: whisperKit
    )

    #expect(asr.onServiceInterrupted != nil)
    withExtendedLifetime(router) {}
  }

  @Test("onServiceInterrupted is invokable without crashing when both pipelines idle")
  func serviceInterruptedSafeWhenIdle() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetPipeline(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    let router = ASREventRouter(
      asrManager: asr,
      pipeline: parakeet,
      whisperKitPipeline: whisperKit
    )

    // Both pipelines are idle (.idle is the default state). The callback
    // should no-op without dispatching to either pipeline. The test passes
    // as long as no precondition fires.
    asr.onServiceInterrupted?()
    withExtendedLifetime(router) {}
  }
}
