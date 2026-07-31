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
        source: "HALDeviceInputSource.startCapture.missing_forwarder"),
      audioCapture: capture,
      failureMode: "thrown_start"
    )

    #expect(
      extras["capture.error_source"] as? String
        == "HALDeviceInputSource.startCapture.missing_forwarder")
    #expect(extras["capture.source_type"] as? String == "hal_device_input")
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

  // MARK: - #1714 input-resolution attribution

  @Test("a capture-start failure carries the input resolution source")
  func failureCarriesInputResolutionSource() {
    // The failing population is the point: a fix whose own failures are
    // unattributable cannot be measured.
    let capture = ExtrasAudioCapture()
    capture.currentInputResolutionSource = "list_fallback"

    let extras = AudioCaptureFailureExtras.build(
      error: AudioError.noBuiltInMicrophoneFound,
      audioCapture: capture,
      failureMode: "no_microphone_found"
    )

    #expect(extras["capture.input_resolution_source"] as? String == "list_fallback")
  }

  @Test("nil input resolution OMITS the key entirely")
  func nilInputResolutionOmitsKey() {
    // Not NSNull, not "unknown", not an empty string — absent.
    let extras = AudioCaptureFailureExtras.build(
      error: AudioError.noBuiltInMicrophoneFound,
      audioCapture: ExtrasAudioCapture(),
      failureMode: "no_microphone_found"
    )

    #expect(extras["capture.input_resolution_source"] == nil)
    #expect(extras.keys.contains("capture.input_resolution_source") == false)
  }

  @Test("input and ROUTE resolution sources coexist with distinct values")
  func inputAndRouteResolutionSourcesCoexist() {
    // These two keys look alike and mean different things: one is WHY the input
    // device was selected, the other is how a TRANSPORT LABEL was derived.
    // Proving they coexist with different values is what stops a future reader
    // collapsing them.
    let capture = ExtrasAudioCapture()
    capture.currentInputResolutionSource = "list_fallback"
    capture.currentResolvedRoute = ResolvedRouteTransports(
      selected: "built_in",
      effective: "built_in",
      routeReason: "automatic",
      routeFallbackReason: nil,
      inputSelectionMode: "automatic",
      outputTransport: "built_in",
      routeResolutionSource: "app_derived"
    )

    let extras = AudioCaptureFailureExtras.build(
      error: AudioError.noBuiltInMicrophoneFound,
      audioCapture: capture,
      failureMode: "no_microphone_found"
    )

    #expect(extras["capture.input_resolution_source"] as? String == "list_fallback")
    #expect(extras["capture.route_resolution_source"] as? String == "app_derived")
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
  /// #1714: the fake overrides the interface's `nil` default so a test can
  /// script attribution the builder must carry through.
  var currentInputResolutionSource: String? = nil
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
    AsyncStream { $0.finish() }
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
