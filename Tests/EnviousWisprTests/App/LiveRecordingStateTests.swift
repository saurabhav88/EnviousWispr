@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// Unit tests for `LiveRecordingState` (PR7 of epic #763).
///
/// Verifies the routing logic and the highest-risk PR7 question:
/// observation propagation through `any AudioCaptureInterface` and
/// `any ASRManagerInterface` existentials. Pipeline-state-machine driven
/// transitions are validated by Live UAT (the pipelines' `state` is
/// `public private(set)` and not writeable from tests).
@MainActor
@Suite("LiveRecordingState")
struct LiveRecordingStateTests {

  @Test("init wires four references; default state returns idle pipeline state")
  func defaultStateReturnsIdle() {
    let state = makeState()
    #expect(state.pipelineState == .idle)
    #expect(state.audioLevel == 0)
    #expect(state.currentTranscript == nil)
  }

  @Test("pipelineState routes through asrManager.activeBackendType")
  func pipelineStateRoutesByBackend() {
    let state = makeState()
    // #881 TO-3: drive the WhisperKit driver to a DISTINCT observable state so
    // the two routing arms return values neither branch can produce by accident.
    // The prior test left both drivers .idle, so it stayed green even if the
    // router ignored activeBackendType, inverted the condition, or read the
    // wrong driver in the WhisperKit arm.
    state.whisperKitKernelDriver.setExternalError("wk-marker")
    // Parakeet arm → reads the (error-free) parakeet driver → .idle.
    state.asrManager.setInitialBackendType(.parakeet)
    #expect(state.pipelineState == .idle)
    // WhisperKit arm → reads the WhisperKit driver → .error("wk-marker").
    state.asrManager.setInitialBackendType(.whisperKit)
    #expect(state.pipelineState == .error("wk-marker"))
  }

  @Test(
    "recordingElapsedSeconds routes through asrManager.activeBackendType, mirroring pipelineState")
  func recordingElapsedSecondsRoutesByBackend() {
    let state = makeState()
    // #1393: same routing shape as `pipelineState` above. Both drivers stay
    // at `.idle` here (real FSM-driven `.recording` transitions are Live
    // UAT territory per this file's own header comment, same limitation
    // `pipelineState`'s own "recording" case has), so both branches read
    // `nil` — this proves the routing selects the right driver's property
    // without crashing, not a distinguishing nonzero value.
    state.asrManager.setInitialBackendType(.parakeet)
    #expect(state.recordingElapsedSeconds == nil)
    state.asrManager.setInitialBackendType(.whisperKit)
    #expect(state.recordingElapsedSeconds == nil)
  }

  @Test("audioLevel reads through the audioCapture existential")
  func audioLevelReadsAudioCapture() {
    let audio = SettableAudioCapture()
    let state = makeState(audioCapture: audio)
    audio.audioLevel = 0.42
    #expect(state.audioLevel == 0.42)
  }

  @Test("observation tracking fires when backend type changes via existential (ASR path)")
  func observationPropagatesThroughASRExistential() async {
    let state = makeState()
    state.asrManager.setInitialBackendType(.parakeet)

    // Track a read of pipelineState (which reads asrManager.activeBackendType
    // through `any ASRManagerInterface`). The tracking callback fires once
    // when any tracked property mutates. Confirms Swift Observation propagates
    // through the existential — this is the highest-risk question Codex
    // grounded review flagged. If this test fails, switch LiveRecordingState
    // to concrete-type storage before merge.
    let fired = LockBox<Bool>(false)
    withObservationTracking {
      _ = state.pipelineState
    } onChange: {
      fired.value = true
    }

    state.asrManager.setInitialBackendType(.whisperKit)
    // Yield once to let the observation registry deliver.
    await Task.yield()
    #expect(fired.value, "Observation must propagate through any ASRManagerInterface existential")
  }

  @Test("observation tracking fires when audio level changes via existential (audio path)")
  func observationPropagatesThroughAudioExistential() async {
    let audio = ObservableAudioCapture()
    let state = makeState(audioCapture: audio)

    // Track a read of audioLevel (which reads audioCapture.audioLevel through
    // `any AudioCaptureInterface`). Audio path counterpart to the ASR test
    // above. Codex code-diff review flagged that the ASR test alone does not
    // prove the audio existential path. ObservableAudioCapture is `@Observable`
    // so its `audioLevel` mutation triggers Swift Observation; if propagation
    // is broken through the existential, this assertion fails.
    let fired = LockBox<Bool>(false)
    withObservationTracking {
      _ = state.audioLevel
    } onChange: {
      fired.value = true
    }

    audio.audioLevel = 0.5
    await Task.yield()
    #expect(fired.value, "Observation must propagate through any AudioCaptureInterface existential")
  }

  // MARK: - Fixtures

  private func makeState(
    audioCapture: any AudioCaptureInterface = SettableAudioCapture(),
    asrManager: any ASRManagerInterface = ASRManager()
  ) -> LiveRecordingState {
    // Codex code-diff revision: use the internal `init(directory:)` overload
    // with a temp directory so the test does not write into the user's
    // production transcript dir or schedule the detached permissions
    // migration that the zero-arg `TranscriptStore()` does at init.
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-recording-state-tests-\(UUID().uuidString)")
    let store = TranscriptStore(directory: tempDir)
    let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audioCapture, asrManager: asrManager, store: store)
    let whisperKit = DictationRuntimeFixtures.makeWhisperKitPipeline(
      audioCapture: audioCapture, store: store)
    return LiveRecordingState(
      kernelDriver: parakeet,
      whisperKitKernelDriver: whisperKit,
      audioCapture: audioCapture,
      asrManager: asrManager
    )
  }
}

/// Reference box so the observation callback can flip a flag the test reads
/// without `inout` capture semantics. The callback is `@Sendable`, so this
/// is not `@MainActor`; `nonisolated(unsafe)` lets the closure mutate
/// without raising a Sendable diagnostic. Single-test fixture; the test
/// runs serially on @MainActor.
private final class LockBox<T>: @unchecked Sendable {
  nonisolated(unsafe) var value: T
  init(_ initial: T) { self.value = initial }
}

/// `AudioCaptureInterface` stub with settable `audioLevel` so tests can
/// verify pass-through reads without driving a real audio engine.
@MainActor
private final class SettableAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onVADModelUnavailable: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onXPCServiceError: ((XPCErrorContext) -> Void)?
  var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  var onAudioStartRetryResolved: ((AudioStartRetryContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "av_audio_engine"
  var noiseSuppressionEnabled: Bool = false
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture() async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func buildEngine(noiseSuppression: Bool) {}
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

/// `@Observable` variant of the audio stub for the audio-existential
/// observation test. The `@Observable` macro generates the read/write
/// observation hooks that `withObservationTracking` requires; mutating
/// `audioLevel` here MUST trigger any tracking closure that read
/// `state.audioLevel`. Used only by `observationPropagatesThroughAudioExistential`.
@MainActor
@Observable
private final class ObservableAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onVADModelUnavailable: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onXPCServiceError: ((XPCErrorContext) -> Void)?
  var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  var onAudioStartRetryResolved: ((AudioStartRetryContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "av_audio_engine"
  var noiseSuppressionEnabled: Bool = false
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture() async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func buildEngine(noiseSuppression: Bool) {}
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
