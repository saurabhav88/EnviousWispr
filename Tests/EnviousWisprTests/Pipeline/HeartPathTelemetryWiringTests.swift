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
/// dependencies are easy to stub. The WhisperKit equivalent would require
/// constructing a real `WhisperKitBackend` actor; the asymmetry it depends
/// on is already proven by the unit tests in
/// `HeartPathTelemetryEmitterTests` plus the literal `backend: .whisperKit`
/// argument at the WhisperKit init site. Adding a full pipeline init test
/// for WhisperKit would not catch a regression the unit tests miss.
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
        vadSignalSource: vad,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting,
        captureErrorSink: captureErrorSink
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
        vadSignalSource: vad,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting,
        // Asserts on STATE, not Sentry — no-op sink keeps the stall captureError
        // off the process-global delegate (#875).
        captureErrorSink: { _, _, _, _, _ in }
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

  // #1578: the asymmetry test. `handleCaptureStall` deliberately reaches the
  // kernel FSM; `handleZeroSignalRefusal` deliberately does not. Asserting only
  // that the observer fired would pass for a method that ALSO stopped the
  // recording, so this drives a real session to `.live` and then proves the FSM
  // did not move. `hasUnconsumedRecordingExit` is the strong witness: an
  // accidental `externalCaptureStalled` on a zero-signal mode latches a
  // recording exit synchronously, so it would be `true` the moment the call
  // returned. It needs `kernelForTesting`, which is DEBUG-only.
  #if DEBUG
    @Test("KernelDictationDriver.handleZeroSignalRefusal observes without moving the FSM")
    func refusalReachesTelemetryWithoutTouchingTheFSM() async throws {
      let fixture = try SyntheticAudioFixture.make(
        fileName: "1578-refusal-no-fsm-move.wav",
        pattern: .toneBurst
      )
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
          vadSignalSource: vad,
          transcriptStore: TranscriptStore(),
          keychainManager: KeychainManager(),
          captureTelemetry: CaptureTelemetryState(),
          pasteCompletionRegistry: PasteCompletionRegistry(),
          engineMutationScope: .alwaysAllowedForTesting,
          captureErrorSink: { _, _, _, _, _ in }
        ))
      let stateWaiter = PipelineStateWaiter(pipeline)

      let config = DictationSessionConfig.testDefault(
        autoPasteToActiveApp: false,
        vadSensitivity: 0.5,
        languageMode: .auto,
        llmProvider: .openAI,
        llmModel: "gpt-test"
      )
      try await pipeline.handle(event: .toggleRecording(config))
      // `PipelineStateWaiter` subscribes to `onStateChange` and parks on a
      // continuation until `.recording` is observed; its 5s timeout is only the
      // deadline fallback around that signal. Same helper, same call, as the
      // stall test above.
      // settle: signal wait on an observed state change, not a clock wait.
      await stateWaiter.wait(for: .recording)

      // Preconditions, so the post-call assertions cannot pass vacuously.
      #expect(pipeline.state == .recording)
      #expect(pipeline.kernelForTesting.state == .live)
      #expect(pipeline.kernelForTesting.hasUnconsumedRecordingExit == false)
      #expect(pipeline.kernelForTesting.recordingOutcome == nil)

      let box = RefusalEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      pipeline.handleZeroSignalRefusal(
        ZeroSignalRefusalContext(
          sessionID: 5,
          reason: .deviceMuted,
          transport: "usb",
          failureShape: .becameZeroMidCapture))

      // 1. The observation genuinely travelled the whole route.
      #expect(box.events.map(\.name) == ["audio.zero_signal_refused"])

      // 2. And the recording is untouched. An accidental zero-signal stall call
      // would synchronously flip `hasUnconsumedRecordingExit`; the other three
      // assertions freeze the broader observer-only contract.
      #expect(pipeline.state == .recording)
      #expect(pipeline.kernelForTesting.state == .live)
      #expect(
        pipeline.kernelForTesting.hasUnconsumedRecordingExit == false,
        "a refusal latched a recording exit — did handleZeroSignalRefusal call externalCaptureStalled?"
      )
      #expect(pipeline.kernelForTesting.recordingOutcome == nil)

      await pipeline.cancelRecording()
    }

    /// Collects PostHog events emitted through the DEBUG hook during a single
    /// synchronous main-actor call.
    @MainActor
    private final class RefusalEventBox {
      var events: [CapturedTelemetryEvent] = []
    }

    // #1578: the backlog's ONLY route to the emitter is a single line in
    // `KernelDictationDriverFactory`. Delete it and the kernel still drains, the
    // sink is still called, and every direct kernel, manager, router, emitter and
    // service test stays green — while production emits nothing at all. That is
    // the definition of a guard nothing arms, so this test builds the driver
    // through the REAL factory and watches the REAL telemetry hook.
    @Test("#1578: the drained backlog reaches PostHog through the production factory wiring")
    func drainedBacklogReachesTelemetryThroughFactoryWiring() async throws {
      let audioCapture = BacklogAudioCapture()
      let pipeline = Self.makeFactoryDriver(audioCapture: audioCapture)
      let stateWaiter = PipelineStateWaiter(pipeline)

      let box = RefusalEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // A real session, then a real terminal — `cancel()` from `.idle` concludes
      // nothing and would reach no drain point at all.
      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on an observed state change, not a clock wait.
      await stateWaiter.wait(for: .recording)
      #expect(pipeline.state == .recording)

      // Populate the backlog INSIDE the active session. Seeding it beforehand
      // would model a state production cannot reach: `AudioCaptureManager`
      // clears any prior-session backlog when capture begins, so a pre-start
      // seed is a context production would already have thrown away.
      let activeSessionID = audioCapture.currentCaptureSessionID
      audioCapture.stubbedPending = [
        ZeroSignalRefusalContext(
          sessionID: activeSessionID,
          reason: .deviceMuted,
          transport: "usb",
          failureShape: .becameZeroMidCapture),
        ZeroSignalRefusalContext(
          sessionID: activeSessionID,
          reason: .notAlive,
          transport: "bluetooth",
          failureShape: .allZeroFromStart),
      ]
      #expect(audioCapture.stubbedPending.count == 2)

      await pipeline.cancelRecording()

      let refusals = box.events.filter { $0.name == "audio.zero_signal_refused" }
      #expect(refusals.count == 2, "N pending contexts must produce N events, not one batch")
      #expect(
        refusals.map { $0.stringProps["reason"] } == ["device_muted", "not_alive"],
        "order lost between the atomic take and the emitter")
      #expect(refusals.map { $0.stringProps["transport"] } == ["usb", "bluetooth"])
      #expect(
        refusals.map { $0.stringProps["failure_shape"] }
          == ["became_zero_mid_capture", "all_zero_from_start"])
      #expect(audioCapture.takeCallCount == 1, "the terminal did not perform exactly one drain")
      #expect(audioCapture.stubbedPending.isEmpty)
    }

    @Test("#1578: an empty backlog emits nothing through the production wiring")
    func emptyBacklogEmitsNothingThroughFactoryWiring() async throws {
      let audioCapture = BacklogAudioCapture()
      let pipeline = Self.makeFactoryDriver(audioCapture: audioCapture)
      let stateWaiter = PipelineStateWaiter(pipeline)

      let box = RefusalEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      try await pipeline.handle(event: .toggleRecording(Self.refusalConfig))
      // settle: signal wait on an observed state change, not a clock wait.
      await stateWaiter.wait(for: .recording)
      #expect(pipeline.state == .recording)
      #expect(audioCapture.stubbedPending.isEmpty)

      await pipeline.cancelRecording()

      // The paired control. Without it, a factory that emitted a spurious event on
      // every terminal would satisfy the positive test above. The take assertion
      // matters as much as the event one: it proves the control actually ENTERED
      // the drain and found nothing, rather than silently skipping it.
      #expect(audioCapture.takeCallCount == 1, "the empty control never entered the drain")
      #expect(audioCapture.stubbedPending.isEmpty)
      #expect(box.events.allSatisfy { $0.name != "audio.zero_signal_refused" })
    }

    private static let refusalConfig = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )

    private static func makeFactoryDriver(
      audioCapture: BacklogAudioCapture
    ) -> KernelDictationDriver {
      KernelDictationDriverFactory.makeForParakeet(
        inputs: .init(
          audioCapture: audioCapture,
          // MockASRManager, not NoOpASRManager: the no-op stub throws from its
          // lifecycle methods, so the forward path never reaches `.recording` and
          // no terminal drain point is ever exercised. Same choice the
          // recording-state test above makes.
          asrManager: MockASRManager(
            transcribeBehavior: .success(
              ASRResult(
                text: "hello", language: "en", duration: 1,
                processingTime: 0.01, backendType: .parakeet))),
          vadSignalSource: KernelDictationDriverFactory.makeSharedVADSignalSource(
            audioCapture: audioCapture),
          transcriptStore: TranscriptStore(),
          keychainManager: KeychainManager(),
          captureTelemetry: CaptureTelemetryState(),
          pasteCompletionRegistry: PasteCompletionRegistry(),
          engineMutationScope: .alwaysAllowedForTesting,
          captureErrorSink: { _, _, _, _, _ in }
        ))
    }
  #endif
}

#if DEBUG
  /// A capture double whose ONLY interesting behaviour is the pending-refusal
  /// backlog, so the factory-wiring test observes the wire and nothing else.
  @MainActor
  private final class BacklogAudioCapture: AudioCaptureInterface {
    var stubbedPending: [ZeroSignalRefusalContext] = []
    private(set) var takeCallCount = 0

    func takePendingZeroSignalRefusals() -> [ZeroSignalRefusalContext] {
      takeCallCount += 1
      let pending = stubbedPending
      stubbedPending.removeAll(keepingCapacity: true)
      return pending
    }

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
    var warmEnginePolicy: WarmEnginePolicy = .off

    func startEnginePhase() async throws {}
    func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
      // Same shape as `FixtureAudioCapture`: flip the capture flags and bump the
      // session id so the forward path can reach `.recording`. Without this the
      // session never leaves arming and no terminal drain point is ever reached.
      currentCaptureSessionID += 1
      isCapturing = true
      isActivelyCapturing = true
      return AsyncStream { $0.finish() }
    }
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
      try await beginCapturePhase(recoveryPayload: nil)
    }
    func stopCapture() async -> CaptureResult {
      isCapturing = false
      isActivelyCapturing = false
      // Real audio, so the take is an ordinary recording rather than a
      // zero-signal one — this test is about the BACKLOG route, not classification.
      return CaptureResult(samples: [Float](repeating: 0.5, count: 16_000))
    }
    func rebuildEngine() {}
    func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
    func preWarm() async throws {}
    func abortPreWarm() {}
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
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
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
  func preWarm() async throws {}
  func abortPreWarm() {}
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
  var isStreaming: Bool = false
  var downloadProgress: Double = 0
  var downloadPhase: String = "idle"
  var downloadDetail: String = ""
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  func loadModel() async throws {}
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
  func switchBackend(to type: ASRBackendType) async { activeBackendType = type }

  var activeBackendSupportsStreaming: Bool { get async { false } }

  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
    throw NoOpError.unexpected
  }
  func startStreaming(options: TranscriptionOptions) async throws { throw NoOpError.unexpected }
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws { throw NoOpError.unexpected }
  func finalizeStreaming() async throws -> ASRResult { throw NoOpError.unexpected }
  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}

  enum NoOpError: Error { case unexpected }
}
