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
}

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
  func stopCapture() async -> CaptureResult { CaptureResult(samples: []) }
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
