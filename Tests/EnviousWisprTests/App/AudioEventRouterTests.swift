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
    // `makeParakeetDriver` runs `KernelDictationDriverFactory.make` which
    // claims `onVADAutoStop` via `CaptureVADSignalSource.bind`. To exercise
    // the App router's unclaimed-fallback path explicitly, clear the slot
    // BEFORE constructing the router. (The kernel-claim-survives path has
    // its own test below.)
    audio.onVADAutoStop = nil

    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
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
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: store)
    let telemetry = CaptureTelemetryState()
    var existingOwnerCallCount = 0
    audio.onVADAutoStop = { existingOwnerCallCount += 1 }

    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
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
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(audioCapture: audio)
    let inputs = KernelDictationDriverFactory.ParakeetInputs(
      audioCapture: audio,
      asrManager: asr,
      vadSignalSource: vad,
      transcriptStore: TranscriptStore(),
      keychainManager: KeychainManager(),
      captureTelemetry: CaptureTelemetryState(),
      pasteCompletionRegistry: PasteCompletionRegistry())
    let driver = KernelDictationDriverFactory.makeForParakeet(inputs: inputs)

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
    // Share the SAME VAD source with the WhisperKit driver, mirroring production
    // (`EnviousWisprApp.swift:101-102`). Without this, the helper's own
    // `makeSharedVADSignalSource` builds a second source and re-binds
    // `audio.onVADAutoStop` to it — orphaning the Parakeet kernel's stop path so
    // `fireVADAutoStop()` reaches nobody and the recording survives to the 300s
    // cap (#882: the false-pass + 5-minute hang this test used to exhibit).
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audio, store: legacyStore, sharedVAD: vad)
    // Post-PR-4b.4 of #827: the App router takes the same driver the kernel
    // path uses; there is no separate "legacy Parakeet" pipeline to satisfy.
    let router = AudioEventRouter(
      audioCapture: audio,
      kernelDriver: driver,
      whisperKitKernelDriver: whisperKit,
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

    // Drain state changes until the driver is in `.recording`. Reaching
    // recording runs through warm-up, so allow a generous bound; a stall here
    // is a real failure, not a flaky pass.
    while true {
      guard let state = await waiter.next(timeout: .seconds(5)) else {
        Issue.record("driver did not reach .recording within 5s")
        return
      }
      if state == PipelineState.recording { break }
    }

    // The kernel claims `audio.onVADAutoStop` via the shared `CaptureVADSignalSource`.
    // Firing VAD auto-stop must reach the kernel (claim not overwritten by the
    // WhisperKit driver's construction, nor by `AudioEventRouter`) and trigger a
    // prompt stop.
    audio.fireVADAutoStop()

    // A correctly-wired VAD-stop transitions in milliseconds. The ONLY other way
    // this recording stops is the 300s max-duration cap — so a sub-2s transition
    // PROVES the manual VAD-stop actually reached the kernel. If the claim were
    // stolen/dropped, no prompt transition fires: this times out and fails fast
    // (#882 — previously it hung to the 300s cap and FALSE-PASSED via the cap's
    // separate `maxDuration` signal path).
    guard let next = await waiter.next(timeout: .seconds(2)) else {
      Issue.record(
        "VAD auto-stop produced no state transition within 2s: the kernel onVADAutoStop claim was not honored (the regression #882 guards against)"
      )
      return
    }
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
      whisperKitKernelDriver: whisperKit,
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
      whisperKitKernelDriver: whisperKit,
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
/// the instant the next state is delivered. Buffers states arriving before any
/// `next()` call so the test cannot miss a transition that fires before it gets
/// a chance to await. Mirror of the `SignalPipelineLogger`/`PipelineStateWaiter`
/// shape — including a timeout backstop so a regression FAILS FAST instead of
/// parking the continuation forever and hanging the whole test runner
/// (swift-patterns.md `tests-no-unconditional-continuation-await`, #445/#696).
@MainActor
private final class DriverStateWaiter {
  private var pending: [PipelineState] = []
  private var waiter: CheckedContinuation<PipelineState?, Never>?
  private var timeoutTask: Task<Void, Never>?

  func receive(_ state: PipelineState) {
    if let waiter {
      self.waiter = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      waiter.resume(returning: state)
    } else {
      pending.append(state)
    }
  }

  /// Returns the next state, or `nil` if none arrives within `timeout`. A `nil`
  /// return is the fail-fast signal (the caller records an `Issue`): the only
  /// non-prompt stop in this suite is the 300s max-recording cap, so a
  /// correctly-wired transition always arrives in well under `timeout`. The
  /// timeout task is the only `Task.sleep` here and it never feeds a SUT
  /// measurement — it is a pure deadline backstop (allowed exception in
  /// swift-patterns.md `tests-no-real-time-scheduling-precision`).
  func next(timeout: Duration = .seconds(2)) async -> PipelineState? {
    if !pending.isEmpty {
      return pending.removeFirst()
    }
    return await withCheckedContinuation { (cont: CheckedContinuation<PipelineState?, Never>) in
      waiter = cont
      timeoutTask = Task { @MainActor [weak self] in
        // A cancelled timeout — the common case where `receive` resumed first
        // and cancelled us — must EXIT, not fall through and resume whatever
        // waiter is parked NOW; otherwise a stale drain-loop timeout steals the
        // next await's continuation and resolves it with a spurious nil.
        do { try await Task.sleep(for: timeout) } catch { return }
        guard let self, let parked = self.waiter else { return }
        self.waiter = nil
        self.timeoutTask = nil
        parked.resume(returning: nil)
      }
    }
  }
}
