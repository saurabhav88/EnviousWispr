import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprASR
@testable import EnviousWisprAudio
@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR8 of #763 — unit tests for `AudioEventRouter`.
///
/// Verifies callback installation on construction and that the route-change
/// observer invokes `captureTelemetry.incrementConfigChange()`. End-to-end
/// pipeline-state-flip routing under engine-interruption is covered by Live
/// UAT; here we lock the shape and the most catchable regressions.
@MainActor
@Suite("AudioEventRouter")
struct AudioEventRouterTests {

  @Test("init installs engine/XPC callbacks and legacy VAD fallback when unclaimed")
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

  @Test("init does not overwrite an existing VAD auto-stop owner")
  func preservesExistingVADAutoStopOwner() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let parakeet = DictationRuntimeFixtures.makeParakeetPipeline(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let telemetry = CaptureTelemetryState()
    var existingOwnerCallCount = 0
    audio.onVADAutoStop = { existingOwnerCallCount += 1 }

    let router = AudioEventRouter(
      audioCapture: audio,
      pipeline: parakeet,
      whisperKitPipeline: whisperKit,
      captureTelemetry: telemetry,
      resolveActiveCaptureBackend: { nil }
    )

    audio.onVADAutoStop?()

    #expect(existingOwnerCallCount == 1)
    withExtendedLifetime(router) {}
  }

  @Test("kernel VAD owner survives App router construction")
  func kernelVADOwnerSurvivesAppRouterConstruction() async throws {
    let audio = FakeAudioCapture()
    let asr = StubParakeetASRManager()
    asr.supportsStreaming = false
    asr.transcribeResult = ASRResult(
      text: "kernel vad stop",
      language: "en",
      duration: 1,
      processingTime: 0.01,
      backendType: .parakeet
    )
    let inputs = KernelDictationDriverFactory.Inputs(
      audioCapture: audio,
      asrManager: asr,
      transcriptStore: TranscriptStore(),
      keychainManager: KeychainManager(),
      captureTelemetry: CaptureTelemetryState(),
      pasteCompletionRegistry: PasteCompletionRegistry())
    let driver = KernelDictationDriverFactory.make(inputs: inputs)

    // Signal-based state-change waiter. Resumes the instant the driver
    // transitions, so the test does not depend on real-time scheduling
    // precision (swift-patterns.md § "Tests must not depend on real-time
    // scheduling precision"). Installed BEFORE any other wiring so no
    // construction step can drop the subscription.
    let waiter = DriverStateWaiter()
    driver.onStateChange = { state in
      MainActor.assumeIsolated { waiter.receive(state) }
    }

    let legacyStore = DictationRuntimeFixtures.tempStore()
    let legacyParakeet = DictationRuntimeFixtures.makeParakeetPipeline(
      audioCapture: audio, asrManager: asr, store: legacyStore)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: legacyStore)
    let router = AudioEventRouter(
      audioCapture: audio,
      pipeline: legacyParakeet,
      whisperKitPipeline: whisperKit,
      captureTelemetry: CaptureTelemetryState(),
      resolveActiveCaptureBackend: { .parakeet }
    )

    try await driver.handle(
      event: PipelineEvent.toggleRecording(
        DictationSessionConfig.testDefault(
          autoCopyToClipboard: false,
          vadAutoStop: true,
          useStreamingASR: false
        )))

    // Drain state changes until the driver is in `.recording`. Each await
    // resumes the instant the next state arrives; no polling, no sleep.
    while await waiter.next() != PipelineState.recording {}

    // The kernel claims `audio.onVADAutoStop` via `CaptureVADSignalSource`.
    // If the fix held, AudioEventRouter did NOT overwrite that claim, so
    // firing VAD auto-stop reaches the kernel and triggers a state transition.
    audio.fireVADAutoStop()

    // Wait for the next state change. If the kernel's claim survived, this
    // resumes promptly with a non-.recording state. If the claim was
    // overwritten, no state change fires and the test deadlocks (the suite's
    // surrounding test-runner timeout is the only safety net — which is what
    // we want: a real failure, not a flaky pass).
    let next = await waiter.next()
    #expect(next != PipelineState.recording)
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

/// Signal-based waiter for `KernelDictationDriver.onStateChange`. Resumes
/// the instant the next state is delivered — no `Task.sleep`, no real-time
/// deadline. Mirror of the `SignalPipelineLogger` shape but specialized to
/// `PipelineState`. Buffers states arriving before any `next()` call so the
/// test cannot miss a transition that fires before it gets a chance to await.
@MainActor
private final class DriverStateWaiter {
  private var pending: [PipelineState] = []
  private var waiter: CheckedContinuation<PipelineState, Never>?

  func receive(_ state: PipelineState) {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: state)
    } else {
      pending.append(state)
    }
  }

  func next() async -> PipelineState {
    if !pending.isEmpty {
      return pending.removeFirst()
    }
    return await withCheckedContinuation { cont in
      waiter = cont
    }
  }
}
