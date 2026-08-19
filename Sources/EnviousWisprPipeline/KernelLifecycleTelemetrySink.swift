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

  /// #1846. Optional-taking so `nil` means REMOVE, never a sentinel value.
  typealias TakeIDSink = @MainActor (_ takeID: String?) -> Void

  typealias AudioRouteSink = @MainActor (_ route: String) -> Void

  /// `takeID` (#1846) names WHICH dictation the event belongs to. Threaded as a
  /// parameter rather than read from `telemetryState` inside the default closure so
  /// a test observing this seam sees the exact value that reaches PostHog.
  typealias DictationInvokedSink = @MainActor (
    _ triggerSource: String, _ inputMode: String, _ targetApp: String?, _ takeID: String?
  ) -> Void

  typealias ModelLoadWedgedSink = @MainActor (
    _ backend: String, _ telemetry: KernelModelLoadWedgeTelemetry?
  ) -> Void

  /// #1845. Every optional is omit-when-nil at the `TelemetryService` boundary;
  /// `peakAudioLevel` is optional deliberately so a missing reading can never be
  /// emitted as an exact zero.
  typealias VADGateNoSpeechSink = @MainActor (
    _ backend: String, _ mode: String, _ rawSampleCount: Int, _ peakAudioLevel: Float?,
    _ wholeBufferRMS: Float?, _ maxWindowRMS: Float?, _ durationMs: Int?,
    _ effectiveTransport: String?, _ selectedTransport: String?, _ inputSelectionMode: String?,
    _ inputDeviceKind: String?, _ captureNativeRateHz: Double?, _ captureNativeChannelCount: Int?,
    _ takeID: String?
  ) -> Void

  /// #1884 `dictation.started` — the denominator. Deliberately minimal: this
  /// event exists to be counted, and every fact worth knowing about a take is
  /// already on its terminal row.
  typealias DictationStartedSink = @MainActor (
    _ takeID: String, _ backend: String
  ) -> Void

  /// #1884 `dictation.terminal`. `result` is one of the seven terminal labels;
  /// `reason` is a `TerminalNoticeReason.rawValue` and is nil unless the terminal
  /// is `.failed`. The attribution block is nil unless the take was signal-free.
  typealias DictationTerminalSink = @MainActor (
    _ takeID: String, _ backend: String, _ result: String, _ reason: String?,
    _ inputDeviceKind: String?, _ effectiveTransport: String?, _ selectedTransport: String?,
    _ inputSelectionMode: String?, _ wholeBufferRMS: Float?, _ maxWindowRMS: Float?,
    _ peakAudioLevel: Float?, _ durationMs: Int?, _ captureNativeRateHz: Double?,
    _ captureNativeChannelCount: Int?,
    // #2184: what the VAD's segments did to this take's audio. All four are nil
    // when the take concluded before the conditioner ran, which is the reading
    // rather than a gap. Owner: `KernelVADConditioningTelemetry`.
    _ vadRawSampleCount: Int?, _ vadFilteredSampleCount: Int?,
    _ vadRetainedRatio: Double?, _ vadConditioningReason: String?,
    // #2087: `ordinary` or `escape_recovery`. An Escape Recovery session
    // concludes `.completed` like any other, so without this the terminal row
    // reports withheld text as a delivered dictation.
    _ deliveryDisposition: String?
  ) -> Void

  typealias CaptureErrorSink = @MainActor (
    _ error: any Error & StableSentryErrorIdentity,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?
  ) -> Void

  typealias SnapshotCaptureErrorSink = @MainActor (
    _ error: any Error & StableSentryErrorIdentity,
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
    _ terminalState: String, _ backend: String, _ recordingDurationMs: Int?,
    _ takeID: String?
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
  private let updateTakeID: TakeIDSink
  private let updateAudioRoute: AudioRouteSink
  private let dictationInvoked: DictationInvokedSink
  private let modelLoadWedged: ModelLoadWedgedSink
  private let vadGateNoSpeech: VADGateNoSpeechSink

  /// #1884 `dictation.started`. Primitives rather than the snapshot type because
  /// `TelemetryService` lives in Services and cannot see Pipeline types — the
  /// dependency runs one way only.
  private let dictationStarted: DictationStartedSink

  /// #1884 `dictation.terminal`. Destructured for the same reason.
  private let dictationTerminal: DictationTerminalSink
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
  /// Heartpath 5b (#1520): emit `audio.dead_mic_recovery` when a durable success
  /// resolves a pending dead-mic watch (audio flowed again on a later take).
  /// No-op default so direct sink tests stay source-compatible; the factory
  /// wires it to the same emitter method the kernel's later-retire path uses.
  private let deadMicRecovered: @MainActor (DeadMicRecoveryOutcome) -> Void

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
    // #1846: INERT by default, unlike every sibling seam here, which defaults to
    // the real SDK call. The asymmetry is deliberate and it is the safer default
    // for a NEW seam: `KernelLifecycleRecordingScopeBaselineTests` must compile
    // against `origin/main`, so it cannot name this argument, and a real-SDK
    // default would make that file mutate process-global Sentry scope while
    // claiming in its own header that it touches no vendor scope. Production
    // wires it explicitly in `KernelDictationDriverFactory`.
    //
    // Scope of that protection, stated exactly: it covers DIRECT sink
    // constructions in unit tests, which the terminal postamble below would
    // otherwise drag onto the real scope. Tests that build a driver through the
    // factory still get production wiring, as they already do for the five sibling
    // seams whose defaults call the real SDK.
    //
    // An inert default is a footgun — a dropped factory line would leave the
    // feature tested, documented and dead. That is closed by
    // `productionFactoryWiresTheTakeKey` in `KernelLifecycleTelemetrySinkTests`,
    // which fails if the factory stops wiring this seam. Do not delete that test
    // without restoring a real default here.
    updateTakeID: @escaping TakeIDSink = { _ in },
    updateAudioRoute: @escaping AudioRouteSink = { route in
      SentryBreadcrumb.updateAudioRoute(route)
    },
    dictationInvoked: @escaping DictationInvokedSink = { trigger, mode, target, takeID in
      TelemetryService.shared.dictationInvoked(
        triggerSource: trigger, inputMode: mode, targetApp: target, takeID: takeID)
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
    vadGateNoSpeech: @escaping VADGateNoSpeechSink = {
      backend, mode, rawSampleCount, peakAudioLevel, wholeBufferRMS, maxWindowRMS, durationMs,
      effectiveTransport, selectedTransport, inputSelectionMode, inputDeviceKind,
      captureNativeRateHz, captureNativeChannelCount, takeID in
      TelemetryService.shared.vadGateNoSpeech(
        backend: backend, mode: mode, rawSampleCount: rawSampleCount,
        peakAudioLevel: peakAudioLevel, wholeBufferRMS: wholeBufferRMS,
        maxWindowRMS: maxWindowRMS, durationMs: durationMs,
        effectiveTransport: effectiveTransport, selectedTransport: selectedTransport,
        inputSelectionMode: inputSelectionMode, inputDeviceKind: inputDeviceKind,
        captureNativeRateHz: captureNativeRateHz,
        captureNativeChannelCount: captureNativeChannelCount, takeID: takeID)
    },
    dictationStarted: @escaping DictationStartedSink = { takeID, backend in
      TelemetryService.shared.dictationStarted(takeID: takeID, backend: backend)
    },
    dictationTerminal: @escaping DictationTerminalSink = {
      takeID, backend, result, reason, inputDeviceKind, effectiveTransport, selectedTransport,
      inputSelectionMode, wholeBufferRMS, maxWindowRMS, peakAudioLevel, durationMs,
      captureNativeRateHz, captureNativeChannelCount, vadRawSampleCount, vadFilteredSampleCount,
      vadRetainedRatio, vadConditioningReason, deliveryDisposition in
      TelemetryService.shared.dictationTerminal(
        takeID: takeID, backend: backend, result: result, reason: reason,
        inputDeviceKind: inputDeviceKind, effectiveTransport: effectiveTransport,
        selectedTransport: selectedTransport, inputSelectionMode: inputSelectionMode,
        wholeBufferRMS: wholeBufferRMS, maxWindowRMS: maxWindowRMS,
        peakAudioLevel: peakAudioLevel, durationMs: durationMs,
        captureNativeRateHz: captureNativeRateHz,
        captureNativeChannelCount: captureNativeChannelCount,
        deliveryDisposition: deliveryDisposition,
        vadRawSampleCount: vadRawSampleCount,
        vadFilteredSampleCount: vadFilteredSampleCount,
        vadRetainedRatio: vadRetainedRatio,
        vadConditioningReason: vadConditioningReason)
    },
    captureError: @escaping CaptureErrorSink = { error, category, stage, extra in
      // #2021: promote the groupable capture fields to per-event TAGS. This sink
      // carries `AudioCaptureFailureExtras.build` output, so it emits the same
      // two fields as the other three default sinks and needs the same
      // promotion — a partially-tagged population is worse than an untagged one,
      // because an aggregate over it looks complete.
      SentryBreadcrumb.captureError(
        error, category: category, stage: stage, extra: extra,
        tags: SentryAudioExtras.promotedTags(from: extra))
    },
    captureErrorWithSnapshot: @escaping SnapshotCaptureErrorSink = {
      error, category, stage, extra, snapshot in
      SentryBreadcrumb.captureError(
        error, category: category, stage: stage, extra: extra, snapshot: snapshot,
        tags: SentryAudioExtras.promotedTags(from: extra))
    },
    noAudioCapturedRich: NoAudioCapturedSink? = nil,
    audioCaptureInterrupted: @escaping AudioCaptureInterruptedSink = {
      cause, attempted, succeeded, terminal, backend, durationMs, takeID in
      TelemetryService.shared.audioCaptureInterrupted(
        cause: cause, salvageAttempted: attempted, salvageSucceeded: succeeded,
        terminalState: terminal, backend: backend, recordingDurationMs: durationMs,
        takeID: takeID)
    },
    deadMicRecovered: @escaping @MainActor (DeadMicRecoveryOutcome) -> Void = { _ in }
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
    self.updateTakeID = updateTakeID
    self.updateAudioRoute = updateAudioRoute
    self.dictationInvoked = dictationInvoked
    self.modelLoadWedged = modelLoadWedged
    self.vadGateNoSpeech = vadGateNoSpeech
    self.dictationStarted = dictationStarted
    self.dictationTerminal = dictationTerminal
    self.captureError = captureError
    self.captureErrorWithSnapshot = captureErrorWithSnapshot
    self.noAudioCapturedRich = noAudioCapturedRich
    self.audioCaptureInterrupted = audioCaptureInterrupted
    self.deadMicRecovered = deadMicRecovered
  }

  /// Switch over the 12-case lifecycle vocabulary and emit each PR-1 §B.7.2
  /// kernel-owned event with byte-identical event identity
  /// (stage / message / category / event name). Payload fidelity per §3.7
  /// mapping table — preserved where the sink can read, deferred where rich
  /// kernel-side wiring would be required (§2.2 non-goals).
  /// #1846 cloud review: establish the take tag SYNCHRONOUSLY at session
  /// acceptance, before the kernel spawns any work.
  ///
  /// `emit` refreshes the tag on every lifecycle event, but the first such event
  /// arrives through `observeKernelState`'s unstructured `Task { @MainActor }`,
  /// which has no ordering guarantee against the kernel's own spawned
  /// `runForwardPath`. Model-load and capture-start failures — the errors most
  /// likely to fire early in a session, and exactly the ones this feature exists
  /// to join — could therefore be raised before the tag existed and ship
  /// untagged. The kernel calls this inside `start(config:)` itself, so the
  /// window is closed by construction rather than by scheduling luck.
  ///
  /// Deliberately routed through the SAME `updateTakeID` writer as the per-event
  /// refresh and the terminal clear: this type stays the single owner of that
  /// scope tag.
  func establishTakeID(_ takeID: String) {
    updateTakeID(takeID)
  }

  /// #1884: BOTH acceptance effects, through one method and one identity.
  ///
  /// The Sentry take tag first (unchanged, same single writer), then exactly one
  /// `dictation.started`. They share the `takeID` the kernel just minted — no
  /// second callback, no second identity.
  ///
  /// This is the denominator. A take that never reaches a terminal is only
  /// visible as the difference between this event and `dictation.terminal`, so
  /// an accepted session that emits nothing here is invisible rather than
  /// merely uncounted.
  func acceptSession(takeID: String) {
    updateTakeID(takeID)
    dictationStarted(takeID, backend.rawValue)
  }

  /// #1884: exactly one row per ACCEPTED terminal, rendered from the immutable
  /// snapshot and nothing else.
  ///
  /// Reads no live state on purpose. By the time this runs, `finishTerminal`'s
  /// cleanup has torn down callbacks, tasks, the adapter and capture state, and
  /// the next take may already be running — so anything consulted here could
  /// describe a different dictation than the one being reported.
  func emitTerminal(_ snapshot: KernelTerminalTelemetrySnapshot) {
    let event = snapshot.outcome.lifecycleEvent
    guard let result = Self.terminalStateLabel(for: event) else {
      // Unreachable: every `RecordingOutcome` projects to a terminal, and a
      // projection test freezes that. Refusing beats emitting `result: nil`,
      // which would be an unqueryable row that still counts in the denominator.
      return
    }
    // Read from the PROJECTED event, never from the raw outcome. `.noTransport`
    // projects to `.failed(.noAudioCaptured)`, so an outcome-side match labels the
    // row `failed` with no reason at all — a failure invisible to every
    // reason-keyed count (whole-diff review 2026-07-31). One projection decides
    // both fields, so they cannot disagree.
    let reason: String? =
      if case .failed(let failureReason) = event {
        failureReason.terminalNoticeReason.rawValue
      } else {
        nil
      }
    let attribution = snapshot.signalAttribution
    // #2184: read from the SNAPSHOT, never from `telemetryState` — take B may
    // already be running by the time this renders, and the whole reason the
    // snapshot exists is that live state cannot answer for a concluded take.
    let conditioning = snapshot.vadConditioning
    dictationTerminal(
      snapshot.takeID, snapshot.backend, result, reason,
      attribution?.inputDeviceKind, attribution?.effectiveTransport,
      attribution?.selectedTransport, attribution?.inputSelectionMode,
      attribution?.wholeBufferRMS, attribution?.maxWindowRMS,
      attribution?.peakAudioLevel, attribution?.durationMs,
      attribution?.captureNativeRateHz, attribution?.captureNativeChannelCount,
      conditioning?.rawSampleCount, conditioning?.filteredSampleCount,
      conditioning?.retainedRatio, conditioning?.conditioningReason,
      snapshot.deliveryDisposition.rawValue)
  }

  func emit(_ event: KernelLifecycleEvent) {
    // #1846: establish the take key FIRST, before the pre-switch interruption
    // counter and before any breadcrumb, error or PostHog emission. Required on
    // EVERY event, not just the start one: `withObservationTracking` is not a
    // lossless queue (`KernelHeartPathTelemetryObserver.handleObservationChange`
    // dispatches every coalesced delta event), so a terminal can be handled in
    // the same fire as its start — and if the tag were only set at start, a
    // coalesced fire would leave the terminal error untagged.
    updateTakeID(telemetryState.takeID)
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
      dictationInvoked(triggerSource, inputMode, targetApp, telemetryState.takeID)
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
        if let recovery = captureTelemetry.recordSuccessfulRecording(
          recoveryTransport: audioCapture.currentResolvedRoute?.effective ?? "unknown",
          sessionID: audioCapture.currentCaptureSessionID)
        {
          deadMicRecovered(recovery)
        }
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
      // boundary.) Category is `.audioCaptureFailed`, never `.xpcServiceError`,
      // because a device disconnect is an audio failure and not an XPC one.
      //
      // The old justification here claimed the category choice kept a benign
      // disconnect from paging the "XPC Service Crash >1/hr" alert. That was
      // FALSE and is deleted rather than reworded: the rate rules were plain
      // `count()` over `is:unresolved` and filtered by no category at all, so
      // both categories fed the same counter and the choice changed nothing
      // about what fired (#1965, verified against the live rule definitions).
      // The category is still right; only the stated reason was wrong.
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
    // Arm-local clear REMOVED (#1846): the generic terminal postamble below is
    // now the single owner, so every terminal clears on exactly one path.

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
      // #1707: which salvage outcome preceded this terminal — absent when the
      // interruption was never salvage-eligible (recovery not attempted).
      var extra: [String: Any] = ["was_recording": wasRecording, "backend": bv]
      if let salvageOutcome = telemetryState.asrSalvageOutcome {
        extra["asr_salvage_outcome"] = salvageOutcome.rawValue
      }
      // #1707 Phase 2: a retry preempted by a competing interruption before
      // its own result was accepted leaves `.attempted` as the FINAL
      // recorded value (§3a) — this is where that value actually surfaces,
      // since that race publishes `.asrInterrupted`, not `.asrFailed`.
      if let retryOutcome = telemetryState.asrRetryOutcome {
        extra["asr_retry_outcome"] = retryOutcome.rawValue
      }
      emitCaptureError(
        KernelFallbackSentryError.xpcServiceError(backendLabel: backendLabel),
        .xpcServiceError, "asr",
        extra,
        snapshot: recordingSnapshot())
    // Arm-local clear REMOVED (#1846) — see the terminal postamble below.

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
        // #1845: ONE computation, TWO records. The breadcrumb is unchanged in
        // name and stage; the tally is new and is the only countable evidence
        // this terminal has ever produced — a breadcrumb is attached to a later
        // Sentry event, and a no-speech terminal fires none, so until now these
        // takes were invisible.
        let facts = vadGateNoSpeechFacts()
        breadcrumb(
          "asr", "VAD gate: no speech detected, skipping ASR",
          noSpeechVADGatePayload(facts))
        vadGateNoSpeech(
          facts.backend, facts.mode, facts.rawSampleCount, facts.peakAudioLevel,
          facts.wholeBufferRMS, facts.maxWindowRMS, facts.durationMs,
          facts.effectiveTransport, facts.selectedTransport, facts.inputSelectionMode,
          facts.inputDeviceKind, facts.captureNativeRateHz, facts.captureNativeChannelCount,
          facts.takeID)
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

    case .asrEmptyDespiteAudio:
      // #1920: context-only breadcrumb, mirroring the `.failed(.asrEmpty)` arm
      // this replaces (#979 already downgraded that one from a Sentry error).
      // NO Sentry event: nothing failed. The countable record is the
      // `asr_empty_despite_audio` value on the `dictation_terminal` row, which
      // already carries `take_id`, device kind, both transports, the energy
      // triple and duration — so no dedicated audio event was minted (a second
      // record would overlap it, the #1845 lesson). A breadcrumb cannot carry
      // the count either, because a no-error terminal fires no Sentry event for
      // it to attach to.
      breadcrumb(
        "asr", "ASR returned empty text while audio was arriving",
        telemetryState.asrEmptyDiagnostics?.sentryExtra() ?? ["backend": backend.rawValue])

    case .cancelled:
      // r7 — NO breadcrumb. PR-1 §B.7.4 allows only ONE new event
      // (`discarded`); a `.cancelled` breadcrumb would be a second new event.
      // The kernel state observer still tracks the `.cancelled` transition —
      // only the telemetry emission is omitted.
      break
    }

    // #1846: ONE generic terminal postamble, reached after the event-specific arm
    // so the terminal event itself still carries the take key. `terminalStateLabel`
    // is the closed seven-terminal authority, so a new terminal cannot silently
    // skip cleanup — it has to decide there first.
    //
    // This is the single owner of the terminal `recording.active` clear ON THIS
    // PATH. Measured before this change: five terminal arms had no arm-local
    // clear (`.pipelineCompleted`, `.failed`, `.discarded`, `.noSpeech`,
    // `.cancelled`) and two did (`.audioInterrupted`, `.asrInterrupted`); those
    // two arm-local calls were REMOVED rather than left as duplicates.
    // `.pipelineCompleted` normally follows the `.recordingStopped` marker, which
    // clears capture scope at `emitRecordingStopped`, but the postamble
    // deliberately does not depend on that route.
    //
    // Measured, not remembered — `grep -rn "updateRecordingState(" Sources/`
    // returns exactly three CLEAR sites: this postamble, `emitRecordingStopped`
    // below, and one OUTSIDE this file.
    //
    // The outside site is deliberate, and it is an EARLIER EMERGENCY CLEAR rather
    // than a competing terminal-arm owner:
    // `KernelDictationDriver.handleEngineInterruption` clears `recording.active`
    // immediately for `.arming`, `.stopping` and `.delivering`, then routes the
    // session toward a later `.cancelled` terminal. Keeping that earlier write
    // preserves its synchronous freshness guarantee while this postamble provides
    // route-independent terminal cleanup. The writes are idempotent, but the
    // redundancy is not free — it is one extra process-global scope mutation, and
    // that cost is accepted in exchange for closing the stale window before the
    // asynchronously observed terminal arrives. The take key needs no early clear
    // there because it must stay live through the terminal event itself.
    if Self.terminalStateLabel(for: event) != nil {
      updateTakeID(nil)
      updateRecordingState(false, nil, nil)
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
      telemetryState.recordingSnapshot?.durationMs,
      telemetryState.takeID)
  }

  /// The terminal each lifecycle event represents, or `nil` for a non-terminal
  /// event. Exhaustive on purpose.
  /// Internal since #1884 so the projection tests can verify that every
  /// `RecordingOutcome` maps to a terminal label. The enclosing type is already
  /// `internal` and the tests already use `@testable`, so `package` would widen
  /// access without buying anything — `internal` is the narrowest that works.
  static func terminalStateLabel(for event: KernelLifecycleEvent) -> String? {
    switch event {
    case .pipelineCompleted: "completed"
    case .failed: "failed"
    case .audioInterrupted: "audio_interrupted"
    case .asrInterrupted: "asr_interrupted"
    case .discarded: "discarded"
    case .noSpeech: "no_speech"
    // #1920: its OWN terminal result, an additive eighth value. NOT `failed`
    // (nothing failed) and NOT `no_speech` (we cannot assert absence of speech,
    // and `analytics-operations.md` documents `no_speech` as a quiet room).
    // The `asr_empty_with_speech` series drops to zero at this release boundary;
    // that drop IS this change, not a fix.
    case .asrEmptyDespiteAudio: "asr_empty_despite_audio"
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

  /// #1845: everything the `.vadGate` terminal reports, computed ONCE and fed to
  /// BOTH the Sentry breadcrumb and the PostHog tally. Two independent reads
  /// would let the two records describe the same take differently.
  ///
  /// Every route and format value here is frozen: route from
  /// `noSpeechTelemetry` (stamped at the classifier site from this take's
  /// `lastResolvedRoute`), format from `captureHealth.stopMetadata` (stamped
  /// immediately post-stop, before every early terminal). Nothing reads
  /// `audioCapture.currentResolvedRoute`, which is live and can describe a
  /// later source by the time a terminal renders.
  private struct VADGateNoSpeechFacts {
    let backend: String
    let mode: String
    let rawSampleCount: Int
    /// Optional and NEVER defaulted to `0`. An exact zero is the signature of a
    /// digitally dead channel (#1809); manufacturing one from missing state
    /// would make absent data look like the finding we are hunting.
    let peakAudioLevel: Float?
    let wholeBufferRMS: Float?
    let maxWindowRMS: Float?
    let durationMs: Int?
    let effectiveTransport: String?
    let selectedTransport: String?
    let inputSelectionMode: String?
    /// #1845: `built_in_mic` / `jack_input`, refining the ambiguous `built_in`
    /// transport into the two physical inputs it covers. nil elsewhere.
    let inputDeviceKind: String?
    let captureNativeRateHz: Double?
    let captureNativeChannelCount: Int?
    let takeID: String?
  }

  private func vadGateNoSpeechFacts() -> VADGateNoSpeechFacts {
    let noSpeech = telemetryState.noSpeechTelemetry
    let health = telemetryState.captureHealth
    return VADGateNoSpeechFacts(
      backend: backend.rawValue,
      mode: noSpeech?.mode ?? (outcome.streamingMode ? "streaming" : "batch"),
      rawSampleCount: noSpeech?.rawSampleCount ?? audioCapture.capturedSamples.count,
      peakAudioLevel: noSpeech?.peakAudioLevel,
      wholeBufferRMS: noSpeech?.wholeBufferRMS,
      maxWindowRMS: noSpeech?.maxWindowRMS,
      durationMs: telemetryState.recordingSnapshot?.durationMs,
      effectiveTransport: noSpeech?.effectiveTransport,
      selectedTransport: noSpeech?.selectedTransport,
      inputSelectionMode: noSpeech?.inputSelectionMode,
      inputDeviceKind: noSpeech?.inputDeviceKind,
      captureNativeRateHz: health?.stopMetadata?.nativeRateHz,
      captureNativeChannelCount: health?.stopMetadata?.nativeChannelCount,
      // Read BEFORE the generic terminal postamble clears the take key. The
      // postamble deliberately runs after the event-specific arm for exactly
      // this reason; if it is ever moved above the switch, the §11.2 take-key
      // test fails rather than the property silently emptying.
      takeID: telemetryState.takeID
    )
  }

  private func noSpeechVADGatePayload(_ facts: VADGateNoSpeechFacts) -> [String: Any] {
    var payload: [String: Any] = [
      "backend": facts.backend,
      "mode": facts.mode,
      "raw_sample_count": facts.rawSampleCount,
    ]
    if let v = facts.peakAudioLevel { payload["peak_audio_level"] = v }
    if let v = facts.wholeBufferRMS { payload["whole_buffer_rms"] = v }
    if let v = facts.maxWindowRMS { payload["max_window_rms"] = v }
    if let v = facts.durationMs { payload["duration_ms"] = v }
    if let v = facts.effectiveTransport { payload["effective_transport"] = v }
    if let v = facts.selectedTransport { payload["selected_transport"] = v }
    if let v = facts.inputSelectionMode { payload["input_selection_mode"] = v }
    if let v = facts.inputDeviceKind { payload["input_device_kind"] = v }
    if let v = facts.captureNativeRateHz { payload["capture_native_rate_hz"] = v }
    if let v = facts.captureNativeChannelCount { payload["capture_native_channel_count"] = v }
    return payload
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
    _ error: any Error & StableSentryErrorIdentity,
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
        ?? KernelFallbackSentryError.modelLoadFailed
      emitCaptureError(
        modelError,
        .modelLoadFailed, "asr",
        ["backend": backend.rawValue])
    case .captureStartFailed:
      let error =
        telemetryState.captureFailureError
        ?? KernelFallbackSentryError.captureStartFailed
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "thrown_start"))
    case .noMicrophoneFound:
      // #1558: no usable input device on the toggle/menu start path. Keeps the
      // `audio_capture_failed` cluster populated (distinct `failureMode`) so the
      // held-release drop can still be watched post-ship.
      let error =
        telemetryState.captureFailureError
        ?? KernelFallbackSentryError.noMicrophoneFound
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "no_microphone_found"))
    case .asrEmpty:
      // #1920: UNREACHABLE — `RecordingFailureReason.asrEmpty` has no production
      // producer since the empty-decode path was re-typed to
      // `.asrEmptyDespiteAudio` (see that case's own arm above). Retained with
      // the reason case itself; the notes below are the #979 provenance and
      // describe the pre-#1920 shape.
      // #979: ASR-empty on non-speech (ambient noise trips VAD, engine
      // correctly returns empty) is an EXPECTED outcome, not an error.
      // Evidence: 7 organic capture pairs all ambient non-speech (energy-mod
      // 0.08-0.19, no inter-word pauses); founder repro "airplane, light taps";
      // SuperWhisper logs the same condition and treats it as a soft notice.
      // The user already sees the terminal notice ("Transcription error. Try
      // again.", #1558) from the terminal STATE (KernelDictationDriver),
      // independent of this emit. Downgrade from a Sentry error (which flagged
      // a non-bug AND auto-filed issues via the Sentry->GitHub triage) to a
      // context-only breadcrumb. Frequency still lives in PostHog
      // pipeline.failed (error_code "asr_empty_with_speech"); engineering
      // evidence still lives in the DEBUG DictationAudioArchive. Both remain intact.
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
      // Row 8 (#1525 PR J-1): `transcriptionFailureError` stays `(any Error)?`
      // because Parakeet's raw-vendor passthrough can be a non-conforming
      // CoreML error (the recognized FluidAudio path already conforms). A
      // conforming value (including the `KernelFallbackSentryError` default)
      // passes through unchanged; a genuine miss becomes `.coreML`/
      // `.unexpectedTranscriptionFailure` — never a silent drop.
      let error =
        telemetryState.transcriptionFailureError
        ?? KernelFallbackSentryError.transcriptionFailed
      // #1707 Phase 2: a retry this session accepted as exhausted surfaces
      // here (the retry-exhausted `default:` branch sets `.retryExhausted`
      // immediately before this terminal fires) — absent when no Phase-2
      // retry was ever consulted (the pre-capture producer).
      var asrFailedExtra: [String: Any] = ["backend": backend.rawValue]
      if let retryOutcome = telemetryState.asrRetryOutcome {
        asrFailedExtra["asr_retry_outcome"] = retryOutcome.rawValue
      }
      emitCaptureError(
        SentryCaptureBoundaryError.normalizingTranscriptionFailure(error),
        .asrFailed, "transcription",
        asrFailedExtra,
        snapshot: recordingSnapshot())
    case .permissionDenied:
      let error =
        telemetryState.captureFailureError
        ?? KernelFallbackSentryError.permissionDenied
      emitCaptureError(
        error,
        .audioCaptureFailed, "recording",
        captureFailureExtra(error: error, failureMode: "permission_denied"))
    case .prepareFailed:
      let error =
        telemetryState.captureFailureError
        ?? KernelFallbackSentryError.prepareFailed
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
