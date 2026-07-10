@preconcurrency import AVFoundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

@Suite("AudioCaptureFailureExtras")
@MainActor
struct AudioCaptureFailureExtrasTests {
  @Test("format creation failures include the originating audio source")
  func formatCreationFailureAddsSource() {
    let capture = ExtrasAudioCapture()
    capture.currentCaptureSessionID = 42
    capture.preferredInputDeviceIDOverride = "preferred-mic"

    let extras = AudioCaptureFailureExtras.build(
      error: AudioError.formatCreationFailed(
        source: "AVAudioEngineSource.startCapture.missing_forwarder"),
      audioCapture: capture,
      failureMode: "thrown_start"
    )

    #expect(
      extras["capture.error_source"] as? String
        == "AVAudioEngineSource.startCapture.missing_forwarder")
    #expect(extras["capture.source_type"] as? String == "av_audio_engine")
    #expect(extras["capture.failure_mode"] as? String == "thrown_start")
    #expect(extras["capture_session_id"] as? Int == 42)
    #expect(extras["capture.input_device_uid_preferred"] as? String == "preferred-mic")
  }

  @Test("non-audio errors omit the audio source and keep backend tag")
  func nonAudioErrorOmitsSource() {
    let extras = AudioCaptureFailureExtras.build(
      error: GenericStartError.failed,
      audioCapture: ExtrasAudioCapture(),
      failureMode: "thrown_start",
      backend: "whisperKit"
    )

    #expect(extras["capture.error_source"] == nil)
    #expect(extras["backend"] as? String == "whisperKit")
  }

  @Test("audio error keeps user-facing message stable")
  func audioErrorMessageStable() {
    let error = AudioError.formatCreationFailed(source: "unit.test")
    #expect(error.localizedDescription == "Failed to create audio format.")
    #expect(error.diagnosticSource == "unit.test")
  }
}

private enum GenericStartError: Error {
  case failed
}

@MainActor
private final class ExtrasAudioCapture: AudioCaptureInterface {
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
