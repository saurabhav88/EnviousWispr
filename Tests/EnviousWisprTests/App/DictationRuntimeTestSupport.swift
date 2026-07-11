@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR8 of #763 — shared spies for the three router unit tests. Identical
/// shape to the existing `SettableAudioCapture` / `NoOpASRManager` fixtures
/// used elsewhere; centralised here so the three router test files don't
/// each redeclare a 40-line stub.
@MainActor
final class RouterTestAudioCapture: AudioCaptureInterface {
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
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
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
  var preWarmError: Error?
  /// #1063 PR1: counts `abortPreWarm()` so the release-during-recovery-arm guard
  /// (Codex code-diff r2 P2) can assert the prewarmed engine is torn down.
  private(set) var abortPreWarmCallCount = 0

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
  func preWarm() async throws {
    if let preWarmError { throw preWarmError }
  }
  func abortPreWarm() { abortPreWarmCallCount += 1 }
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}

@MainActor
final class RouterTestASRManager: ASRManagerInterface {
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
    throw RouterTestError.unexpected
  }
  func startStreaming(options: TranscriptionOptions) async throws {
    throw RouterTestError.unexpected
  }
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    throw RouterTestError.unexpected
  }
  func finalizeStreaming() async throws -> ASRResult { throw RouterTestError.unexpected }
  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}
}

enum RouterTestError: Error { case unexpected }

@MainActor
enum DictationRuntimeFixtures {
  static func tempStore() -> TranscriptStore {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("router-tests-\(UUID().uuidString)")
    return TranscriptStore(directory: tempDir)
  }

  /// PR-4b.4 of #827: returns the kernel-backed driver (the Parakeet pipeline
  /// post-cutover). Callers update their stored variable type from
  /// the old Parakeet pipeline to `KernelDictationDriver`; the construction-site
  /// keyword-arg shape is otherwise unchanged.
  static func makeParakeetDriver(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    store: TranscriptStore
  ) -> KernelDictationDriver {
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)
    return KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audioCapture,
        asrManager: asrManager,
        vadSignalSource: vad,
        transcriptStore: store,
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry()
      ))
  }

  /// PR-5 Rung 5 (#827): WhisperKit is a second kernel driver via the
  /// factory's `makeForWhisperKit(inputs:)`. The fixture function keeps its
  /// historical name (`makeWhisperKitPipeline`) so callers do not change;
  /// only the return type narrows to `KernelDictationDriver`.
  ///
  /// `sharedVAD` (#882): production builds ONE `CaptureVADSignalSource` and
  /// passes the same instance to both drivers (`WisprBootstrapper.swift:101-102`),
  /// so `audioCapture.onVADAutoStop` is bound exactly once. A test that builds
  /// both a Parakeet and a WhisperKit driver MUST share the source the same
  /// way, or this helper's own `makeSharedVADSignalSource` call re-binds (steals)
  /// the callback and orphans the first driver's VAD-stop path. Pass the
  /// Parakeet driver's source here to mirror production; default `nil` keeps the
  /// historical fresh-source behavior for single-driver callers.
  static func makeWhisperKitPipeline(
    audioCapture: any AudioCaptureInterface,
    store: TranscriptStore,
    sharedVAD: CaptureVADSignalSource? = nil
  ) -> KernelDictationDriver {
    let vad =
      sharedVAD
      ?? KernelDictationDriverFactory.makeSharedVADSignalSource(
        audioCapture: audioCapture)
    let detector = LanguageDetector(onLanguageFlip: { _ in })
    return KernelDictationDriverFactory.makeForWhisperKit(
      inputs: .init(
        audioCapture: audioCapture,
        whisperKitBackend: WhisperKitBackend(),
        languageDetector: detector,
        vadSignalSource: vad,
        transcriptStore: store,
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry()
      ))
  }

  static func captureStallContext(sessionID: UInt64) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: 1_000,
      firedAtUptimeNs: 2_000,
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil
    )
  }

  static func xpcReplyFailureContext(sessionID: UInt64) -> XPCReplyFailureContext {
    XPCReplyFailureContext(
      replyStage: "stopCapture",
      errorDomain: "TestDomain",
      errorCode: 1,
      errorDescription: "test",
      sessionID: sessionID
    )
  }

  static func captureSessionInterruptionContext(
    sessionID: UInt64
  ) -> CaptureSessionInterruptionContext {
    CaptureSessionInterruptionContext(
      kind: .wasInterrupted,
      reasonCode: 1,
      reasonLabel: "test",
      errorDomain: nil,
      errorCode: nil,
      errorDescription: nil,
      sessionID: sessionID,
      isActivelyCapturing: true
    )
  }
}
