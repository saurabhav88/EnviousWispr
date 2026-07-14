import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
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
      whisperKitKernelDriver: whisperKit
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
      whisperKitKernelDriver: whisperKit
    )

    // Both pipelines are idle (.idle is the default state). The idle branch
    // only logs — it must not dispatch into either driver. #881 TO-3: pin that
    // by asserting both drivers stay .idle after the callback (the prior test
    // had zero #expect, so a future idle-branch side effect that flipped a
    // driver off .idle would have gone uncaught here).
    asr.onServiceInterrupted?()
    #expect(parakeet.state == .idle)
    #expect(whisperKit.state == .idle)
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
        whisperKitKernelDriver: whisperKit
      )

      // Walk the kernel FSM through the legal edges so it lands in
      // `.finalizing`; the public mapping at
      // KernelDictationDriver.pipelineState(for:externalError:) returns
      // `.polishing` for that state, which is the safe-point window the
      // router must NOT interrupt on ASR XPC crash.
      let kernel = driver.kernelForTesting
      #expect(kernel.testForceTransition(to: .arming))
      #expect(kernel.testForceTransition(to: .live))
      #expect(kernel.testForceTransition(to: .stopping))
      #expect(kernel.testForceTransition(to: .delivering))
      kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      #expect(driver.state == .polishing)
      asr.onServiceInterrupted?()
      await Task.yield()

      #expect(driver.state == .polishing)
      // Codex PR #990 P2 (#959): the safe point includes the marker side
      // effect, not just the FSM state — a crash during polishing is not an
      // idle reap. A stale marker would route the NEXT not-ready press
      // through warm-respawn (skipping the cold pill) and pollute
      // `coldstart.service_reclaimed` telemetry.
      #expect(driver.residentModelLostWhileIdle == false)
      withExtendedLifetime(router) {}
    }
  #endif

  #if DEBUG
    @Test("ASR XPC crash during WhisperKit polishing leaves the safe point alone")
    func serviceInterruptedDuringWhisperKitPolishingIsIgnored() async {
      // PR-5 Rung 5 (#827): WhisperKit is now a second kernel driver, so the
      // FSM-walk shape mirrors the Parakeet test above. The legacy approach
      // (driving `.polishing` via `whisperKit.llmPolish.onWillProcess?()`)
      // relied on the deleted pipeline's bespoke state-change side effect;
      // walk the kernel FSM through `.preparing → .recording → .stopping →
      // .transcribing → .finalizing` instead, which maps to driver state
      // `.polishing` via `KernelDictationDriver.pipelineState(for:...)`.
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      asr.activeBackendType = .whisperKit
      let store = DictationRuntimeFixtures.tempStore()
      let driver = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store)
      let router = ASREventRouter(
        asrManager: asr,
        kernelDriver: driver,
        whisperKitKernelDriver: whisperKit
      )

      let kernel = whisperKit.kernelForTesting
      #expect(kernel.testForceTransition(to: .arming))
      #expect(kernel.testForceTransition(to: .live))
      #expect(kernel.testForceTransition(to: .stopping))
      #expect(kernel.testForceTransition(to: .delivering))
      kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      #expect(whisperKit.state == .polishing)
      asr.onServiceInterrupted?()
      await Task.yield()

      #expect(whisperKit.state == .polishing)
      // Codex PR #990 P2 (#959): same marker discipline as the Parakeet
      // polishing test above — a WhisperKit session mid-polish means the
      // system is not idle, so the Parakeet driver must not be marked.
      #expect(driver.residentModelLostWhileIdle == false)
      withExtendedLifetime(router) {}
    }
  #endif

  // MARK: - #959 idle reap → resident-model-lost marker

  @Test("idle ASR reap sets the resident-model-lost marker on the Parakeet driver")
  func idleReapSetsResidentModelLostMarker() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let router = ASREventRouter(
      asrManager: asr, kernelDriver: parakeet, whisperKitKernelDriver: whisperKit)

    #expect(parakeet.residentModelLostWhileIdle == false)
    // Both pipelines idle → `onServiceInterrupted` (fired only when a resident
    // model was lost) is the reap-while-idle case → marker is set.
    asr.onServiceInterrupted?()
    #expect(parakeet.residentModelLostWhileIdle == true)
    withExtendedLifetime(router) {}
  }

  #if DEBUG
    @Test("active ASR interruption routes to the driver and does NOT set the idle marker")
    func activeInterruptionDoesNotSetIdleMarker() async {
      let audio = RouterTestAudioCapture()
      let asr = RouterTestASRManager()
      let store = DictationRuntimeFixtures.tempStore()
      let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store)
      let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
        audioCapture: audio, store: store)
      let router = ASREventRouter(
        asrManager: asr, kernelDriver: parakeet, whisperKitKernelDriver: whisperKit)

      let kernel = parakeet.kernelForTesting
      #expect(kernel.testForceTransition(to: .arming))
      #expect(kernel.testForceTransition(to: .live))
      #expect(parakeet.state == .recording)
      asr.onServiceInterrupted?()
      await Task.yield()

      // Active session → the crash routes to `handleASRServiceInterruption`,
      // NOT the idle-reap marker branch.
      #expect(parakeet.residentModelLostWhileIdle == false)
      withExtendedLifetime(router) {}
    }
  #endif
}
