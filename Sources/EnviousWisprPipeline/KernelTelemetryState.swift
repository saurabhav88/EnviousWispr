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
  /// #1167: set by the best-effort `store` closure when the durable history save
  /// throws. The lifecycle sink reads it to withhold the "transcript durably
  /// saved" success marker on a degraded-save completion. The operational source
  /// of truth for recovery-spool cleanup is `KernelFinalizationOutcome.historySaved`,
  /// NOT this telemetry mirror.
  var historySaveFailed = false
  var transcriptionFailureError: (any Error)?
  var modelLoadError: (any Error)?

  func resetForNewSession(polishEnabled: Bool) {
    self.polishEnabled = polishEnabled
    recordingSnapshot = nil
    noSpeechTelemetry = nil
    asrEmptyDiagnostics = nil
    asrCompletedTelemetry = nil
    captureFailureError = nil
    historySaveFailed = false
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
  // PR-5 Rung 5 Pass 2 r2 #B1: WhisperKit-only — whether incremental-worker
  // output was accepted vs batch fallback. Restores the `"incremental"` key the
  // OLD `WhisperKitPipeline.swift:1049-1052` ASR-completed breadcrumb carried.
  // nil for Parakeet (no incremental concept) → sink omits the key.
  var incrementalAccepted: Bool? = nil
  // #950 tail-trim diagnostic, eligible Parakeet batch only. `droppedTailMs`
  // always set (incl. 0) on the eligible success path so the Sentry breadcrumb
  // carries a denominator; `tailHadEnergy` only when droppedTailMs > 0 (no tail
  // slice otherwise). nil → sink omits the key.
  var droppedTailMs: Int? = nil
  var tailHadEnergy: Bool? = nil
  // #950 tail-preserve recovery + tuning signals (eligible Parakeet batch only).
  // `usedTailPreservation`: nil=ineligible, false=eligible-not-preserved,
  // true=recovered a sustained-voice dropped tail. `recoveredTailMs`: ms appended
  // back on a fire. `tailVoicedFraction`: sustained-voice ratio of the dropped
  // tail. `tailRefusedReason`: why an eligible tail was refused. nil → sink omits.
  var usedTailPreservation: Bool? = nil
  var recoveredTailMs: Int? = nil
  var tailVoicedFraction: Double? = nil
  var tailRefusedReason: String? = nil
  // #1232 tail-clip telemetry (recalibrated #1236): release-safe classifier + lead
  // signals. All numbers/booleans, no audio or text. `tailClipClassification` is one
  // of asr_complete / suspected_asr_drop / unknown. `asrLastTokenGapMs` is the
  // headline drop metric (untranscribed tail on the decoded timeline). nil → sink
  // omits the key.
  var tailClipClassification: String? = nil
  var captureTrailingSilenceMs: Int? = nil
  var captureTail200Rms: Double? = nil
  var captureTail200Peak: Double? = nil
  var asrInputDurationMs: Int? = nil
  var asrLastTokenEndMs: Int? = nil
  var asrLastTokenGapMs: Int? = nil
  var asrChunked: Bool? = nil
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

  // PR-5 Rung 4.5 (#827): LID perf signpost transport. The WhisperKit adapter
  // populates these during finalize so `KernelFinalizationWiring.deliver` can
  // emit `t_clipboard_write` with the same `session_id` + LID-shape fields the
  // OLD pipeline carried (`WhisperKitPipeline.swift:1079-1086`). Parakeet does
  // not populate these; the wiring gates the emit on engine identity.
  var lidCaptureSessionID: UInt64? = nil
  var lidVoicedDurationSec: Double? = nil
  var lidWindowCount: Int? = nil
  var lidClipKind: String? = nil
}

@MainActor
protocol ASREngineTelemetryProviding: AnyObject {
  var lastASRDiagnostics: KernelASRAdapterDiagnostics? { get }
  var lastFailureError: (any Error)? { get }
}
