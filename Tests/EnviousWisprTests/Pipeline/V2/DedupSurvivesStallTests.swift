@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// V2 fault-injection — Lane C invariant C1 (issue #291).
///
/// Asserts that the per-session stall dedup in `HeartPathTelemetryEmitter` is
/// truly per-session: a stall fires in session 1 (state flips to `.error`),
/// and after `cancelRecording` + `startRecording`, a fresh stall in session 2
/// fires again rather than getting suppressed by stale dedup state. Dedup
/// must not leak across recordings.
///
/// Uses a `NeverFinishingAudioCapture` stub so the pipeline parks in
/// `.recording` without racing against the audio path's auto-completion.
/// Does NOT exercise the DEBUG capture fault-injection seam — that's Lane A
/// scenario A5's responsibility.
@MainActor
@Suite("V2 Lane C — dedup state survives recording restart")
struct DedupSurvivesStallTests {

  @Test(
    "stall fires in session 1, fires again in fresh session 2 — dedup is per-session, not global"
  )
  func testDedupSurvivesStallRestart() async throws {
    let audioCapture = NeverFinishingAudioCapture()
    let asrManager = NoOpASRManagerV2()

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
        // No-op sink: this test asserts on STATE flips, not on Sentry. Inject a
        // no-op so the pipeline's stall captureError never reaches the
        // process-global delegate, where it could pollute a concurrent test's
        // installed spy (#875).
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

    // ─── Session 1 ─────────────────────────────────────────────────────────
    try await pipeline.handle(event: .toggleRecording(config))
    await stateWaiter.wait(for: .recording)
    #expect(pipeline.state == .recording, "session 1 must reach .recording")

    // First stall in session 1 — emitter fires (no prior dedup); the kernel's
    // recording-exit continuation resumes the forward-path coroutine, which
    // then transitions to `.failed(.captureStalled)` (driver maps to
    // `.error(.captureStalled)`). The transition is async
    // because the forward path runs in a separate Task — poll until it lands.
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 1))
    await stateWaiter.wait(for: .error(.captureStalled))
    #expect(
      pipeline.state == .error(.captureStalled),
      "first stall in session 1 must flip state to .error")

    // Reset to idle so we can start session 2. `cancelRecording()` is a
    // no-op once the pipeline is in `.error` (its guard checks for
    // `.recording` / `.loadingModel`); `reset()` is the path that takes the
    // pipeline back to `.idle` from any state.
    pipeline.reset()
    await stateWaiter.wait(for: .idle)
    #expect(pipeline.state == .idle, "reset() must return to .idle")

    // ─── Session 2 ─────────────────────────────────────────────────────────
    try await pipeline.handle(event: .toggleRecording(config))
    await stateWaiter.wait(for: .recording)
    #expect(
      pipeline.state == .recording,
      "session 2 must reach .recording — dedup must not block restart")

    // Stall in session 2 (fresh sessionID). Emitter must NOT consider this
    // deduped from session 1's prior fire — the pipeline guard must advance
    // to .error. If dedup state had leaked across recordings, state would
    // remain .recording and this test would fail.
    pipeline.handleCaptureStall(Self.stallContext(sessionID: 2))
    await stateWaiter.wait(for: .error(.captureStalled))
    #expect(
      pipeline.state == .error(.captureStalled),
      "stall in fresh session 2 must fire — dedup state must not survive restart")

    await pipeline.cancelRecording()
  }

  // MARK: - Helpers

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
}

// MARK: - Test stubs

/// `AudioCaptureInterface` stub that never delivers buffers and never
/// finishes its capture stream — the pipeline parks in `.recording` so we
/// can fire `handleCaptureStall` deterministically without racing the
/// audio path's auto-completion. Architecture rule "duplication is allowed
/// when it protects independence" — V2 tests stay decoupled from
/// `HeartPathTelemetryWiringTests`'s private stubs.
@MainActor
private final class NeverFinishingAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "synthetic-fixture"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "fixture_mock"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  /// Hold the continuation indefinitely so the AsyncStream never completes.
  /// The pipeline's read loop stays parked, leaving state at `.recording`.
  private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    isCapturing = true
    isActivelyCapturing = true
    currentCaptureSessionID += 1
    // #1548 D2: reaching `.live` no longer needs a buffer (the forward path
    // transitions sequentially). But THIS scenario is a stall AFTER audio arrives —
    // a genuine capture-stall (.captureStalled), not a dead-mic
    // no-transport. So deliver ONE buffer to make `bufferCountThisSession > 0`,
    // which is what routes the later `.noBuffers` stall to `.captureStall` instead
    // of `.noTransport`. Then the stream parks, holding `.live`.
    if let buffer = Self.makeSilentBuffer() { onBufferCaptured?(buffer) }
    return AsyncStream { cont in
      self.continuation = cont
      // Intentionally never yield, never finish.
    }
  }

  /// A single silent capture-sized mono float buffer — amplitude is irrelevant to
  /// buffer-count bookkeeping.
  private static func makeSilentBuffer() -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: AVAudioChannelCount(AudioConstants.channels),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(AudioConstants.captureBufferSize))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(AudioConstants.captureBufferSize)
    return buffer
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await startEnginePhase()
    return try await beginCapturePhase()
  }
  func stopCapture() async -> CaptureResult {
    continuation?.finish()
    continuation = nil
    isCapturing = false
    isActivelyCapturing = false
    return CaptureResult(samples: [])
  }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm() async throws {}
  func abortPreWarm() {
    continuation?.finish()
    continuation = nil
    isCapturing = false
    isActivelyCapturing = false
  }
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) { ([], 0) }
  func getVADSegments() async -> [SpeechSegment] { [] }
}

/// `ASRManagerInterface` stub. The dedup-survives-stall test never reaches
/// transcription (recording is interrupted by stall + cancel), so all
/// methods throw / return trivial values to flag unintended invocation.
@MainActor
private final class NoOpASRManagerV2: ASRManagerInterface {
  var activeBackendType: ASRBackendType = .parakeet
  var isModelLoaded: Bool = false
  var isStreaming: Bool = false
  var downloadProgress: Double = 0
  var downloadPhase: String = "idle"
  var downloadDetail: String = ""
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  // PR-4b.4: the kernel adapter calls `loadModel()` during warmUp and the
  // kernel watchdogs the load via `loadProgressTickReporter` — no ticks for
  // long enough triggers `.modelLoadFailed`. The old Parakeet pipeline
  // path bypassed the watchdog, so an empty body was sufficient. Fire a tick
  // so the watcher sees progress, then flip `isModelLoaded` to mark the
  // load complete; the recording then proceeds to `.recording` and this
  // stall-dedup scenario can run as designed.
  func loadModel() async throws {
    loadProgressTickReporter?(Date(), "test-fake-load")
    isModelLoaded = true
  }
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
  func switchBackend(to type: ASRBackendType) async { activeBackendType = type }
  var activeBackendSupportsStreaming: Bool { get async { false } }
  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
    throw V2StubError.unexpected
  }
  func startStreaming(options: TranscriptionOptions) async throws { throw V2StubError.unexpected }
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws { throw V2StubError.unexpected }
  func finalizeStreaming() async throws -> ASRResult { throw V2StubError.unexpected }
  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}

  enum V2StubError: Error { case unexpected }
}
