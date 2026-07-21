import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelLifecycleTelemetrySinkTests (epic #827, PR-4b.2 §11)
//
// Coverage gate for `KernelLifecycleTelemetrySink`. The sink renders each
// `KernelLifecycleEvent` value into byte-identical Sentry / PostHog calls
// (stage / message / category / event name) so PR-4b.4's App cutover
// preserves the telemetry timeline.
//
// All five injected sink seams are closure-recorders so the tests inspect
// emissions directly. The r8 negative tests (`failedCaptureStalledEmitsNothing`
// + `failedNoAudioCapturedEmitsNothing`) lock the skip-not-share invariant:
// the rich `HeartPathTelemetryEmitter` owns those two terminals, and the
// lifecycle sink must NOT emit a duplicate `captureError(.audioCaptureFailed)`
// for them.

@MainActor
@Suite struct KernelLifecycleTelemetrySinkTests {

  // MARK: - Recorder

  @MainActor
  private final class Recorder {
    struct BreadcrumbCall: Equatable {
      let stage: String
      let message: String
      let dataKeys: [String]  // sorted keys — Any-typed values aren't Equatable
    }
    struct RecordingStateCall: Equatable {
      let active: Bool
      let backend: String?
      let isStreaming: Bool?
    }
    struct DictationInvokedCall: Equatable {
      let triggerSource: String
      let inputMode: String
      let targetApp: String?
    }
    struct CaptureErrorCall: Equatable {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let errorDescription: String
      let extraKeys: [String]  // sorted — Any-typed values aren't Equatable
    }

    /// #1408: the non-paging `audio.capture_interrupted` counter.
    struct AudioCaptureInterruptedCall: Equatable {
      let cause: String
      let salvageAttempted: Bool
      let salvageSucceeded: Bool
      let terminalState: String
      let backend: String
    }

    var breadcrumbs: [BreadcrumbCall] = []
    var recordingStates: [RecordingStateCall] = []
    var audioRoutes: [String] = []
    var dictationsInvoked: [DictationInvokedCall] = []
    var modelLoadWedgedBackends: [String] = []
    var captureErrors: [CaptureErrorCall] = []
    var audioCaptureInterruptions: [AudioCaptureInterruptedCall] = []
    var deadMicRecoveries: [DeadMicRecoveryOutcome] = []
  }

  // MARK: - Sink construction with recorder seams

  private func makeSink(
    recorder: Recorder,
    backend: ASRBackendType = .parakeet,
    context: KernelSessionContext = KernelSessionContext(),
    telemetryState: KernelTelemetryState = KernelTelemetryState(),
    captureTelemetry: CaptureTelemetryState = CaptureTelemetryState()
  ) -> KernelLifecycleTelemetrySink {
    KernelLifecycleTelemetrySink(
      backend: backend,
      audioCapture: FakeAudioCapture(),
      context: context,
      captureTelemetry: captureTelemetry,
      telemetryState: telemetryState,
      breadcrumb: { stage, message, data in
        recorder.breadcrumbs.append(
          Recorder.BreadcrumbCall(
            stage: stage, message: message,
            dataKeys: (data?.keys.map { $0 } ?? []).sorted()))
      },
      updateRecordingState: { active, backend, isStreaming in
        recorder.recordingStates.append(
          Recorder.RecordingStateCall(active: active, backend: backend, isStreaming: isStreaming))
      },
      updateAudioRoute: { route in recorder.audioRoutes.append(route) },
      dictationInvoked: { trigger, mode, target in
        recorder.dictationsInvoked.append(
          Recorder.DictationInvokedCall(
            triggerSource: trigger, inputMode: mode, targetApp: target))
      },
      modelLoadWedged: { backend, _ in recorder.modelLoadWedgedBackends.append(backend) },
      captureError: { error, category, stage, extra in
        recorder.captureErrors.append(
          Recorder.CaptureErrorCall(
            category: category, stage: stage, errorDescription: error.localizedDescription,
            extraKeys: (extra?.keys.map { $0 } ?? []).sorted()))
      },
      // #1408: injected so no test ever reaches the real PostHog SDK
      // (`tests-no-process-global-mutable-delegate`).
      audioCaptureInterrupted: { cause, attempted, succeeded, terminal, backend, _ in
        recorder.audioCaptureInterruptions.append(
          Recorder.AudioCaptureInterruptedCall(
            cause: cause, salvageAttempted: attempted, salvageSucceeded: succeeded,
            terminalState: terminal, backend: backend))
      },
      deadMicRecovered: { recorder.deadMicRecoveries.append($0) })
  }

  // MARK: - Per-event byte-identical event identity

  @Test(".pipelineStartingUp emits the 'Pipeline starting up' breadcrumb (Pass 2 #1)")
  func pipelineStartingUpEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.pipelineStartingUp)
    #expect(
      recorder.breadcrumbs == [
        .init(stage: "pipeline", message: "Pipeline starting up", dataKeys: ["backend"])
      ])
    #expect(recorder.captureErrors.isEmpty)
  }

  @Test(".modelLoading emits the TP:365 'Model loading' breadcrumb")
  func modelLoadingEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.modelLoading)
    #expect(
      recorder.breadcrumbs == [
        .init(stage: "asr", message: "Model loading", dataKeys: ["backend"])
      ])
    #expect(recorder.captureErrors.isEmpty)
  }

  @Test(".recordingCommitted(streaming: false) emits batch-mode telemetry")
  func recordingCommittedBatchEmission() {
    let recorder = Recorder()
    let context = KernelSessionContext()
    context.config = .testDefault(inputMode: .pushToTalk, triggerSource: .pttHotkey)
    let sink = makeSink(recorder: recorder, context: context)
    sink.emit(.recordingCommitted(isStreaming: false))
    #expect(
      recorder.dictationsInvoked == [
        .init(triggerSource: "ptt_hotkey", inputMode: "pushToTalk", targetApp: nil)
      ])
    // Breadcrumb data dict carries both `backend` and `streaming` keys —
    // mirrors old TP:548-551.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "recording", message: "Recording started",
          dataKeys: ["backend", "streaming"].sorted())
      ])
    #expect(
      recorder.recordingStates == [
        .init(active: true, backend: "parakeet", isStreaming: false)
      ])
    #expect(recorder.audioRoutes == ["fake"])
  }

  @Test(".recordingCommitted(streaming: true) threads the streaming flag (Codex review #11 r2)")
  func recordingCommittedStreamingEmission() {
    let recorder = Recorder()
    let context = KernelSessionContext()
    context.config = .testDefault()
    let sink = makeSink(recorder: recorder, context: context)
    sink.emit(.recordingCommitted(isStreaming: true))
    // Both the breadcrumb data and updateRecordingState must carry the
    // real streaming flag (the bug the earlier draft had — hardcoding false
    // would misreport every streaming session as batch).
    #expect(
      recorder.recordingStates == [
        .init(active: true, backend: "parakeet", isStreaming: true)
      ])
  }

  @Test(".recordingStopped emits the TP:671 breadcrumb + updateRecordingState(false)")
  func recordingStoppedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.recordingStopped)
    // Fixer item #4 restored OLD-TP:671's sample count payload; production now
    // emits the exact `sample_count` key with the recording-stopped breadcrumb.
    #expect(
      recorder.breadcrumbs == [
        .init(stage: "recording", message: "Recording stopped", dataKeys: ["sample_count"])
      ])
    #expect(
      recorder.recordingStates == [
        .init(active: false, backend: nil, isStreaming: nil)
      ])
  }

  @Test(".transcriptionStarted emits the TP:827 'Transcription started' breadcrumb")
  func transcriptionStartedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.transcriptionStarted)
    // Fixer item #4 restored OLD-TP:827-832's mode payload so production can
    // distinguish streaming ASR from batch ASR in the breadcrumb.
    #expect(
      recorder.breadcrumbs == [
        .init(stage: "asr", message: "Transcription started", dataKeys: ["backend", "mode"])
      ])
  }

  @Test(".asrCompleted emits the TP:922 'ASR completed' breadcrumb")
  func asrCompletedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.asrCompleted)
    // Round 2 item #10 restored OLD-TP:922-935's `duration_s`, `char_count`,
    // `mode`, `language` fields. Sink now emits the full sorted key set.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: ["backend", "char_count", "duration_s", "language", "mode"])
      ])
  }

  @Test(".asrCompleted carries the 'incremental' key when WhisperKit set it (Pass 2 r2 #B1)")
  func asrCompletedCarriesIncrementalWhenSet() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en",
      incrementalAccepted: true)
    let sink = makeSink(recorder: recorder, backend: .whisperKit, telemetryState: state)
    sink.emit(.asrCompleted)
    // Parity with OLD `WhisperKitPipeline.swift:1049-1052` — the breadcrumb
    // distinguishes accepted incremental output from batch fallback.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: ["backend", "char_count", "duration_s", "incremental", "language", "mode"])
      ])
  }

  @Test(".asrCompleted omits 'incremental' when nil (Parakeet path, Pass 2 r2 #B1)")
  func asrCompletedOmitsIncrementalWhenNil() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en")
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: ["backend", "char_count", "duration_s", "language", "mode"])
      ])
  }

  @Test(".asrCompleted carries both tail keys when a tail was dropped (#950)")
  func asrCompletedCarriesTailKeysWhenDropped() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en",
      droppedTailMs: 250, tailHadEnergy: true)
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: [
            "backend", "char_count", "duration_s", "language", "mode",
            "tail_dropped_ms", "tail_had_energy",
          ])
      ])
  }

  @Test(".asrCompleted carries tail_dropped_ms=0 but omits tail_had_energy when no tail (#950)")
  func asrCompletedCarriesZeroDropOmitsEnergy() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en",
      droppedTailMs: 0, tailHadEnergy: nil)
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: [
            "backend", "char_count", "duration_s", "language", "mode", "tail_dropped_ms",
          ])
      ])
  }

  @Test(".asrCompleted omits both tail keys when nil (streaming / WhisperKit, #950)")
  func asrCompletedOmitsTailKeysWhenNil() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "streaming", language: "en")
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: ["backend", "char_count", "duration_s", "language", "mode"])
      ])
  }

  @Test(".asrCompleted carries preserve + tuning keys when a tail was recovered (#950)")
  func asrCompletedCarriesPreserveKeys() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en",
      droppedTailMs: 2_500, tailHadEnergy: true,
      usedTailPreservation: true, recoveredTailMs: 2_500, tailVoicedFraction: 0.92)
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: [
            "backend", "char_count", "duration_s", "language", "mode",
            "tail_dropped_ms", "tail_had_energy", "tail_preserved",
            "tail_preserved_ms", "tail_voiced_fraction",
          ])
      ])
  }

  @Test(".asrCompleted carries tail_refused_reason when eligible but not preserved (#950)")
  func asrCompletedCarriesRefusedReason() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.asrCompletedTelemetry = KernelASRCompletedTelemetry(
      durationSeconds: 0.3, charCount: 5, mode: "batch", language: "en",
      droppedTailMs: 1_000, tailHadEnergy: true,
      usedTailPreservation: false, tailVoicedFraction: 0.2,
      tailRefusedReason: "low_voiced_fraction")
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.asrCompleted)
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR completed",
          dataKeys: [
            "backend", "char_count", "duration_s", "language", "mode",
            "tail_dropped_ms", "tail_had_energy", "tail_preserved",
            "tail_refused_reason", "tail_voiced_fraction",
          ])
      ])
  }

  @Test(".pipelineCompleted emits the TP:1032 breadcrumb")
  func pipelineCompletedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.pipelineCompleted)
    // Fixer item #3 restored OLD-TP:1032-1040's rich timing and paste-tier
    // payload, so production emits the full sorted key set again.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "pipeline", message: "Pipeline complete",
          dataKeys: ["asr_s", "backend", "e2e_s", "paste_tier", "polish_s"])
      ])
  }

  // MARK: - Heartpath 5b (#1520): dead-mic recovery forwarding

  @Test(".pipelineCompleted forwards a pending dead-mic recovery outcome")
  func pipelineCompletedForwardsDeadMicRecovery() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    // Arm a watch as if an EARLIER session (5) retired a dead source; the sink's
    // FakeAudioCapture reports currentCaptureSessionID 0, a different (later)
    // session, so this completion resolves it.
    captureTelemetry.armDeadMicWatch(
      DeadMicRetireWatch(shape: "all_zero_from_start", transport: "bluetooth"), sessionID: 5)
    let sink = makeSink(recorder: recorder, captureTelemetry: captureTelemetry)

    sink.emit(.pipelineCompleted)

    #expect(recorder.deadMicRecoveries.count == 1)
    #expect(recorder.deadMicRecoveries.first?.recovered == true)
    #expect(recorder.deadMicRecoveries.first?.resolution == "later_success")
  }

  @Test(".pipelineCompleted does NOT resolve a watch armed by the SAME session (#1520 P1)")
  func sameSessionCompletionDoesNotResolveDeadMicWatch() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    // Arm with the SAME session id the sink's FakeAudioCapture reports (0) — the
    // becameZeroMidCapture take that armed at stop and now self-completes. It
    // must not fake its own recovery.
    captureTelemetry.armDeadMicWatch(
      DeadMicRetireWatch(shape: "became_zero_mid_capture", transport: "bluetooth"), sessionID: 0)
    let sink = makeSink(recorder: recorder, captureTelemetry: captureTelemetry)

    sink.emit(.pipelineCompleted)

    #expect(recorder.deadMicRecoveries.isEmpty)
  }

  @Test(".pipelineCompleted with a degraded save does NOT resolve the dead-mic watch")
  func degradedSaveDoesNotResolveDeadMicWatch() {
    let recorder = Recorder()
    let telemetryState = KernelTelemetryState()
    telemetryState.historySaveFailed = true  // degraded completion, no durable success
    let captureTelemetry = CaptureTelemetryState()
    captureTelemetry.armDeadMicWatch(
      DeadMicRetireWatch(shape: "all_zero_from_start", transport: "bluetooth"), sessionID: 5)
    let sink = makeSink(
      recorder: recorder, telemetryState: telemetryState, captureTelemetry: captureTelemetry)

    sink.emit(.pipelineCompleted)

    // A degraded save is not a durable success, so it must not be counted as a
    // recovery — the watch stays pending.
    #expect(recorder.deadMicRecoveries.isEmpty)
  }

  // #1174 A3 — matcher-set-adversarial: at the `.audioInterrupted` gate both
  // surviving causes are genuine unowned losses, so BOTH `.engineLost` and
  // `.deviceRemoved` capture `.audioCaptureFailed`. (#1543 removed the
  // XPC-connection cause, the only cause that used to be suppressed here;
  // `.maxDurationReached` was deleted by #1408 A3 — the cap routes as a normal
  // stop and can no longer reach this gate.) Every case resets recording state.

  @Test(".audioInterrupted(.engineLost) captures .audioCaptureFailed + resets state")
  func audioInterruptedEngineLostCaptures() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, backend: .whisperKit)
    sink.emit(.audioInterrupted(cause: .engineLost))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "audio")
    #expect(
      recorder.captureErrors.first?.errorDescription.contains("Audio engine interrupted") == true)
    #expect(
      recorder.recordingStates == [
        .init(active: false, backend: nil, isStreaming: nil)
      ])
  }

  @Test("exactly the two unowned-loss causes capture at the .audioInterrupted terminal")
  func audioInterruptedExactlyTheUnownedLossesCapture() {
    // CaseIterable guard — if a future cause is added, this forces an explicit
    // capture/suppress decision rather than silently inheriting either branch.
    var capturingCauses: Set<EngineInterruptionCause> = []
    for cause in EngineInterruptionCause.allCases {
      let recorder = Recorder()
      let sink = makeSink(recorder: recorder)
      sink.emit(.audioInterrupted(cause: cause))
      if !recorder.captureErrors.isEmpty { capturingCauses.insert(cause) }
    }
    // #1408 split `.deviceRemoved` out of `.engineLost`. Both are recording-losing
    // interruptions with no other owner, so BOTH must still capture — otherwise
    // the split would silently halve the "audio capture failed" alert.
    #expect(capturingCauses == [.engineLost, .deviceRemoved])
  }

  // MARK: - #1408 the interruption counter (the salvage denominator)
  //
  // Suppressing `audio_capture_failed` on a salvaged dictation without a
  // replacement would mean we could count what device death COSTS but not how
  // often it HAPPENS. `audio.capture_interrupted` is that denominator: one emit
  // per interrupted session, at whatever terminal it reaches, salvaged or not.
  // It is deliberately not an error — a Bluetooth user walking away is not our
  // defect, and this must never page, email, or file a ticket.

  @Test("a salvaged completion emits the counter with salvage_succeeded, and NO capture error")
  func salvagedCompletionEmitsCounterNotError() {
    let recorder = Recorder()
    let telemetryState = KernelTelemetryState()
    telemetryState.interruptionCause = .engineLost
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)

    sink.emit(.pipelineCompleted)

    #expect(
      recorder.audioCaptureInterruptions == [
        .init(
          cause: "engine_lost", salvageAttempted: true, salvageSucceeded: true,
          terminalState: "completed", backend: "parakeet")
      ])
    #expect(
      recorder.captureErrors.isEmpty,
      "a dictation the user successfully received must not raise a Sentry error")
  }

  @Test("an unsalvaged interruption emits BOTH the counter and the capture error")
  func unsalvagedInterruptionEmitsCounterAndError() {
    let recorder = Recorder()
    let telemetryState = KernelTelemetryState()
    telemetryState.interruptionCause = .engineLost
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)

    sink.emit(.audioInterrupted(cause: .engineLost))

    #expect(
      recorder.audioCaptureInterruptions == [
        .init(
          cause: "engine_lost", salvageAttempted: true, salvageSucceeded: false,
          terminalState: "audio_interrupted", backend: "parakeet")
      ])
    #expect(recorder.captureErrors.count == 1, "the lost dictation is still a real loss")
  }

  // #1543: the former "unsalvageable cause reports salvage_attempted false"
  // test is gone with the XPC-connection cause — in-process every interruption
  // cause is recoverable, so there is no unsalvageable cause to exercise. The
  // `salvage_attempted == true` path is covered by
  // `salvagedCompletionEmitsCounterNotError` above.

  /// A session that was never interrupted must emit nothing. Otherwise the
  /// denominator counts every dictation and the salvage rate reads as ~100%.
  @Test("an ordinary completion emits no interruption counter")
  func ordinaryCompletionEmitsNoCounter() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)

    sink.emit(.pipelineCompleted)

    #expect(recorder.audioCaptureInterruptions.isEmpty)
  }

  /// One emit per interrupted session, whatever terminal it lands on. A per-arm
  /// emit would quietly miss the arm nobody thought of — a user cancelling
  /// mid-salvage, or salvaged audio that decodes to nothing.
  @Test("every terminal an interrupted session can reach emits exactly one counter")
  func everyInterruptedTerminalEmitsExactlyOnce() {
    let terminals: [(KernelLifecycleEvent, String)] = [
      (.pipelineCompleted, "completed"),
      (.audioInterrupted(cause: .engineLost), "audio_interrupted"),
      (.cancelled, "cancelled"),
      (.failed(.asrEmpty), "failed"),
      (.noSpeech(.vadGate), "no_speech"),
      (.discarded(.tooShort), "discarded"),
    ]
    for (event, expectedTerminal) in terminals {
      let recorder = Recorder()
      let telemetryState = KernelTelemetryState()
      telemetryState.interruptionCause = .engineLost
      let sink = makeSink(recorder: recorder, telemetryState: telemetryState)

      sink.emit(event)

      #expect(
        recorder.audioCaptureInterruptions.count == 1,
        "terminal \(expectedTerminal) must emit exactly one counter")
      #expect(recorder.audioCaptureInterruptions.first?.terminalState == expectedTerminal)
    }
  }

  /// Non-terminal events must not emit, even mid-interruption. Otherwise a single
  /// session inflates the counter once per lifecycle event it happens to fire.
  @Test("non-terminal events never emit the interruption counter")
  func nonTerminalEventsNeverEmitCounter() {
    let nonTerminals: [KernelLifecycleEvent] = [
      .pipelineStartingUp, .modelLoading, .recordingCommitted(isStreaming: false),
      .recordingStopped, .transcriptionStarted, .asrCompleted,
    ]
    for event in nonTerminals {
      let recorder = Recorder()
      let telemetryState = KernelTelemetryState()
      telemetryState.interruptionCause = .engineLost
      let sink = makeSink(recorder: recorder, telemetryState: telemetryState)

      sink.emit(event)

      #expect(recorder.audioCaptureInterruptions.isEmpty, "\(event) is not a terminal")
    }
  }

  @Test(".asrInterrupted(wasRecording: true) emits captureError + state(false)")
  func asrInterruptedEmissionFromRecording() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, backend: .whisperKit)
    sink.emit(.asrInterrupted(wasRecording: true))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .xpcServiceError)
    #expect(recorder.captureErrors.first?.stage == "asr")
    // PR-5 Rung 5 Pass 2 #3 — the crash message names the backend again
    // (parity with OLD `WhisperKitPipeline.swift:1217`).
    #expect(
      recorder.captureErrors.first?.errorDescription == "ASR XPC service crashed (WhisperKit)")
    #expect(
      recorder.recordingStates == [
        .init(active: false, backend: nil, isStreaming: nil)
      ])
  }

  @Test(".asrInterrupted(wasRecording: false) threads the flag (matrix #3)")
  func asrInterruptedEmissionFromTranscribing() {
    // Old TP:1145 reported `was_recording == state == .recording` at crash
    // time. The earlier draft hardcoded `true` and would have
    // misclassified mid-transcribe XPC crashes as crashed-while-recording.
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.asrInterrupted(wasRecording: false))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .xpcServiceError)
    // No salvage attempt was recorded on this bare telemetryState — the
    // signal must stay absent, not a false-positive key (#1707).
    #expect(!(recorder.captureErrors.first?.extraKeys.contains("asr_salvage_outcome") ?? true))
  }

  @Test(".asrInterrupted threads asr_salvage_outcome when a salvage was attempted (#1707)")
  func asrInterruptedThreadsSalvageOutcome() {
    let telemetryState = KernelTelemetryState()
    telemetryState.interruptedSalvageSource = .asr
    telemetryState.asrSalvageOutcome = .rewarmFailed
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)
    sink.emit(.asrInterrupted(wasRecording: true))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.extraKeys.contains("asr_salvage_outcome") == true)
  }

  @Test(
    "#1707 Phase 2: .asrInterrupted surfaces asr_retry_outcome when a preempting interruption left a retry at .attempted"
  )
  func asrInterruptedThreadsRetryOutcome() {
    let telemetryState = KernelTelemetryState()
    telemetryState.asrRetryOutcome = .attempted
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)
    sink.emit(.asrInterrupted(wasRecording: true))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.extraKeys.contains("asr_retry_outcome") == true)
  }

  @Test(
    "#1707 Phase 2: .asrInterrupted omits asr_retry_outcome when no Phase-2 retry was ever consulted"
  )
  func asrInterruptedOmitsRetryOutcomeWhenNil() {
    let telemetryState = KernelTelemetryState()
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)
    sink.emit(.asrInterrupted(wasRecording: true))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.extraKeys.contains("asr_retry_outcome") == false)
  }

  @Test(".discarded carries the reason as a data field (PR-1 §B.7.4)")
  func discardedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.discarded(.tooShort))
    #expect(
      recorder.breadcrumbs == [
        .init(stage: "recording", message: "Recording discarded", dataKeys: ["reason"])
      ])
  }

  @Test(".noSpeech(.vadGate) emits the TP:787 breadcrumb (r7)")
  func noSpeechVADGateEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.noSpeech(.vadGate))
    // Round 2 item #15 restored OLD-TP:787-804's `mode`, `peak_audio_level`,
    // `raw_sample_count` fields. Sink now emits the full sorted key set.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "VAD gate: no speech detected, skipping ASR",
          dataKeys: ["backend", "mode", "peak_audio_level", "raw_sample_count"])
      ])
  }

  @Test(".noSpeech(.asrEmptyNoSpeech) emits the TP:902 breadcrumb (r7)")
  func noSpeechASREmptyEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.noSpeech(.asrEmptyNoSpeech))
    // Round 2 enrichment added `mode` to this breadcrumb alongside the
    // existing `backend` field.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "asr", message: "ASR empty (no speech detected)",
          dataKeys: ["backend", "mode"])
      ])
  }

  @Test(
    ".noSpeech(.emptyAfterProcessing) emits the #1358 processing breadcrumb, NOT a heart-path capture",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1358",
      "filler-only capture must end quietly, no Sentry error"
    ))
  func noSpeechEmptyAfterProcessingEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.noSpeech(.emptyAfterProcessing))
    // Breadcrumb only — mirrors the #979 asr-empty downgrade. The old bug fired
    // a `heart_path_finalization` `emitCaptureError`; this must NOT.
    #expect(
      recorder.breadcrumbs == [
        .init(
          stage: "processing", message: "Text processing produced no lexical content",
          dataKeys: ["backend"])
      ])
    #expect(
      recorder.captureErrors.isEmpty,
      "no heart_path_finalization Sentry capture for a quiet no-speech outcome")
  }

  @Test(".cancelled emits NOTHING (PR-1 §B.7.4 only-one-new-event rule)")
  func cancelledEmitsNothing() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.cancelled)
    #expect(recorder.breadcrumbs.isEmpty)
    #expect(recorder.captureErrors.isEmpty)
    #expect(recorder.recordingStates.isEmpty)
    #expect(recorder.audioRoutes.isEmpty)
    #expect(recorder.dictationsInvoked.isEmpty)
  }

  // MARK: - Per-failure-reason coverage (10 positive + 2 r8 negative)

  @Test(".failed(.modelWedged) emits .modelLoadWedged captureError + telemetry")
  func failedModelWedgedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.modelWedged))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .modelLoadWedged)
    #expect(recorder.captureErrors.first?.stage == "asr")
    #expect(recorder.modelLoadWedgedBackends == ["parakeet"])
  }

  @Test(".failed(.modelLoadFailed) emits .modelLoadFailed captureError")
  func failedModelLoadFailedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.modelLoadFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .modelLoadFailed)
    #expect(recorder.captureErrors.first?.stage == "asr")
  }

  /// #1525 PR J-1: `modelLoadError` narrowed to `(any Error & StableSentryErrorIdentity)?`
  /// — a bare `NSError` no longer type-checks here. This fixture preserves the test's
  /// intent (assert the real thrown error's message reaches the captured event, not a
  /// synthesized placeholder) while conforming.
  private struct FixtureModelLoadError: Error, LocalizedError, StableSentryErrorIdentity {
    let sentryFingerprintDescriptor = "WhisperKit#42"
    let sentrySemanticID = "test.fixture_model_load_error"
    var errorDescription: String? { "CoreML model failed to compile" }
  }

  @Test(".failed(.modelLoadFailed) surfaces the real thrown error (Pass 2 #2)")
  func failedModelLoadFailedUsesRealError() {
    let recorder = Recorder()
    let state = KernelTelemetryState()
    state.modelLoadError = FixtureModelLoadError()
    let sink = makeSink(recorder: recorder, telemetryState: state)
    sink.emit(.failed(.modelLoadFailed))
    #expect(recorder.captureErrors.count == 1)
    // PR-5 Rung 5 Pass 2 #2 — the captured error is the real thrown one,
    // NOT a synthesized "Model load failed" placeholder (parity with OLD
    // `WhisperKitPipeline.swift:475-477`).
    #expect(
      recorder.captureErrors.first?.errorDescription == "CoreML model failed to compile")
  }

  /// #1658 PR J-2: pins the defensive nil-property fallback identity. Both current
  /// production adapters enforce ready-or-throw, so a nil `modelLoadError` at
  /// `.loadFailed` is not a demonstrated production path — but the sink's fallback
  /// must keep its shipped identity if one ever reaches it.
  @Test(".failed(.modelLoadFailed) with modelLoadError nil emits the fixed fallback identity")
  func failedModelLoadFailedNilPropertyUsesFallbackIdentity() {
    var capturedIdentity: String?
    var capturedDescriptor: String?
    var captureCount = 0
    let sink = KernelLifecycleTelemetrySink(
      backend: .parakeet,
      audioCapture: FakeAudioCapture(),
      context: KernelSessionContext(),
      captureTelemetry: CaptureTelemetryState(),
      telemetryState: KernelTelemetryState(),
      captureError: { error, _, _, _ in
        captureCount += 1
        capturedIdentity = error.sentrySemanticID
        capturedDescriptor = error.sentryFingerprintDescriptor
      })
    sink.emit(.failed(.modelLoadFailed))
    #expect(captureCount == 1)
    #expect(capturedDescriptor == "EnviousWispr#-10")
    #expect(capturedIdentity == "kernel.model_load_failed")
  }

  @Test(".failed(.captureStartFailed) emits .audioCaptureFailed captureError")
  func failedCaptureStartFailedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.captureStartFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "recording")
  }

  @Test(".failed(.noMicrophoneFound) emits .audioCaptureFailed captureError (#1558)")
  func failedNoMicrophoneFoundEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.noMicrophoneFound))
    // Keeps the audio_capture_failed cluster populated (distinct failureMode)
    // so the held-release drop stays observable post-ship.
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "recording")
  }

  @Test(
    ".failed(.asrEmpty) downgrades to a breadcrumb, emits NO captureError (#979)",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/979", "ASR-empty non-bug"))
  func failedASREmptyDowngradedToBreadcrumb() throws {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.asrEmpty))
    // #979: ASR-empty on non-speech is an expected outcome, not an error — no
    // Sentry error means no auto-filed issue. A context-only breadcrumb instead.
    #expect(recorder.captureErrors.isEmpty)
    let crumb = try #require(recorder.breadcrumbs.first { $0.stage == "asr" })
    #expect(crumb.message == "ASR returned empty text despite speech evidence")
  }

  // Adversarial control: the downgrade is scoped to `.asrEmpty` ONLY — sibling
  // failure terminals still emit a real Sentry error (see
  // failedModelLoadFailedEmission / failedCaptureStartFailedEmission above).
  @Test(".failed(.asrEmpty) downgrade does NOT silence sibling failure terminals")
  func asrEmptyDowngradeIsScoped() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.captureStartFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
  }

  @Test(".failed(.emptyAfterProcessing) emits .heartPathFinalization captureError")
  func failedEmptyAfterProcessingEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.emptyAfterProcessing))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .heartPathFinalization)
    #expect(recorder.captureErrors.first?.stage == "processing")
  }

  // #1167: a clean completion stamps the "transcript durably saved" success
  // marker; a degraded-save completion (history write threw, delivery still
  // ran) must NOT — the marker gates on `telemetryState.historySaveFailed`.
  @Test(".pipelineCompleted records the success marker when the save succeeded")
  func pipelineCompletedRecordsSuccessMarkerOnSave() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    let state = KernelTelemetryState()
    state.historySaveFailed = false
    let sink = makeSink(
      recorder: recorder, telemetryState: state, captureTelemetry: captureTelemetry)
    sink.emit(.pipelineCompleted)
    #expect(captureTelemetry.timeSinceLastSuccessfulRecordingMs() != nil)
  }

  @Test(".pipelineCompleted withholds the success marker on a degraded save (#1167)")
  func pipelineCompletedWithholdsSuccessMarkerOnSaveFailure() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    let state = KernelTelemetryState()
    state.historySaveFailed = true
    let sink = makeSink(
      recorder: recorder, telemetryState: state, captureTelemetry: captureTelemetry)
    sink.emit(.pipelineCompleted)
    #expect(captureTelemetry.timeSinceLastSuccessfulRecordingMs() == nil)
  }

  @Test(".failed(.asrFailed) emits .asrFailed captureError at 'transcription'")
  func failedASRFailedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.asrFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .asrFailed)
    #expect(recorder.captureErrors.first?.stage == "transcription")
  }

  @Test(
    "#1707 Phase 2: .failed(.asrFailed) surfaces asr_retry_outcome when this session exhausted its retry"
  )
  func failedASRFailedThreadsRetryOutcome() {
    let telemetryState = KernelTelemetryState()
    telemetryState.asrRetryOutcome = .retryExhausted
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder, telemetryState: telemetryState)
    sink.emit(.failed(.asrFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.extraKeys.contains("asr_retry_outcome") == true)
  }

  @Test(
    "#1707 Phase 2: .failed(.asrFailed) omits asr_retry_outcome for a pre-capture failure (retry never consulted)"
  )
  func failedASRFailedOmitsRetryOutcomeWhenNil() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.asrFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.extraKeys.contains("asr_retry_outcome") == false)
  }

  @Test(".failed(.asrWedged) routes through the same .asrFailed/transcription path")
  func failedASRWedgedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.asrWedged))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .asrFailed)
    #expect(recorder.captureErrors.first?.stage == "transcription")
  }

  /// Row 8 (#1525 PR J-1): `transcriptionFailureError` stays `(any Error)?` because
  /// Parakeet's raw-vendor passthrough can be a non-conforming, non-CoreML error too.
  /// A miss must still fire exactly one event under the fixed `.unexpectedTranscriptionFailure`
  /// identity — never silently drop the alert.
  @Test(
    ".failed(.asrFailed) with a non-CoreML raw transcription error normalizes to .unexpectedTranscriptionFailure"
  )
  func failedASRFailedNonCoreMLNormalizesToUnexpected() {
    struct OpaqueTranscriptionError: Error {}
    var capturedIdentity: String?
    var captureCount = 0
    let state = KernelTelemetryState()
    state.transcriptionFailureError = OpaqueTranscriptionError()
    let sink = KernelLifecycleTelemetrySink(
      backend: .parakeet,
      audioCapture: FakeAudioCapture(),
      context: KernelSessionContext(),
      captureTelemetry: CaptureTelemetryState(),
      telemetryState: state,
      captureError: { error, _, _, _ in
        captureCount += 1
        capturedIdentity = error.sentrySemanticID
      })
    sink.emit(.failed(.asrFailed))
    #expect(captureCount == 1)
    #expect(capturedIdentity == "boundary.unexpected_transcription_failure")
  }

  @Test(".failed(.permissionDenied) emits .audioCaptureFailed captureError")
  func failedPermissionDeniedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.permissionDenied))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "recording")
  }

  @Test(".failed(.prepareFailed) emits .audioCaptureFailed captureError")
  func failedPrepareFailedEmission() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.prepareFailed))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "recording")
  }

  // MARK: - r8 NEGATIVE tests (skip-not-share)
  //
  // The rich `HeartPathTelemetryEmitter` owns these two terminals
  // (`stallFired(ctx:)` / `noAudioCaptured(ctx:)`). The lifecycle sink MUST
  // NOT emit a duplicate `captureError(.audioCaptureFailed)` for them —
  // otherwise PR-4b.4 cutover doubles Sentry counts for every stall and every
  // no-audio incident. The observer still routes the lifecycle event INTO
  // the sink (proved by `KernelHeartPathTelemetryObserverTests`); the sink
  // intentionally produces zero side-effect.

  @Test(".failed(.captureStalled) emits NOTHING — rich emitter owns this terminal (r8)")
  func failedCaptureStalledEmitsNothing() {
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.captureStalled))
    #expect(recorder.captureErrors.isEmpty)
    #expect(recorder.breadcrumbs.isEmpty)
    #expect(recorder.recordingStates.isEmpty)
    #expect(recorder.audioRoutes.isEmpty)
    #expect(recorder.dictationsInvoked.isEmpty)
    #expect(recorder.modelLoadWedgedBackends.isEmpty)
  }

  @Test(
    ".failed(.noAudioCaptured) DOES emit captureError — no other path wires it (Codex review #11 r3)"
  )
  func failedNoAudioCapturedEmitsCaptureError() {
    // The earlier r8 patch tried to skip this case symmetrically with
    // `.captureStalled`, but grep verified asymmetry: the rich
    // `HeartPathTelemetryEmitter.noAudioCaptured(ctx:)` is called ONLY from
    // Parakeet pipeline / KernelDictationDriver — both bypassed by the
    // kernel-driver cutover. The lifecycle sink IS the only no-audio
    // emitter in the new factory stack; skipping here would drop the
    // signal entirely.
    let recorder = Recorder()
    let sink = makeSink(recorder: recorder)
    sink.emit(.failed(.noAudioCaptured))
    #expect(recorder.captureErrors.count == 1)
    #expect(recorder.captureErrors.first?.category == .audioCaptureFailed)
    #expect(recorder.captureErrors.first?.stage == "recording")
  }

  @Test(
    ".failed(.noAudioCaptured) routes through the rich sink when wired (Div 6)"
  )
  func failedNoAudioCapturedRoutesRichSinkWhenWired() {
    // Div 6 of seam audit (TP:273-291): when the factory wires
    // `noAudioCapturedRich` to the emitter, the sink builds the full
    // NoAudioContext and dispatches there instead of falling back to
    // the basic captureError. The captureError recorder must stay
    // empty in this path (the rich sink owns the dedup contract +
    // Sentry emission).
    let recorder = Recorder()
    var richCalls: [NoAudioContext] = []
    let sink = KernelLifecycleTelemetrySink(
      backend: .parakeet,
      audioCapture: FakeAudioCapture(),
      context: KernelSessionContext(),
      captureTelemetry: CaptureTelemetryState(),
      captureError: { error, category, stage, extra in
        recorder.captureErrors.append(
          Recorder.CaptureErrorCall(
            category: category, stage: stage, errorDescription: error.localizedDescription,
            extraKeys: (extra?.keys.map { $0 } ?? []).sorted()))
      },
      noAudioCapturedRich: { ctx in richCalls.append(ctx) })
    sink.emit(.failed(.noAudioCaptured))
    #expect(recorder.captureErrors.isEmpty)
    #expect(richCalls.count == 1)
    // The ctx must carry the rich payload that the basic-error path lost.
    #expect(richCalls.first?.route == "fake")
    #expect(richCalls.first?.captureSourceType != "")
  }

  // MARK: - Backend-parametrization regression (r6)

  @Test("sink emits backend.rawValue, not a hardcoded 'parakeet' string")
  func backendParametrizationIsRespected() {
    let recorder = Recorder()
    let context = KernelSessionContext()
    context.config = .testDefault()
    let sink = makeSink(recorder: recorder, backend: .whisperKit, context: context)
    sink.emit(.recordingCommitted(isStreaming: false))
    // updateRecordingState argument must come from the injected backend, not
    // a hardcoded literal.
    #expect(recorder.recordingStates.first?.backend == "whisperKit")
  }
}
