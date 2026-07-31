import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// #1707: which of the two salvage-eligible interruption sources this
/// session's capture was interrupted by. `.engine` carries the existing
/// `EngineInterruptionCause` payload unchanged; `.asr` has no payload — the
/// ASR-interruption salvage path always emits `.asrInterrupted(wasRecording:
/// true)` on failure, so there is nothing further to distinguish. One enum,
/// not two independently-settable fields, so "both set" is unrepresentable.
enum InterruptedSalvageSource: Equatable, Sendable {
  case engine(EngineInterruptionCause)
  case asr
}

/// #1707 — Codex code-diff r2: a DEDICATED signal distinguishing an
/// ASR-interruption salvage attempt's outcome, separate from `lastStopReason`
/// (which only ever records the ORIGINAL exit, `"asr_interruption"`, whether
/// the salvage that followed succeeded or not). Without this, production
/// telemetry cannot distinguish a successful salvage from a rewarm failure, a
/// decode failure, or a superseded attempt — exactly the breakdown needed to
/// validate and eventually tune the recovery deadline (§3a).
public enum ASRSalvageOutcome: String, Sendable {
  /// The recovery capability confirmed readiness. Set immediately; if decode
  /// then fails, `interruptedTerminalFloor` upgrades this to `.decodeFailed`.
  case rewarmSucceeded = "rewarm_succeeded"
  case rewarmFailed = "rewarm_failed"
  case decodeFailed = "decode_failed"
  case cancelled = "cancelled"
}

/// #1707 Phase 2 — this session's ASR post-capture-decode retry outcome.
/// `.attempted` is set BEFORE the retry's own await begins and can be the
/// FINAL recorded value (a retry preempted by a competing interruption/
/// supersession before its own result is accepted never reaches `.retrySucceeded`/
/// `.retryExhausted`) — this is not a bug, it is the honest terminal state for
/// that race. `nil` means no Phase-2 retry ever started for this session
/// (covers both the pre-capture producer and a first-attempt success).
public enum ASRRetryOutcome: String, Sendable {
  case attempted = "attempted"
  case retrySucceeded = "retry_succeeded"
  case retryExhausted = "retry_exhausted"
}

/// Per-session telemetry side-channel for details that do not belong in the
/// kernel FSM state enum. The kernel writes this before terminal transitions;
/// `KernelLifecycleTelemetrySink` reads it when rendering the lifecycle event.
@MainActor
final class KernelTelemetryState {
  var polishEnabled = false
  /// #1846: the kernel session's `SessionID.raw.uuidString`, projected here so
  /// telemetry can name WHICH dictation an event belongs to. Observation-only:
  /// never persisted, never `Codable`, and it never influences a kernel decision.
  /// Replaced by the next accepted session's reset, never cleared mid-session —
  /// Sentry scope clearing is the lifecycle sink's terminal postamble's job, and
  /// a second clearer here would blank the tag while polish and paste are still
  /// running, which is exactly where the highest-volume errors are raised.
  var takeID: String?
  var recordingSnapshot: KernelRecordingSnapshotTelemetry?
  var noSpeechTelemetry: KernelNoSpeechTelemetry?
  var asrEmptyDiagnostics: ASREmptyResultDiagnostics?
  var asrCompletedTelemetry: KernelASRCompletedTelemetry?
  var captureFailureError: (any Error & StableSentryErrorIdentity)?
  /// #1167: set by the best-effort `store` closure when the durable history save
  /// throws. The lifecycle sink reads it to withhold the "transcript durably
  /// saved" success marker on a degraded-save completion. The operational source
  /// of truth for recovery-spool cleanup is `KernelFinalizationOutcome.historySaved`,
  /// NOT this telemetry mirror.
  var historySaveFailed = false
  var transcriptionFailureError: (any Error)?
  var modelLoadError: (any Error & StableSentryErrorIdentity)?
  /// #1434: the ONE capture-health record every post-stop consumer reads.
  /// Stamped immediately after `stopCapture()` returns + the stale-session
  /// guard passes — BEFORE the too-short / no-audio / dead-air early
  /// terminals — so no-audio, asrEmpty, and completed all share it.
  var captureHealth: KernelCaptureHealthTelemetry?
  /// #1408/#1707: the ONE home for "this session's capture was interrupted, and
  /// by what." Stamped once per session under a first-wins accept condition —
  /// `.engine(cause)` by `RecordingSessionKernel.externalEngineInterrupted`,
  /// `.asr` by the winning `.asrInterruption` exit from `.live` — and read by
  /// the kernel's salvage guard, the kernel's terminal floor (and, for `.asr`,
  /// the widened `isLegalConclusion`), the History "Interrupted" badge, and
  /// this module's lifecycle telemetry sink. Cleared ONLY by
  /// `resetForNewSession()` below — a second clearer would let a stale source
  /// leak into the next session and mis-fire the floor.
  var interruptedSalvageSource: InterruptedSalvageSource?

  /// Read/write derived projection onto `interruptedSalvageSource`, preserving
  /// every pre-#1707 production reader and test writer of the engine-only
  /// cause (`RecordingSessionKernel.lastAudioInterruptionCause` reads through
  /// here) without a second, independently-mutable copy. The getter returns
  /// the associated cause only for `.engine(cause)`; the setter maps a
  /// non-nil cause to `.engine(cause)` and nil to nil — it can never produce
  /// `.asr`, matching the fact that no pre-#1707 writer ever meant that case.
  var interruptionCause: EngineInterruptionCause? {
    get {
      guard case .engine(let cause) = interruptedSalvageSource else { return nil }
      return cause
    }
    set {
      interruptedSalvageSource = newValue.map { .engine($0) }
    }
  }
  /// #1317: the classified zero-signal failure mode for this session (nil =
  /// never classified). Stamped once, by whichever classification wins
  /// (reactive `.zeroSignal` exit OR STOP-time, §3.6) — drives the
  /// `.zeroSignal` pill for `allZeroFromStart` and the partial-capture
  /// disclosure for `becameZeroMidCapture` (§3.5).
  var zeroSignalFailureMode: CaptureStallFailureMode?

  /// #1707: this session's ASR-interruption salvage outcome, or `nil` if no
  /// salvage was attempted. See `ASRSalvageOutcome` for the value taxonomy.
  var asrSalvageOutcome: ASRSalvageOutcome?

  /// #1707 Phase 2: this session's post-capture-decode retry outcome, or
  /// `nil` if no Phase-2 retry ever started. See `ASRRetryOutcome`.
  var asrRetryOutcome: ASRRetryOutcome?

  /// `takeID` has NO default on purpose: an accepted session must state its own
  /// identity. A default would let a caller silently start a take with no key.
  func resetForNewSession(takeID: String, polishEnabled: Bool) {
    self.takeID = takeID
    self.polishEnabled = polishEnabled
    recordingSnapshot = nil
    noSpeechTelemetry = nil
    asrEmptyDiagnostics = nil
    asrCompletedTelemetry = nil
    captureFailureError = nil
    historySaveFailed = false
    transcriptionFailureError = nil
    modelLoadError = nil
    captureHealth = nil
    interruptedSalvageSource = nil
    zeroSignalFailureMode = nil
    asrSalvageOutcome = nil
    asrRetryOutcome = nil
  }
}

/// #1434: one capture-health record per session — helper-side facts from
/// `CaptureResult.metadata` (stop-time) merged with the kernel's own
/// stabilization observations (start-time). Every telemetry consumer
/// (`dictation.completed`, asrEmpty Sentry extra, NoAudio context) reads
/// this single record instead of N side channels.
struct KernelCaptureHealthTelemetry {
  /// From `CaptureResult.metadata` (nil when the source didn't produce one —
  /// stabilization flags below are still valid then).
  var stopMetadata: CaptureStopMetadata?
  /// Kernel-side: did `waitForFormatStabilization` return true pre-capture.
  var formatStabilized: Bool?
  /// Kernel-side: did the false path trigger the one rebuild+restart.
  var captureRebuiltForFormat: Bool?
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
  /// #1845 — the two energy values `RawAudioDeadAirClassifier.measure` compared
  /// against their floors. Optional because the classification short-circuits;
  /// `nil` means NOT COMPUTED, never "computed as zero". Populated only on the
  /// `.vadGate` route, which is the only one that runs the classifier — the
  /// `.asrEmptyNoSpeech` stamp leaves them nil and that is correct, not a gap.
  var wholeBufferRMS: Float?
  var maxWindowRMS: Float?
  /// #1845 — THIS take's route, frozen from `lastResolvedRoute` at the
  /// classifier site.
  ///
  /// These live here rather than being read at emit time because the sink's
  /// only other handle is `audioCapture.currentResolvedRoute`, which is LIVE
  /// state and can describe a later source by the time a terminal renders. The
  /// dead-mic telemetry already refuses that live read for the same reason
  /// (`RecordingSessionKernel.swift:1686-1690`).
  ///
  /// The native capture FORMAT fields are deliberately NOT duplicated here:
  /// `telemetryState.captureHealth.stopMetadata` is already frozen before every
  /// early terminal and already reachable from the sink, so a second copy would
  /// be a second authority for one fact.
  var effectiveTransport: String?
  var selectedTransport: String?
  var inputSelectionMode: String?
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
  // #1309 effective-path streaming telemetry (WhisperKit only; nil omitted).
  // `mode` above is the REQUESTED mode (kernel capability gate);
  // `streamingRequested` restates it as an explicit boolean so the event can
  // filter requested-vs-effective without string parsing. All metadata.
  var streamingRequested: Bool? = nil
  var streamingEffective: Bool? = nil
  var streamingDegradeReason: String? = nil
  var streamingFinalPath: String? = nil
  var streamingDecodeCount: Int? = nil
  var streamingCoveredSec: Double? = nil
  var tailDecodeSec: Double? = nil
  var maxUnconfirmedWindowSec: Double? = nil
  var stopWhileDecodeInFlight: Bool? = nil
  // #1434 degraded-lead salvage (set only on a salvaged completion; nil →
  // sink omits). `salvageSucceededAtTrimMs` is the winning candidate's trim.
  var salvageAttempted: Bool? = nil
  var salvageCandidateCount: Int? = nil
  var salvageSucceededAtTrimMs: Int? = nil
  var salvageRemainingAudioMs: Int? = nil
}

struct KernelASRAdapterDiagnostics {
  // #1309 effective-path telemetry (WhisperKit adapter; nil for Parakeet).
  // `streamingEffective`: did a streaming flush deliver the transcript.
  // `streamingDegradeReason`: none / disabled / auto_language /
  // model_not_ready / flush_empty / flush_throw.
  // `streamingFinalPath`: streaming_flush / clean_batch / fallback_batch / failed.
  var streamingEffective: Bool? = nil
  var streamingDegradeReason: String? = nil
  var streamingFinalPath: String? = nil
  var stopWhileDecodeInFlight: Bool? = nil
  var streamingMaxUnconfirmedWindowSec: Double? = nil

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
