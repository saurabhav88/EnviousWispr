@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// Pipeline-level tests for the `HeartPathTelemetryEmitter` wiring.
///
/// Codex round-1 (2026-04-30) flagged two gaps the emitter unit tests
/// alone could not catch:
///   3. Pipeline-level dedup + terminal-state flip: a future refactor that
///      drops `guard fired else { return }` in `handleCaptureStall` would
///      still pass emitter unit tests. We must observe both the Sentry
///      dedup contract AND the `state` flip contract holding at the
///      pipeline boundary.
///   4. (Retired #1524.) The backend-wiring proof used the asymmetric
///      `"backend"` extra on `captureSessionInterruption` as its witness.
///      That extra existed ONLY on that emit, and both died with the
///      capture-session backend; no surviving emit carries a `backend` key.
///
/// Codex round-2 (2026-04-30) caught that an earlier version of the dedup
/// test only fired Sentry events from `.idle` state, so the
/// `guard state == .recording` path bailed both calls regardless of the
/// emitter's return value. That made the terminal-state-flip claim
/// theater. The fix lives in `parakeetPipelineStallFlipsStateOnceFromRecording`
/// below, which uses `FixtureAudioCapture` + `startRecording(...)` to
/// drive into `.recording` before calling `handleCaptureStall`.
///
/// We test `KernelDictationDriver` (Parakeet) directly because its
/// dependencies are easy to stub. The Whisper equivalent would require
/// constructing a real `Whisper backend` actor; the asymmetry it depends
/// on is already proven by the unit tests in
/// `HeartPathTelemetryEmitterTests` plus the literal `backend: .whisper`
/// argument at the Whisper init site. Adding a full pipeline init test
/// for Whisper would not catch a regression the unit tests miss.
@MainActor
@Suite("HeartPathTelemetryEmitter — pipeline wiring + dedup at pipeline level")
struct HeartPathTelemetryWiringTests {

  // MARK: - Spy bridge

  /// Sendable-by-mutex captured-call list. The Sentry delegate runs on
  /// whichever thread the SDK fires from, so the storage must be
  /// thread-safe; the test reads on @MainActor after the synchronous
  /// pipeline call returns.
  private final class CaptureSpy: @unchecked Sendable {
    struct Captured {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let extra: [String: Any]
    }
    private let lock = NSLock()
    private var _calls: [Captured] = []

    var calls: [Captured] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }

    func record(_ call: Captured) {
      lock.lock()
      defer { lock.unlock() }
      _calls.append(call)
    }
  }

  /// Build a spy-backed capture sink to inject into a pipeline. Replaces the
  /// former `SentryBreadcrumb.captureErrorDelegate` global install — that
  /// process-global is shared across all `@MainActor` tests and is the #875
  /// cross-test pollution vector. The injected sink fires synchronously on the
  /// main actor, so `spy.calls` is observable immediately after the pipeline
  /// method returns.
  private static func spySink(
    _ spy: CaptureSpy
  ) -> KernelDictationDriverFactory.HeartPathCaptureErrorSink {
    { _, category, stage, extra, _ in
      spy.record(.init(category: category, stage: stage, extra: extra ?? [:]))
    }
  }

  // MARK: - Test doubles

  private static func makeStubAudio() -> NoOpAudioCapture {
    NoOpAudioCapture()
  }

  private static func makeASR() -> NoOpASRManager {
    NoOpASRManager()
  }

  private static func makePipeline(
    captureErrorSink: @escaping KernelDictationDriverFactory.HeartPathCaptureErrorSink = {
      _, _, _, _, _ in
    }
  ) -> KernelDictationDriver {
    let audio = makeStubAudio()
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(audioCapture: audio)
    return KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audio,
        asrManager: makeASR(),
        parakeetUpgrade: .legacyForTesting(),
        vadSignalSource: vad,
        transcriptStore: DictationRuntimeFixtures.tempStore(),
        keychainManager: KeychainManager(),
        localPolishers: .llamaForTests,
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting,
        captureErrorSink: captureErrorSink, revealPatience: PasteRevealPatience(), isSharedEngineHeldByOtherWorkload: { false }
      ))
  }

  private static func stallContext(sessionID: UInt64) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: 1_000,
      firedAtUptimeNs: 2_000,
      route: "built_in_mic",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers
    )
  }

  // MARK: - Tests

  /// Codex gap #3 (Sentry-emit half) — pipeline-level emit dedup. Two
  /// consecutive `handleCaptureStall` calls on the same session must
  /// produce ONE captureError. Proves the emitter the pipeline uses is
  /// connected to the same dedup state. Does NOT verify the
  /// terminal-state flip — that lives in the next test.
  @Test("KernelDictationDriver.handleCaptureStall dedups Sentry emits per session")
  func parakeetPipelineStallDedupsSentryPerSession() {
    let spy = CaptureSpy()
    let pipeline = Self.makePipeline(captureErrorSink: Self.spySink(spy))

    pipeline.handleCaptureStall(Self.stallContext(sessionID: 7))
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 7))

    #expect(spy.calls.count == 1)
    #expect(spy.calls[0].category == .audioCaptureStalled)
    #expect(spy.calls[0].extra["capture_session_id"] as? Int == 7)
  }

  /// Sanity companion to the dedup test: a different `sessionID` re-arms
  /// the dedup, proving it is not a global one-shot.
  @Test("KernelDictationDriver.handleCaptureStall re-arms Sentry emits on session change")
  func parakeetPipelineStallReArmsOnSession() {
    let spy = CaptureSpy()
    let pipeline = Self.makePipeline(captureErrorSink: Self.spySink(spy))

    pipeline.handleCaptureStall(Self.stallContext(sessionID: 1))
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 1))  // suppressed
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 2))  // fresh session

    #expect(spy.calls.count == 2)
    let sessions = spy.calls.compactMap { $0.extra["capture_session_id"] as? Int }
    #expect(sessions == [1, 2])
  }

  /// Codex gap #3 — `guard fired else { return }` in
  /// `KernelDictationDriver.handleCaptureStall` must prevent a
  /// session-deduped call from incorrectly flipping state to `.error`.
  ///
  /// Test shape (Codex round-3 suggestion):
  ///   1. Pre-dedup the emitter's stall flag while the pipeline is `.idle`
  ///      by calling `handleCaptureStall(sessionID: N)`. The `.idle` state
  ///      gate bails before any state mutation, but the emitter's
  ///      per-session dedup still flips internally (it runs FIRST).
  ///   2. Drive into `.recording` via `startRecording(...)`.
  ///   3. Call `handleCaptureStall(sessionID: N)` again — same session.
  ///
  /// With `guard fired else { return }` present (correct): emitter returns
  /// false (already deduped), the guard short-circuits before the
  /// `state == .recording` check, state stays `.recording`.
  ///
  /// Without that guard (regression): emitter returns false but control
  /// reaches `guard state == .recording`, which passes, so state
  /// incorrectly flips to `.error` and `pendingStallRecoveryToken` is
  /// reset — breaking the #289 token-gated recovery contract.
  ///
  /// The first-stall-from-recording case (state → .error on first hit) is
  /// covered implicitly: if the emitter's pre-dedup wiring breaks, the
  /// second call would emit and the test fails for the opposite reason.
  @Test("KernelDictationDriver.handleCaptureStall guard fired prevents deduped state flip")
  func parakeetPipelineStallGuardFiredPreventsDedupedFlip() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "r5-stall-guard-fired.wav",
      pattern: .toneBurst
    )
    // #1548 D2: deliver a first buffer so the step-3 stall is a genuine
    // `.captureStall` (async flip via the recording-exit channel), not a
    // synchronous dead-mic `.noTransport` — the test observes `.recording`
    // immediately after firing the stall, which requires the async path.
    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url, deliverFirstBuffer: true)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)
    let pipeline = KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audioCapture,
        asrManager: asrManager,
        parakeetUpgrade: .legacyForTesting(),
        vadSignalSource: vad,
        transcriptStore: DictationRuntimeFixtures.tempStore(),
        keychainManager: KeychainManager(),
        localPolishers: .llamaForTests,
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting,
        // Asserts on STATE, not Sentry — no-op sink keeps the stall captureError
        // off the process-global delegate (#875).
        captureErrorSink: { _, _, _, _, _ in }, revealPatience: PasteRevealPatience(), isSharedEngineHeldByOtherWorkload: { false }
      ))
    let stateWaiter = PipelineStateWaiter(pipeline)

    // Step 1: pre-dedup the emitter's stall flag while pipeline is .idle.
    // `handleCaptureStall` calls telemetry.stallFired (which dedups
    // per-session) BEFORE the state guard, so the emitter's internal
    // flag gets set even though pipeline state stays .idle.
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 99))
    #expect(pipeline.state == .idle)

    // Step 2: drive into .recording.
    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )
    try await pipeline.handle(event: .toggleRecording(config))

    await stateWaiter.wait(for: .recording)
    #expect(pipeline.state == .recording)

    // Step 3: same-session stall, now from .recording. Emitter returns
    // false (deduped). With `guard fired else { return }`: state stays
    // .recording. Without it: state flips to .error.
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 99))

    #expect(
      pipeline.state == .recording,
      "deduped stall must NOT flip state — `guard fired` regressed?")

    await pipeline.cancelRecording()
  }

  #if DEBUG
    // #1578 / #4841: a refusal's ONLY route to the emitter is a single line in
    // `KernelDictationDriverFactory`. Delete it and the kernel still classifies,
    // the sink is still called, and every direct kernel, emitter and service test
    // stays green while production emits nothing. So this builds the driver
    // through the REAL factory, drives a real STOP of a whole-zero take whose
    // device is ineligible (the double reports no frozen bind, which the
    // classifier owns as `.boundDeviceUnavailable`), and watches the REAL hook.
    // The #900 clock seam advances logical time past the too-short gate, so no
    // test sleeps.
    @Test("#4841: an ineligible whole-zero STOP reaches PostHog through the production factory")
    func ineligibleWholeZeroStopReachesTelemetryThroughFactoryWiring() async throws {
      let audioCapture = StopSamplesAudioCapture()
      audioCapture.stopSamples = [Float](repeating: 0, count: 24_000)
      let clock = ManualSeconds()
      let pipeline = Self.makeFactoryDriver(audioCapture: audioCapture, clock: clock)
      let stateWaiter = PipelineStateWaiter(pipeline)

      let box = RefusalEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on an observed state change, not a clock wait.
      await stateWaiter.wait(for: .recording)
      clock.now += 2  // past the minimum visible recording, by hand
      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on the terminal state change, not a clock wait.
      await stateWaiter.wait(for: { !$0.isActive })

      #expect(audioCapture.stopCallCount == 1, "the take never reached STOP")
      let refusals = box.events.filter { $0.name == "audio.zero_signal_refused" }
      #expect(refusals.count == 1, "one ineligible whole-zero STOP must produce exactly one event")
      #expect(refusals.first?.stringProps["reason"] == "bound_device_unavailable")
      #expect(refusals.first?.stringProps["failure_shape"] == "all_zero_from_start")
    }

    @Test("#4841: a STOP with real audio emits no refusal through the production wiring")
    func audibleStopEmitsNoRefusalThroughFactoryWiring() async throws {
      let audioCapture = StopSamplesAudioCapture()
      audioCapture.stopSamples = [Float](repeating: 0.5, count: 24_000)
      let clock = ManualSeconds()
      let pipeline = Self.makeFactoryDriver(audioCapture: audioCapture, clock: clock)
      let stateWaiter = PipelineStateWaiter(pipeline)

      let box = RefusalEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on an observed state change, not a clock wait.
      await stateWaiter.wait(for: .recording)
      clock.now += 2
      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on the terminal state change, not a clock wait.
      await stateWaiter.wait(for: { !$0.isActive })

      // The paired control: a factory that emitted a refusal on every STOP would
      // satisfy the positive test above, and a take discarded as too short would
      // satisfy this one vacuously, so the take must also not be a discard.
      #expect(audioCapture.stopCallCount == 1, "the control never reached STOP")
      #expect(box.events.contains { $0.name == "dictation.terminal" && $0.stringProps["result"] != "discarded" })
      #expect(box.events.allSatisfy { $0.name != "audio.zero_signal_refused" })
    }

    /// Collects PostHog events emitted through the DEBUG hook.
    @MainActor
    private final class RefusalEventBox {
      var events: [CapturedTelemetryEvent] = []
    }

    /// A hand-advanced clock for the #900 seam.
    @MainActor
    private final class ManualSeconds {
      var now: TimeInterval = 1_000
    }

    private static let refusalConfig = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )

    private static func makeFactoryDriver(
      audioCapture: StopSamplesAudioCapture, clock: ManualSeconds
    ) -> KernelDictationDriver {
      KernelDictationDriverFactory.makeForParakeet(
        inputs: .init(
          audioCapture: audioCapture,
          // MockASRManager, not NoOpASRManager: the no-op stub throws from its
          // lifecycle methods, so the forward path never reaches `.recording`.
          asrManager: MockASRManager(
            transcribeBehavior: .success(
              ASRResult(
                text: "hello", language: "en", duration: 1,
                processingTime: 0.01, backendType: .parakeet))),
          parakeetUpgrade: .legacyForTesting(),
          vadSignalSource: KernelDictationDriverFactory.makeSharedVADSignalSource(
            audioCapture: audioCapture),
          transcriptStore: DictationRuntimeFixtures.tempStore(),
          keychainManager: KeychainManager(),
          localPolishers: .llamaForTests,
          captureTelemetry: CaptureTelemetryState(),
          pasteCompletionRegistry: PasteCompletionRegistry(),
          engineMutationScope: .alwaysAllowedForTesting,
          captureErrorSink: { _, _, _, _, _ in }, revealPatience: PasteRevealPatience(),
          isSharedEngineHeldByOtherWorkload: { false },
          currentTime: { clock.now }
        ))
    }
  #endif
}

#if DEBUG
  /// A capture double whose ONLY interesting behaviour is what STOP returns, so
  /// the factory-wiring test observes the stop-time refusal wire and nothing else.
  /// It reports no frozen bind (the protocol default), so a whole-zero STOP is
  /// classified ineligible.
  @MainActor
  private final class StopSamplesAudioCapture: AudioCaptureInterface {
    var stopSamples: [Float] = []
    private(set) var stopCallCount = 0
    var isCapturing: Bool = false
    var audioLevel: Float = 0
    var capturedSamples: [Float] = []
    var currentAudioRoute: String = "built_in_mic"
    var currentResolvedRoute: ResolvedRouteTransports?
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
    var onVADAutoStop: (() -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var onCaptureStalled: ((CaptureStallContext) -> Void)?
    var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
    var currentCaptureSessionID: UInt64 = 1
    var isActivelyCapturing: Bool = false
    var captureSourceType: String = "hal_device_input"
    var selectedInputDeviceUID: String = ""
    var preferredInputDeviceIDOverride: String = ""
    var inputChannelByDeviceUID: [String: Int] = [:]
    var warmEnginePolicy: WarmEnginePolicy = .off

    func startEnginePhase(startDeadline: ContinuousClock.Instant) async throws {}
    func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
      currentCaptureSessionID += 1
      isCapturing = true
      isActivelyCapturing = true
      return AsyncStream { $0.finish() }
    }
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
      try await beginCapturePhase(recoveryPayload: nil)
    }
    // #1579 fence parameter deliberately ignored: one capture session only.
    func stopCapture(sessionID _: UInt64) async -> CaptureResult {
      stopCallCount += 1
      isCapturing = false
      isActivelyCapturing = false
      return CaptureResult(samples: stopSamples)
    }
    func rebuildEngine() {}
    func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
    func preWarm(startDeadline: ContinuousClock.Instant) async throws {}
    func abandonPendingStart() {}
    func abortPreWarm() {}
    func releaseUnstartedCapture() {}
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
      -> Bool
    { true }
    func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
    {}
    func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) { ([], 0) }
    func getVADSegments() async -> [SpeechSegment] { [] }
  }
#endif

// MARK: - Stubs (test-local)

/// Minimal `AudioCaptureInterface` stub for pipeline-construction tests.
/// All capture lifecycle methods are no-ops; only the small read-only
/// surface the pipeline reads in `handleCaptureStall` matters.
@MainActor
private final class NoOpAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "hal_device_input"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var inputChannelByDeviceUID: [String: Int] = [:]
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase(startDeadline: ContinuousClock.Instant) async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    // #1548 D2: the forward path reaches `.live` sequentially once this returns —
    // no first-buffer delivery needed to leave Arming.
    return AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture(sessionID: UInt64) async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm(startDeadline: ContinuousClock.Instant) async throws {}
  func abandonPendingStart() {}
  func abortPreWarm() {}
  func releaseUnstartedCapture() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}

/// Minimal `ASRManagerInterface` stub. Pipeline construction reads no ASR
/// state in the telemetry callbacks under test; methods throw or return
/// trivial values so any unintended invocation surfaces immediately.
@MainActor
private final class NoOpASRManager: ASRManagerInterface {
  var activeBackendType: ASRBackendType = .parakeet
  var isModelLoaded: Bool = false
  let vendorDecodeOccupancy = VendorDecodeOccupancy()
  var onVendorDecodeChunkScheduled: (@MainActor @Sendable () -> Void)?
  var onTranscriptionProgress: (@MainActor @Sendable (Double) -> Void)?
  var isStreaming: Bool = false
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  func loadModel() async throws {}
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
  func switchBackend(to type: ASRBackendType) async { activeBackendType = type }

  var activeBackendSupportsStreaming: Bool { get async { false } }

  func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered: ASRInferenceEntryObserver? = nil
  ) async throws -> ASRResult {
    throw NoOpError.unexpected
  }
  func startStreaming(
    options: TranscriptionOptions, attemptID: UUID,
    onWindowInferenceEntered: ASRInferenceEntryObserver? = nil
  ) async throws {
    throw NoOpError.unexpected
  }
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws { throw NoOpError.unexpected }
  func finalizeStreaming() async throws -> ASRResult { throw NoOpError.unexpected }
  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}

  enum NoOpError: Error { case unexpected }
}
