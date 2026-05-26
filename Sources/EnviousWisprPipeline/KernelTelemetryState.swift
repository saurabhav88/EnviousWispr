import Foundation

/// Per-session telemetry side-channel for details that do not belong in the
/// kernel FSM state enum. The kernel writes this before terminal transitions;
/// `KernelLifecycleTelemetrySink` reads it when rendering the lifecycle event.
@MainActor
final class KernelTelemetryState {
  var polishEnabled = false
  var recordingSnapshot: KernelRecordingSnapshotTelemetry?
  var noSpeechTelemetry: KernelNoSpeechTelemetry?
  var asrEmptyDiagnostics: ASREmptyResultDiagnostics?
  var asrCompletedTelemetry: KernelASRCompletedTelemetry?
  var captureFailureError: (any Error)?
  var storageFailureError: (any Error)?
  var transcriptionFailureError: (any Error)?
  var modelLoadError: (any Error)?

  func resetForNewSession(polishEnabled: Bool) {
    self.polishEnabled = polishEnabled
    recordingSnapshot = nil
    noSpeechTelemetry = nil
    asrEmptyDiagnostics = nil
    asrCompletedTelemetry = nil
    captureFailureError = nil
    storageFailureError = nil
    transcriptionFailureError = nil
    modelLoadError = nil
  }
}

struct KernelRecordingSnapshotTelemetry {
  let backend: String
  let audioRoute: String
  let wasStreaming: Bool
  let startTime: Date
  let durationMs: Int
  let targetAppBundleID: String?
}

struct KernelNoSpeechTelemetry {
  let mode: String
  let rawSampleCount: Int
  let peakAudioLevel: Float
}

struct KernelASRCompletedTelemetry {
  let durationSeconds: Double
  let charCount: Int
  let mode: String
  let language: String?
}

struct KernelASRAdapterDiagnostics {
  var streamingResultChars: Int? = nil
  var streamingFinalizeFailed: Bool? = nil
  var streamingFinalizeErrorType: String? = nil
  var streamingBuffersDispatched: Int? = nil
  var streamingBuffersFed: Int? = nil
  var batchRescueAttempted: Bool? = nil
  var batchRescueResultChars: Int? = nil
}

@MainActor
protocol ASREngineTelemetryProviding: AnyObject {
  var lastASRDiagnostics: KernelASRAdapterDiagnostics? { get }
  var lastFailureError: (any Error)? { get }
}
