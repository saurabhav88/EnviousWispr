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

  #if DEBUG
    // `kernelForTesting` + `testForceTransition` are DEBUG-only seams (per
    // KernelDictationDriver:411-425 and RecordingSessionKernel:1730-1746).
    // Existing kernel-FSM-driving tests (RecordingSessionKernelTests,
    // KernelHeartPathTelemetryObserverTests) wrap themselves in `#if DEBUG`
    // for the same reason — `build-check` never compiles the test target in
    // release, but the gate keeps a release-config `swift test` honest
    // (PR #838 / `gotchas-release.md`).
    @Test("ASR XPC crash during Parakeet polishing leaves the safe point alone")
    func serviceInterruptedDuringParakeetPolishingIsIgnored() async {
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      let store = DictationRuntimeFixtures.tempStore()
      let driver = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store)
      let router = ASREventRouter(
        asrManager: asr,
        kernelDriver: driver,
        whisperKitPipeline: whisperKit
      )

      // Walk the kernel FSM through the legal edges so it lands in
      // `.finalizing`; the public mapping at
      // KernelDictationDriver.pipelineState(for:externalError:) returns
      // `.polishing` for that state, which is the safe-point window the
      // router must NOT interrupt on ASR XPC crash.
      let kernel = driver.kernelForTesting
      #expect(kernel.testForceTransition(to: .preparing))
      #expect(kernel.testForceTransition(to: .recording))
      #expect(kernel.testForceTransition(to: .stopping))
      #expect(kernel.testForceTransition(to: .transcribing))
      #expect(kernel.testForceTransition(to: .finalizing))
      #expect(driver.state == .polishing)
      asr.onServiceInterrupted?()
      await Task.yield()

      #expect(driver.state == .polishing)
      withExtendedLifetime(router) {}
    }
  #endif

  @Test("ASR XPC crash during WhisperKit polishing leaves the safe point alone")
  func serviceInterruptedDuringWhisperKitPolishingIsIgnored() async {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let driver = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let router = ASREventRouter(
      asrManager: asr,
      kernelDriver: driver,
      whisperKitPipeline: whisperKit
    )

    whisperKit.llmPolish.onWillProcess?()
    #expect(whisperKit.state == .polishing)
    asr.onServiceInterrupted?()
    await Task.yield()

    #expect(whisperKit.state == .polishing)
    withExtendedLifetime(router) {}
  }
}
