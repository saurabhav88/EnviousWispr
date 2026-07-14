import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Renders `KernelLifecycleEvent` values (produced by
/// `KernelHeartPathTelemetryObserver`) into the byte-identical Sentry / PostHog
/// calls that the old Parakeet pipeline made today. PR-4b.2 §3.7.
///
/// Backend-agnostic — the backend tag flows from `init(backend:)`, never from
/// hardcoded `"parakeet"` / `"whisperKit"` strings inside the switch body.
/// Two factory call sites (PR-4b.2 today; PR-5/PR-6 unify) decide the
/// per-engine value.
///
/// All sinks are closure-injected so tests inspect emissions without touching
/// the real Sentry / PostHog SDKs (same pattern as `HeartPathTelemetryEmitter`).
///
/// **Engine-internal events stay where they live today.** PR-1 §B.7.4 covers
/// the kernel-owned vocabulary; engine-internal telemetry (Parakeet streaming,
/// WhisperKit language detection, etc.) remains in its owning pipeline and
/// will move in PR-5 / PR-6.
@MainActor
final class KernelLifecycleTelemetrySink {

  // MARK: Sinks (closure-injected; default wires real SDK calls)

  /// All sink-emitted breadcrumbs are info-level (matches old TP call sites);
  /// the level is fixed in the default closure rather than exposed in the
  /// typealias so this module doesn't have to import Sentry directly
  /// (`SentryLevel` lives behind `EnviousWisprServices`'s Sentry wrapper).
  typealias BreadcrumbSink = @MainActor (
    _ stage: String, _ message: String, _ data: [String: Any]?
  ) -> Void

  typealias RecordingStateSink = @MainActor (
    _ active: Bool, _ backend: String?, _ isStreaming: Bool?
  ) -> Void

  typealias AudioRouteSink = @MainActor (_ route: String) -> Void

  typealias DictationInvokedSink = @MainActor (
    _ triggerSource: String, _ inputMode: String, _ targetApp: String?
  ) -> Void

  typealias ModelLoadWedgedSink = @MainActor (
    _ backend: String, _ telemetry: KernelModelLoadWedgeTelemetry?
  ) -> Void

  typealias CaptureErrorSink = @MainActor (
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?
  ) -> Void

  typealias SnapshotCaptureErrorSink = @MainActor (
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?,
    _ snapshot: SentryBreadcrumb.RecordingSnapshot
  ) -> Void

  /// Rich `no_audio_captured` emission with the full `NoAudioContext` (route,
  /// active-capture flag, source type, device IDs). Div 6 of seam audit /
  /// TP:273-291: the old Parakeet pipeline routed through
  /// `HeartPathTelemetryEmitter.noAudioCaptured(ctx:)` which preserves the
  /// stall/XPC-failure dedup contract. The default impl emits the basic
  /// captureError (preserves the no-rich-wiring behavior for tests); the
  /// factory wires it to the real emitter so production callers get the
  /// rich payload.
  typealias NoAudioCapturedSink = @MainActor (_ ctx: NoAudioContext) -> Void

  /// #1408: the non-paging counter that gives salvage a denominator. Injected
  /// like every other sink so tests observe the emission without PostHog.
  typealias AudioCaptureInterruptedSink = @MainActor (
    _ cause: String, _ salvageAttempted: Bool, _ salvageSucceeded: Bool,
    _ terminalState: String, _ backend: String, _ recordingDurationMs: Int?
  ) -> Void

  // MARK: Identity + read sources

  private let backend: ASRBackendType
  private let audioCapture: any AudioCaptureInterface
  private let context: KernelSessionContext
  private let outcome: KernelFinalizationOutcome
  private let captureTelemetry: CaptureTelemetryState
  private let telemetryState: KernelTelemetryState
  private let modelLoadWedgeTelemetry: @MainActor () -> KernelModelLoadWedgeTelemetry?
  private let breadcrumb: BreadcrumbSink
  private let updateRecordingState: RecordingStateSink
  private let updateAudioRoute: AudioRouteSink
  private let dictationInvoked: DictationInvokedSink
  private let modelLoadWedged: ModelLoadWedgedSink
  private let captureError: CaptureErrorSink
  private let captureErrorWithSnapshot: SnapshotCaptureErrorSink
  /// Optional. When wired (factory path), the sink routes
  /// `.noAudioCaptured` through this closure so the emitter's dedup
  /// contract + rich extras land at Sentry. When nil (test path / no
  /// rich wiring), the sink falls back to the basic captureError
  /// closure with the same context fields. Either way, the test
  /// recorder pattern observes the emission via its `captureError`
  /// injection.
  private let noAudioCapturedRich: NoAudioCapturedSink?
  private let audioCaptureInterrupted: AudioCaptureInterruptedSink

  init(
    backend: ASRBackendType,
    audioCapture: any AudioCaptureInterface,
    context: KernelSessionContext,
    outcome: KernelFinalizationOutcome = KernelFinalizationOutcome(),
    captureTelemetry: CaptureTelemetryState,
    telemetryState: KernelTelemetryState = KernelTelemetryState(),
    modelLoadWedgeTelemetry: @escaping @MainActor () -> KernelModelLoadWedgeTelemetry? = { nil },
    breadcrumb: @escaping BreadcrumbSink = { stage, message, data in
      SentryBreadcrumb.add(stage: stage, message: message, level: .info, data: data)
    },
    updateRecordingState: @escaping RecordingStateSink = { active, backend, isStreaming in
      SentryBreadcrumb.updateRecordingState(
        active: active, backend: backend, isStreaming: isStreaming)
    },
    updateAudioRoute: @escaping AudioRouteSink = { route in
      SentryBreadcrumb.updateAudioRoute(route)
    },
    dictationInvoked: @escaping DictationInvokedSink = { trigger, mode, target in
      TelemetryService.shared.dictationInvoked(
        triggerSource: trigger, inputMode: mode, targetApp: target)
    },
    modelLoadWedged: @escaping ModelLoadWedgedSink = { backend, telemetry in
      TelemetryService.shared.modelLoadWedged(
        backend: backend, stage: "loading_model",
        silenceMs: telemetry?.silenceMs,
        observedMaxGapMs: telemetry?.observedMaxGapMs,
        observedPhase: telemetry?.observedPhase ?? "kernel",
        signalCountTotal: telemetry?.signalCountTotal,
        firstSignalLatencyMs: telemetry?.firstSignalLatencyMs,
        totalAttemptDurationMs: telemetry?.totalAttemptDurationMs)
    },
    captureError: @escaping CaptureErrorSink = { error, category, stage, extra in
      SentryBreadcrumb.captureError(error, category: category, stage: stage, extra: extra)
    },
    captureErrorWithSnapshot: @escaping SnapshotCaptureErrorSink = {
      error, category, stage, extra, snapshot in
      SentryBreadcrumb.captureError(
        error, category: category, stage: stage, extra: extra, snapshot: snapshot)
    },
    noAudioCapturedRich: NoAudioCapturedSink? = nil,
    audioCaptureInterrupted: @escaping AudioCaptureInterruptedSink = {
      cause, attempted, succeeded, terminal, backend, durationMs in
      TelemetryService.shared.audioCaptureInterrupted(
        cause: cause, salvageAttempted: attempted, salvageSucceeded: succeeded,
        terminalState: terminal, backend: backend, recordingDurationMs: durationMs)
    }
  ) {
    self.backend = backend
    self.audioCapture = audioCapture
    self.context = context
    self.outcome = outcome
    self.captureTelemetry = captureTelemetry
    self.telemetryState = telemetryState
    self.modelLoadWedgeTelemetry = modelLoadWedgeTelemetry
    self.breadcrumb = breadcrumb
    self.updateRecordingState = updateRecordingState
    self.updateAudioRoute = updateAudioRoute
    self.dictationInvoked = dictationInvoked
    self.modelLoadWedged = modelLoadWedged
    self.captureError = captureError
    self.captureErrorWithSnapshot = captureErrorWithSnapshot
    self.noAudioCapturedRich = noAudioCapturedRich
    self.audioCaptureInterrupted = audioCaptureInterrupted
  }

  /// Switch over the 12-case lifecycle vocabulary and emit each PR-1 §B.7.2
  /// kernel-owned event with byte-identical event identity
  /// (stage / message / category / event name). Payload fidelity per §3.7
  /// mapping table — preserved where the sink can read, deferred where rich
  /// kernel-side wiring would be required (§2.2 non-goals).
  func emit(_ event: KernelLifecycleEvent) {
    emitAudioCaptureInterruptedIfNeeded(for: event)
    switch event {
    case .pipelineStartingUp:
      // PR-5 Rung 5 Pass 2 #1 — parity with OLD
      // `WhisperKitPipeline.swift:438` `Pipeline starting up` breadcrumb.
      // Backend-agnostic in the new architecture; tag the active backend
      // in the data dict so support triage can still filter.
      breadcrumb("pipeline", "Pipeline starting up", ["backend": backend.rawValue])
      Task { [bv = backend.rawValue] in
        await AppLogger.shared.log(
          "Pipeline starting up (backend=\(bv))",
          level: .info, category: "Pipeline"
        )
      }

    case .modelLoading:
      breadcrumb("asr", "Model loading", ["backend": backend.rawValue])

    case .recordingCommitted(let isStreaming):
      let triggerSource = context.config?.triggerSource.rawValue ?? "unknown"
      let inputMode = context.config?.inputMode.rawValue ?? "unknown"
      let targetApp = context.targetApp?.localizedName
      dictationInvoked(triggerSource, inputMode, targetApp)
      // Mirror old TP:546-553 — the breadcrumb data dict carries both
      // `backend` and `streaming`, and `updateRecordingState` carries the
      // real streaming flag (Codex review #11 r2 — earlier draft hardcoded
      // `false` and would have misreported every streaming session as batch).
      breadcrumb(
        "recording", "Recording started",
        ["backend": backend.rawValue, "streaming": isStreaming])
      updateRecordingState(true, backend.rawValue, isStreaming)
      updateAudioRoute(audioCapture.currentAudioRoute)
      Task {
        await AppLogger.shared.log(
          "Recording started. Backend: \(backend.rawValue), streaming=\(isStreaming)",
          level: .info, category: "Pipeline"
        )
      }

    case .recordingStopped:
      emitRecordingStopped(sampleCount: audioCapture.capturedSamples.count)

    case .transcriptionStarted:
      breadcrumb(
        "asr", "Transcription started",
        ["mode": outcome.streamingMode ? "streaming" : "batch", "backend": backend.rawValue])
      Task {
        await AppLogger.shared.log(
          "Pipeline timing: ASR started (mode=\(outcome.streamingMode ? "streaming" : "batch"), backend=\(backend.rawValue))",
          level: .info, category: "PipelineTiming"
        )
      }

    case .asrCompleted:
      // TODO(test-fix): update KernelLifecycleTelemetrySinkTests for the round-2 ASR payload.
      let payload = asrCompletedPayload()
      breadcrumb("asr", "ASR completed", payload)
      Task {
        await AppLogger.shared.log(
          "Pipeline timing: ASR completed in \(payload["duration_s"] ?? "0.000")s "
            + "(mode=\(payload["mode"] ?? "batch"), \(payload["char_count"] ?? 0) chars, "
            + "lang=\(payload["language"] ?? "?"))",
          level: .info, category: "PipelineTiming"
        )
      }

    case .pipelineCompleted:
      breadcrumb("pipeline", "Pipeline complete", pipelineCompletedPayload())
      // #1167: a degraded-save completion (history write threw, delivery still
      // ran) must NOT stamp the "transcript durably saved" success marker — gate
      // on the save outcome mirrored on the telemetry side-channel.
      if !telemetryState.historySaveFailed {
        captureTelemetry.recordSuccessfulRecording()
      }

    case .failed(let reason):
      emitFailed(reason)

    case .audioInterrupted(let cause):
      // Capture the lost dictation for both surviving causes — each is a genuine
      // unowned loss (issue #1174 A3): `.engineLost` and, since #1408,
      // `.deviceRemoved` — the verified-disconnect half that used to hide inside
      // `.engineLost`. Splitting the cause must not halve the alert.
      // (`.maxDurationReached` was deleted by #1408 A3 — the cap is a normal
      // auto-stop and no longer stamps a cause at all. `.captureSessionLost`
      // was deleted by #1524; the XPC-connection cause by #1543 with the audio
      // boundary.) Category is `.audioCaptureFailed`, never `.xpcServiceError` —
      // a benign device disconnect must not page the "XPC Service Crash >1/hr"
      // alert.
      //
      // NOTE: reaching this terminal at all now means salvage did not produce a
      // transcript. A salvaged dictation ends `.completed` and never lands here,
      // so this emit no longer fires for a recording the user actually received.
      switch cause {
      case .engineLost, .deviceRemoved:
        let snapshot = recordingSnapshot()
        emitCaptureError(
          HeartPathError.audioEngineInterrupted(
            route: snapshot?.audioRoute ?? audioCapture.currentAudioRoute,
            durationMs: snapshot?.durationMs ?? 0),
          .audioCaptureFailed, "audio",
          ["was_recording": true, "backend": backend.rawValue],
          snapshot: snapshot)
      }
      updateRecordingState(false, nil, nil)

    case .asrInterrupted(let wasRecording):
      // Bridge matrix #3 — old TP:1145 emitted `was_recording == state == .recording`
      // at crash time. The kernel reaches `.asrInterrupted` from `.recording`
      // OR `.transcribing`; the observer threads the prior state in here.
      // PR-5 Rung 5 Pass 2 #3 — restore the `backend` extra and the
      // backend-named error message from OLD `WhisperKitPipeline.swift:1215-1221`
      // ("ASR XPC service crashed (WhisperKit)") so Sentry can slice the
      // crash bucket by backend again.
      let bv = backend.rawValue
      let backendLabel = backend == .whisperKit ? "WhisperKit" : "Parakeet"
      emitCaptureError(
        NSError(
          domain: "EnviousWispr", code: -3,
          userInfo: [
            NSLocalizedDescriptionKey: "ASR XPC service crashed (\(backendLabel))"
          ]),
        .xpcServiceError, "asr",
        ["was_recording": wasRecording, "backend": bv],
        snapshot: recordingSnapshot())
      updateRecordingState(false, nil, nil)

    case .discarded(let reason):
      // PR-1 §B.7.4 — the ONE new event the epic introduces. Old code was
      // silent for short recordings (TP:634). Sink emits a breadcrumb
      // carrying the abort reason so the timeline names which abort path
      // fired. Rich Sentry event design belongs to a later epic PR.
      breadcrumb(
        "recording", "Recording discarded",
        ["reason": String(describing: reason)])

    case .noSpeech(let source):
      // r7 — emit the source-appropriate breadcrumb to preserve PR-1's exact
      // name/string rule. VAD-gate path = TP:787; ASR-empty no-speech = TP:902.
      switch source {
      case .vadGate:
        // TODO(test-fix): update no-speech payload expectations for round-2 fields.
        breadcrumb(
          "asr", "VAD gate: no speech detected, skipping ASR",
          noSpeechVADGatePayload())
      case .asrEmptyNoSpeech:
        breadcrumb(
          "asr", "ASR empty (no speech detected)",
          [
            "backend": backend.rawValue,
            "mode": telemetryState.noSpeechTelemetry?.mode
              ?? (outcome.streamingMode ? "streaming" : "batch"),
          ])
      case .emptyAfterProcessing:
        // #1358: the limb chain produced no lexical content (bare filler /
        // non-speech artifact). Breadcrumb only — NOT a `heart_path_finalization`
        // Sentry capture (mirrors the #979 asr-empty downgrade).
        breadcrumb(
          "processing", "Text processing produced no lexical content",
          ["backend": backend.rawValue])
      }

    case .cancelled:
      // r7 — NO breadcrumb. PR-1 §B.7.4 allows only ONE new event
      // (`discarded`); a `.cancelled` breadcrumb would be a second new event.
      // The kernel state observer still tracks the `.cancelled` transition —
      // only the telemetry emission is omitted.
      break
    }
  }

  /// #1408: emit the interruption counter exactly once per interrupted session,
  /// at whatever terminal that session reaches. ONE site, not one per arm: a
  /// salvage can end `.completed`, `.audioInterrupted` (the floor), `.cancelled`
  /// (the user discarded it), or `.failed` (the audio came back but decoded to
  /// nothing), and a per-arm emit would quietly miss whichever arm nobody thought
  /// of. `terminalStateLabel` is exhaustive, so a new terminal must decide.
  ///
  /// Reads the same `telemetryState.interruptionCause` the kernel's salvage guard
  /// reads, and derives `salvage_attempted` from `hasRecoverableAudio` — the one
  /// authority — never a second copy of that switch.
  private func emitAudioCaptureInterruptedIfNeeded(for event: KernelLifecycleEvent) {
    guard let cause = telemetryState.interruptionCause,
      let terminal = Self.terminalStateLabel(for: event)
    else { return }
    audioCaptureInterrupted(
      cause.rawValue,
      cause.hasRecoverableAudio,
      terminal == "completed",
      terminal,
      backend.rawValue,
      telemetryState.recordingSnapshot?.durationMs)
  }

  /// The terminal each lifecycle event represents, or `nil` for a non-terminal
  /// event. Exhaustive on purpose.
  private static func terminalStateLabel(for event: KernelLifecycleEvent) -> String? {
    switch event {
    case .pipelineCompleted: "completed"
    case .failed: "failed"
    case .audioInterrupted: "audio_interrupted"
    case .asrInterrupted: "asr_interrupted"
    case .discarded: "discarded"
    case .noSpeech: "no_speech"
    case .cancelled: "cancelled"
    case .pipelineStartingUp, .modelLoading, .recordingCommitted, .recordingStopped,
      .transcriptionStarted, .asrCompleted:
      nil
    }
  }

  func emitRecordingStopped(sampleCount: Int) {
    breadcrumb(
      "recording", "Recording stopped",
      ["sample_count": sampleCount])
    updateRecordingState(false, nil, nil)
  }

  private func pipelineCompletedPayload() -> [String: Any] {
    let e2e =
      outcome.pipelineStartedAtSeconds.flatMap { start in
        outcome.pipelineEndedAtSeconds.map { $0 - start }
      } ?? 0
    let asr =
      outcome.asrStartedAtSeconds.flatMap { start in
        outcome.asrEndedAtSeconds.map { $0 - start }
      } ?? 0

    return [
      "e2e_s": String(format: "%.3f", e2e),
      "asr_s": String(format: "%.3f", asr),
      "polish_s": String(format: "%.3f", outcome.polishDurationSeconds),
      "paste_tier": outcome.pasteResult?.pasteTierLabel ?? "none",
      "backend": backend.rawValue,
    ]
  }

  private func asrCompletedPayload() -> [String: Any] {
    let duration =
      telemetryState.asrCompletedTelemetry?.durationSeconds
      ?? outcome.asrStartedAtSeconds.flatMap { start in
        outcome.asrEndedAtSeconds.map { $0 - start }
      }
      ?? 0
    let mode =
      telemetryState.asrCompletedTelemetry?.mode
      ?? (outcome.streamingMode ? "streaming" : "batch")
    var payload: [String: Any] = [
      "backend": backend.rawValue,
      "duration_s": String(format: "%.3f", duration),
      "char_count": telemetryState.asrCompletedTelemetry?.charCount ?? 0,
      "mode": mode,
      "language": telemetryState.asrCompletedTelemetry?.language ?? "unknown",
    ]
    // PR-5 Rung 5 Pass 2 r2 #B1: restore the OLD `"incremental"` breadcrumb key
    // (`WhisperKitPipeline.swift:1049-1052`); WhisperKit-only, omitted for
    // Parakeet where the field is nil.
    if let incremental = telemetryState.asrCompletedTelemetry?.incrementalAccepted {
      payload["incremental"] = incremental
    }
    // #1309 effective-path streaming facts (WhisperKit only; nil omitted).
    if let t = telemetryState.asrCompletedTelemetry {
      if let v = t.streamingRequested { payload["streaming_requested"] = v }
      if let v = t.streamingEffective { payload["streaming_effective"] = v }
      if let v = t.streamingDegradeReason { payload["streaming_degrade_reason"] = v }
      if let v = t.streamingFinalPath { payload["final_path"] = v }
      if let v = t.streamingDecodeCount { payload["streaming_decode_count"] = v }
      if let v = t.streamingCoveredSec { payload["streaming_covered_sec"] = v }
      if let v = t.tailDecodeSec { payload["tail_decode_sec"] = v }
      if let v = t.maxUnconfirmedWindowSec { payload["max_unconfirmed_window_sec"] = v }
      if let v = t.stopWhileDecodeInFlight { payload["stop_while_decode_in_flight"] = v }
    }
    // #950 tail-trim diagnostic (eligible Parakeet batch only; nil omitted).
    // `tail_dropped_ms` always present when set (incl. 0); `tail_had_energy` only
    // when a tail was dropped. Metadata only — no audio/content.
    if let droppedMs = telemetryState.asrCompletedTelemetry?.droppedTailMs {
      payload["tail_dropped_ms"] = droppedMs
    }
    if let hadEnergy = telemetryState.asrCompletedTelemetry?.tailHadEnergy {
      payload["tail_had_energy"] = hadEnergy
    }
    // #950 tail-preserve recovery + tuning signals (omit-on-nil, metadata only).
    if let preserved = telemetryState.asrCompletedTelemetry?.usedTailPreservation {
      payload["tail_preserved"] = preserved
    }
    if let recoveredMs = telemetryState.asrCompletedTelemetry?.recoveredTailMs {
      payload["tail_preserved_ms"] = recoveredMs
    }
    if let voicedFraction = telemetryState.asrCompletedTelemetry?.tailVoicedFraction {
      payload["tail_voiced_fraction"] = voicedFraction
    }
    if let refusedReason = telemetryState.asrCompletedTelemetry?.tailRefusedReason {
      payload["tail_refused_reason"] = refusedReason
    }
    // #1232 tail-clip telemetry (omit-on-nil, numbers/booleans only — no audio
    // or text). Lets cross-session triage tell capture-clip from ASR-drop.
    if let t = telemetryState.asrCompletedTelemetry {
      if let cls = t.tailClipClassification { payload["tail_clip_class"] = cls }
      if let v = t.captureTrailingSilenceMs { payload["capture_trailing_silence_ms"] = v }
      if let v = t.captureTail200Rms { payload["capture_tail_200_rms"] = v }
      if let v = t.captureTail200Peak { payload["capture_tail_200_peak"] = v }
      if let v = t.asrInputDurationMs { payload["asr_input_duration_ms"] = v }
      if let v = t.asrLastTokenEndMs { payload["asr_last_token_end_ms"] = v }
      if let v = t.asrLastTokenGapMs { payload["asr_last_token_gap_ms"] = v }
      if let v = t.asrChunked { payload["asr_chunked"] = v }
    }
    // #1434 degraded-lead salvage (omit-on-nil; set only on a salvaged
    // completion — Codex review r1 caught these being stamped onto
    // asrCompletedTelemetry but never read here, so a salvaged completion
    // was indistinguishable from a normal one in this breadcrumb).
    if let t = telemetryState.asrCompletedTelemetry {
      if let v = t.salvageAttempted { payload["salvage_attempted"] = v }
      if let v = t.salvageCandidateCount { payload["salvage_candidate_count"] = v }
      if let v = t.salvageSucceededAtTrimMs { payload["salvage_succeeded_at_trim_ms"] = v }
      if let v = t.salvageRemainingAudioMs { payload["salvage_remaining_audio_ms"] = v }
    }
    return payload
  }

  private func noSpeechVADGatePayload() -> [String: Any] {
    [
      "backend": backend.rawValue,
      "mode": telemetryState.noSpeechTelemetry?.mode
        ?? (outcome.streamingMode ? "streaming" : "batch"),
      "raw_sample_count": telemetryState.noSpeechTelemetry?.rawSampleCount
        ?? audioCapture.capturedSamples.count,
      "peak_audio_level": telemetryState.noSpeechTelemetry?.peakAudioLevel ?? 0,
    ]
  }

  private func recordingSnapshot() -> SentryBreadcrumb.RecordingSnapshot? {
    guard let snapshot = telemetryState.recordingSnapshot else { return nil }
    return SentryBreadcrumb.RecordingSnapshot(
      backend: snapshot.backend,
      audioRoute: snapshot.audioRoute,
      wasStreaming: snapshot.wasStreaming,
      startTime: snapshot.startTime,
      durationMs: snapshot.durationMs,
      targetAppBundleID: snapshot.targetAppBundleID ?? context.targetApp?.bundleIdentifier
    )
  }

  private func captureFailureExtra(error: any Error, failureMode: String) -> [String: Any] {
    AudioCaptureFailureExtras.build(
      error: error,
      audioCapture: audioCapture,
      failureMode: failureMode,
      backend: backend == .whisperKit ? backend.rawValue : nil
    )
  }

  private func emitCaptureError(
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?,
    snapshot: SentryBreadcrumb.RecordingSnapshot? = nil
  ) {
    if let snapshot {
      captureErrorWithSnapshot(error, category, stage, extra, snapshot)
    } else {
      captureError(error, category, stage, extra)
    }
  }

  private func modelLoadWedgedExtra(_ telemetry: KernelModelLoadWedgeTelemetry?) -> [String: Any] {
    [
      "backend": backend.rawValue,
      "silence_ms": telemetry?.silenceMs ?? 0,
      "observed_max_gap_ms": telemetry?.observedMaxGapMs ?? 0,
      "observed_phase": telemetry?.observedPhase ?? "kernel",
      "signal_count_total": telemetry?.signalCountTotal ?? 0,
      "first_signal_latency_ms": telemetry?.firstSignalLatencyMs ?? -1,
      "total_attempt_duration_ms": telemetry?.totalAttemptDurationMs ?? 0,
    ]
  }

  /// Per-failure-reason captureError emission. Mirrors old TP failure call
  /// sites with stage + message + core data; rich diagnostic dicts deferred.
  private func emitFailed(_ reason: RecordingFailureReason) {
    switch reason {
    case .modelWedged:
      let telemetry = modelLoadWedgeTelemetry()
      emitCaptureError(
        ModelLoadWatchdog.WedgeError(),
        .modelLoadWedged, "asr",
        modelLoadWedgedExtra(telemetry))
      modelLoadWedged(backend.rawValue, telemetry)
    case .modelLoadFailed:
      // PR-5 Rung 5 Pass 2 #2 — surface the real thrown error from
      // `telemetryState.modelLoadError` (set by the kernel before the
      // `.loadFailed` warmup return at `RecordingSessionKernel.swift:1324`)
      // instead of a synthesized placeholder. Parity with OLD
      // `WhisperKitPipeline.swift:475-477` which captured the thrown
      // `prepare()` error directly. Falls back to a placeholder only when
      // the error is somehow absent.
      let modelError =
        telemetryState.modelLoadError
        ?? NSError(
          domain: "EnviousWispr", code: -10,
          userInfo: [NSLocalizedDescriptionKey: "Model load failed"])
      emitCaptureError(
        modelError,
        .modelLoadFailed, "asr",
        ["backend": backend.rawValue])
    case .captureStartFailed:
      let error =
        telemetryState.captureFailureError
        ?? NSError(
          domain: "EnviousWispr", code: -11,
          userInfo: [NSLocalizedDescriptionKey: "Recording failed"])
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "thrown_start"))
    case .asrEmpty:
      // #979: ASR-empty on non-speech (ambient noise trips VAD, engine
      // correctly returns empty) is an EXPECTED outcome, not an error.
      // Evidence: 7 organic capture pairs all ambient non-speech (energy-mod
      // 0.08-0.19, no inter-word pauses); founder repro "airplane, light taps";
      // SuperWhisper logs the same condition and treats it as a soft notice.
      // The user already sees "Couldn't catch that" from the terminal STATE
      // (KernelDictationDriver), independent of this emit. Downgrade from a
      // Sentry error (which flagged a non-bug AND auto-filed issues via the
      // Sentry->GitHub triage) to a context-only breadcrumb. Frequency still
      // lives in PostHog pipeline.failed (error_code "Couldn't catch that --
      // try again"); engineering evidence still lives in the DEBUG
      // DictationAudioArchive. Both untouched.
      breadcrumb(
        "asr", "ASR returned empty text despite speech evidence",
        telemetryState.asrEmptyDiagnostics?.sentryExtra() ?? ["backend": backend.rawValue])
    case .emptyAfterProcessing:
      emitCaptureError(
        HeartPathError.emptyAfterProcessing(
          route: audioCapture.currentAudioRoute,
          wasPolishEnabled: telemetryState.polishEnabled),
        .heartPathFinalization, "processing",
        [
          "backend": backend.rawValue,
          "capture.route": audioCapture.currentAudioRoute,
          "polish.enabled": telemetryState.polishEnabled,
          "capture_session_id": Int(audioCapture.currentCaptureSessionID),
        ])
    case .asrFailed, .asrWedged:
      let error =
        telemetryState.transcriptionFailureError
        ?? NSError(
          domain: "EnviousWispr", code: -13,
          userInfo: [NSLocalizedDescriptionKey: "Transcription failed"])
      emitCaptureError(
        error,
        .asrFailed, "transcription",
        ["backend": backend.rawValue],
        snapshot: recordingSnapshot())
    case .permissionDenied:
      let error =
        telemetryState.captureFailureError
        ?? NSError(
          domain: "EnviousWispr", code: -14,
          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "permission_denied"))
    case .prepareFailed:
      let error =
        telemetryState.captureFailureError
        ?? NSError(
          domain: "EnviousWispr", code: -15,
          userInfo: [NSLocalizedDescriptionKey: "Prepare failed"])
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "prepare_failed"))
    case .captureStalled:
      // r8 (2026-05-25) — NO Sentry/PostHog emission for `.captureStalled`.
      // The rich `HeartPathTelemetryEmitter.stallFired(ctx:)` (`:91-116`)
      // already owns this terminal: it is reached via
      // `KernelHeartPathTelemetryObserver.handleCaptureStall(_:)` (`:94-100`)
      // from the App-routed `WedgeRecoveryRouter` → driver's
      // `HeartPathTelemetryTarget` conformance, with full
      // `SentryAudioExtras.buildCaptureExtras(...)` payload + per-session
      // dedup. The lifecycle event still fires (kernel state observability
      // is preserved); only the duplicate Sentry captureError is suppressed.
      //
      // Codex r8 flagged this as the convergence-escape signal: emitter
      // dedup is `private` to the emitter, so without this skip both paths
      // fire → Sentry double-counts. Skip-not-share is preferred over an
      // explicit shared dedup contract (scope creep for PR-4b.2).
      break
    case .zeroSignal:
      // #1317: same posture as `.captureStalled` above — NO second Sentry
      // emission. `HeartPathTelemetryEmitter.stallFired(ctx:)` already owns
      // the classified event, submitted either through the reactive
      // `WedgeRecoveryRouter` funnel or the kernel's STOP-time telemetry
      // closure (§3.6 N4). The lifecycle event still fires here.
      break
    case .noAudioCaptured:
      // Build the rich `NoAudioContext` (route, active-capture, source,
      // device IDs) and route through the injected sink. Default impl
      // emits a basic captureError; the factory wires it to
      // `emitter.noAudioCaptured(ctx:)` so production callers also get
      // the stall/XPC-failure dedup contract (Div 6 of seam audit /
      // TP:273-291 — restores the no-audio Sentry payload richness the
      // earlier `KernelLifecycleTelemetrySink` shipped without).
      let sampleCount = audioCapture.capturedSamples.count
      let snapshotDurationMs = telemetryState.recordingSnapshot?.durationMs ?? 0
      let computedDurationMs = sampleCount * 1000 / Int(AudioConstants.sampleRate)
      let preferredID = audioCapture.preferredInputDeviceIDOverride
      let resolvedRoute = audioCapture.currentResolvedRoute
      // #1434: the capture-health record was stamped before this terminal
      // (immediately post-stop), so the no-audio event carries it.
      let health = telemetryState.captureHealth
      let ctx = NoAudioContext(
        sessionID: audioCapture.currentCaptureSessionID,
        durationMs: max(snapshotDurationMs, computedDurationMs),
        wasStreaming: outcome.streamingMode,
        route: audioCapture.currentAudioRoute,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        captureSourceType: audioCapture.captureSourceType,
        inputDeviceUIDPreferred: preferredID.isEmpty ? nil : preferredID,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
        selectedTransport: resolvedRoute?.selected,
        effectiveTransport: resolvedRoute?.effective,
        routeReason: resolvedRoute?.routeReason,
        routeFallbackReason: resolvedRoute?.routeFallbackReason,
        inputSelectionMode: resolvedRoute?.inputSelectionMode,
        outputTransport: resolvedRoute?.outputTransport,
        routeResolutionSource: resolvedRoute?.routeResolutionSource,
        captureNativeRateHz: health?.stopMetadata?.nativeRateHz,
        captureRingDropCount: health?.stopMetadata?.ringDropCount,
        captureConverterErrorCount: health?.stopMetadata?.converterErrorCount,
        captureZeroOutputCount: health?.stopMetadata?.zeroOutputCount,
        captureRateDivergenceDetected: health?.stopMetadata?.rateDivergenceDetected,
        captureFormatStabilized: health?.formatStabilized,
        captureRebuiltForFormat: health?.captureRebuiltForFormat,
        captureNativeChannelCount: health?.stopMetadata?.nativeChannelCount
      )
      if let noAudioCapturedRich {
        noAudioCapturedRich(ctx)
      } else {
        // Fallback for callers that don't wire the rich sink (tests):
        // route through the injected `captureError` so the recorder
        // pattern observes the emission.
        let error = HeartPathError.noAudioCaptured(
          sessionID: ctx.sessionID, durationMs: ctx.durationMs,
          wasStreaming: ctx.wasStreaming, route: ctx.route)
        emitCaptureError(
          error,
          .audioCaptureFailed, "recording",
          captureFailureExtra(error: error, failureMode: "no_audio_captured"))
      }
    }
  }
}
