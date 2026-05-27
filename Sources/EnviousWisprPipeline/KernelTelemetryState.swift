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
  /// `var` (not `let`) so the driver's terminal-state cleanup can stamp the
  /// frontmost app's bundle identifier into the snapshot before nulling
  /// `KernelSessionContext.targetApp` — otherwise the lifecycle sink's
  /// fallback at `KernelLifecycleTelemetrySink:370` would race the clear
  /// and drop `target_app_bundle_id` from terminal Sentry snapshots.
  var targetAppBundleID: String?
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

  // PR-5 Rung 3 (#827): WhisperKit-specific finalize diagnostics. The
  // WhisperKit adapter populates these on every terminal outcome so the
  // kernel's lifecycle sink can render the asr-empty-with-speech-evidence
  // payload (today's `WhisperKitPipeline.swift:1005-1019` Sentry call).
  // Sink-side wiring lands in Rung 5; adapter-side population lands here.
  var rawSampleCount: Int? = nil
  var incrementalAccepted: Bool? = nil
  var incrementalResultChars: Int? = nil
  var incrementalDecodeCount: Int? = nil
  var incrementalSamplesCovered: Int? = nil
  var incrementalStrategy: String? = nil
  var incrementalMode: String? = nil
  var incrementalTailDecodeMs: Int? = nil
}

@MainActor
protocol ASREngineTelemetryProviding: AnyObject {
  var lastASRDiagnostics: KernelASRAdapterDiagnostics? { get }
  var lastFailureError: (any Error)? { get }
}
