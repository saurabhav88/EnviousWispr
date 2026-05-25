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
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    // Post-PR-4b.4 of #827: `makeParakeetDriver` runs the factory which
    // constructs `ParakeetEngineAdapter`, and the adapter installs an
    // `asrManager.onServiceInterrupted` handler of its own (legacy two-hop
    // bridge to `adapter.onEngineInterrupted`). The App router overwrites
    // this on construction below — last-write-wins, and the App route via
    // `kernelDriver.handleASRServiceInterruption()` is now authoritative.
    // The pre-construction handler is therefore non-nil; what the test
    // actually validates is that constructing the router installs a fresh
    // (router-owned) handler and the post-construction reference reaches it.
    let priorHandler = asr.onServiceInterrupted

    let router = ASREventRouter(
      asrManager: asr,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit
    )

    #expect(asr.onServiceInterrupted != nil)
    // Confirms the router REPLACED the adapter's installation rather than
    // running additively — identity check rules out a chain wrapper.
    #expect(asr.onServiceInterrupted as AnyObject? !== priorHandler as AnyObject?)
    withExtendedLifetime(router) {}
  }

  @Test("onServiceInterrupted is invokable without crashing when both pipelines idle")
  func serviceInterruptedSafeWhenIdle() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)

    let router = ASREventRouter(
      asrManager: asr,
      kernelDriver: parakeet,
      whisperKitPipeline: whisperKit
    )

    // Both pipelines are idle (.idle is the default state). The callback
    // should no-op without dispatching to either pipeline. The test passes
    // as long as no precondition fires.
    asr.onServiceInterrupted?()
    withExtendedLifetime(router) {}
  }
}
