import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// MARK: - KernelHeartPathTelemetryObserver (epic #827, PR-4 §3.9)
//
// Heart-path telemetry for the kernel path. It is a dedicated observer, NOT
// folded into `KernelDictationDriver` (council placement challenge accepted):
// the driver owns App-protocol translation; telemetry is a separate concern,
// and folding it in would tie telemetry to UI-derived state — distinct
// terminals (`completed` / `cancelled` / `discarded` / `noSpeech`) all map to
// the `.hidden` overlay, so a UI-keyed observer would miss them.
//
// This observer watches RAW `kernel.state` transitions, so no terminal is
// missed. The capture-stall signal — which the kernel DOES consume for control
// flow — reaches the observer through the driver's `HeartPathTelemetryTarget`
// conformance via `WedgeRecoveryRouter`'s `resolveActiveTelemetryTarget()`
// (PR-4 §3.9).
//
// PR-4a ships this production-unwired: no App-layer caller constructs it. The
// lifecycle-event sink is injected — PR-4b supplies the production sink
// (Sentry breadcrumbs / PostHog) and the §11.2 event matrix verifies every
// PR-1 §B.7 event empirically.

/// A heart-path lifecycle event derived from a raw kernel state transition
/// (PR-1 §B.7). The observer produces these; the injected sink renders them
/// to the telemetry backends.
enum KernelLifecycleEvent: Equatable, Sendable {
  /// The session committed to `recording` — PR-1 §B.7 `dictation.invoked` +
  /// the recording-started breadcrumb. Carries the streaming-mode flag the
  /// kernel decided at `beginSession` time so the sink emits the same
  /// `isStreaming` value old Parakeet pipeline did
  /// (Codex review #11 r2).
  case recordingCommitted(isStreaming: Bool)
  /// The session entered `transcribing` — the `asr` "Transcription started"
  /// breadcrumb.
  case transcriptionStarted
  /// The session reached `completed` — the `pipeline` "Pipeline complete"
  /// breadcrumb.
  case pipelineCompleted
  /// The session reached a `failed` terminal — a per-reason `captureError`.
  /// `model.load_wedged` is the `.modelWedged` case.
  case failed(RecordingFailureReason)
  /// The session reached `audioInterrupted` — a microphone / audio-engine
  /// interruption mid-recording. Carries the `EngineInterruptionCause` so the
  /// sink captures the lost dictation for `.engineLost` only, suppressing the
  /// three already-owned causes (issue #1174 A3).
  case audioInterrupted(cause: EngineInterruptionCause)
  /// The session reached `asrInterrupted` — the `captureError(xpcServiceError)`.
  /// Carries the `was_recording` flag the old TP:1145 captureError extra
  /// carried: `true` when entered from `.recording`, `false` when entered
  /// from `.transcribing`. Bridge matrix #3.
  case asrInterrupted(wasRecording: Bool)
  /// The session reached `discarded` — PR-1 §B.7.4, carrying the abort reason.
  case discarded(DiscardReason)
  /// The session reached `noSpeech`. The associated value names which path led
  /// here so the sink can emit the byte-correct breadcrumb (PR-1 §B.7.2 — old
  /// the old Parakeet pipeline vs `:902`).
  case noSpeech(NoSpeechSource)
  /// The session reached `cancelled` — a user-cancelled recording.
  case cancelled

  // MARK: PR-4b.2 r6 additions

  /// The session entered `.warmingUp` AND the ASR model was not already loaded
  /// (i.e., a real model-load is about to start). Mirrors the old
  /// the old Parakeet pipeline "Model loading" breadcrumb. NOT fired
  /// when the model was warm at start (parity — old code only emits when it
  /// enters the load branch at `:363`). Gated by the kernel's
  /// `didLoadModelThisSession` sibling observable.
  case modelLoading

  /// Recording stopped. Production emits this through
  /// `KernelLifecycleTelemetrySink.emitRecordingStopped(sampleCount:)` after
  /// `stopCapture()` returns, because old TP payload parity needs the final
  /// sample count.
  case recordingStopped

  /// The session entered `.finalizing` AFTER a successful transcribe (ASR
  /// returned non-empty text). Mirrors the old Parakeet pipeline
  /// "ASR completed" breadcrumb. NOT fired on the `.finalizing` path that came
  /// from a no-speech VAD gate or asrEmpty — those emit `.noSpeech(source:)` /
  /// `.failed(.asrEmpty)` instead, matching old code which never emits the
  /// "ASR completed" breadcrumb on those paths.
  case asrCompleted

  /// The session entered `.preparing` — the first observable transition from
  /// `.idle` / terminal at the head of every session. Mirrors the OLD
  /// `WhisperKitPipeline.swift:438` "Pipeline starting up" breadcrumb (PR-5
  /// Rung 5 Pass 2 #1). Warm-path sessions otherwise jumped straight to the
  /// `.recordingCommitted` event with no signal that the kernel even saw the
  /// trigger.
  case pipelineStartingUp
}

/// Observes raw `RecordingSessionKernel` state and emits the PR-1 §B.7
/// heart-path telemetry events.
@MainActor
final class KernelHeartPathTelemetryObserver {

  private let kernel: RecordingSessionKernel
  private let audioCapture: any AudioCaptureInterface
  private let emitter: HeartPathTelemetryEmitter
  private let emitLifecycleEvent: @MainActor (KernelLifecycleEvent) -> Void

  /// The last observation tuple the observer emitted for (#1548 D1). Two
  /// projections became invisible to a state-only watcher: an idle→idle
  /// `recordingOutcome` reset (conclusion lands on `.idle`, already-idle) and a
  /// `deliveringPhase`-only change (same `.delivering` state). So the observer
  /// tracks `(state, recordingOutcome, didLoadModelThisSession, deliveringPhase)`
  /// and emits on the DELTA (§3.7 / plan §200).
  private var lastObservedState: RecordingSessionState
  private var lastObservedOutcome: RecordingOutcome?
  private var lastObservedDidLoadModel: Bool
  private var lastObservedDeliveringPhase: DeliveringPhase

  init(
    kernel: RecordingSessionKernel,
    audioCapture: any AudioCaptureInterface,
    emitter: HeartPathTelemetryEmitter,
    emitLifecycleEvent: @escaping @MainActor (KernelLifecycleEvent) -> Void
  ) {
    self.kernel = kernel
    self.audioCapture = audioCapture
    self.emitter = emitter
    self.emitLifecycleEvent = emitLifecycleEvent
    self.lastObservedState = kernel.state
    self.lastObservedOutcome = kernel.recordingOutcome
    self.lastObservedDidLoadModel = kernel.didLoadModelThisSession
    self.lastObservedDeliveringPhase = kernel.deliveringPhase
  }

  // MARK: Capture-diagnostic callbacks (the kernel does not consume these)
  //
  // These three method names match `HeartPathTelemetryTarget`; the
  // App-facing `KernelDictationDriver` conforms to that protocol and forwards
  // its three methods here. The observer is the single telemetry brain.

  /// Capture-stall telemetry. Reached through the driver's
  /// `HeartPathTelemetryTarget` conformance (PR-4 §3.9).
  /// `HeartPathTelemetryEmitter` dedups per session, so a double-call is harmless.
  ///
  /// #1434: the stall fires BEFORE `stopCapture()`, so no stop metadata exists
  /// yet — the SOURCE stamped rate/divergence into the context; the kernel's
  /// stabilization observations (private telemetry state) are merged here via
  /// the kernel's own accessor. The observer stays a forwarder otherwise.
  func handleCaptureStall(_ ctx: CaptureStallContext) {
    let stabilization = kernel.captureStabilizationTelemetry
    let enriched = ctx.enrichedWithStabilizationFlags(
      formatStabilized: stabilization.formatStabilized,
      captureRebuiltForFormat: stabilization.rebuiltForFormat
    )
    emitter.stallFired(ctx: enriched, isActivelyCapturing: audioCapture.isActivelyCapturing)
  }

  // MARK: Raw-state observation

  /// Arm `withObservationTracking` on `kernel.state`. The `onChange` closure
  /// runs synchronously on whatever context mutated the property; it hops to
  /// `@MainActor` before re-reading state and re-arming (PR-4 §3.7, Gemini
  /// concurrency premise — the explicit hop is the safe pattern even though
  /// the kernel is `@MainActor`). PR-4b.1 widened access from `private` to
  /// internal so the factory (PR-4b.2) can call it directly post-construction
  /// in place of the deleted `start()` method.
  func observeKernelState() {
    withObservationTracking {
      // Track the full lifecycle tuple (#1548 D1) — not just `state`.
      _ = kernel.state
      _ = kernel.recordingOutcome
      _ = kernel.didLoadModelThisSession
      _ = kernel.deliveringPhase
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleObservationChange()
        self.observeKernelState()
      }
    }
  }

  /// Emit every lifecycle event implied by the observation DELTA since the last
  /// fire (#1548 D1). The ending category now lives on `recordingOutcome` (not
  /// an FSM terminal state), and the transcribe/finalize boundary is a
  /// `deliveringPhase` change with no state transition, so both are detected by
  /// comparing against the last-observed tuple. `withObservationTracking` is NOT
  /// a lossless queue, so one fire may carry MORE THAN ONE tuple change; the
  /// pure `deltaEvents` returns every applicable event this fire.
  private func handleObservationChange() {
    let state = kernel.state
    let outcome = kernel.recordingOutcome
    let didLoadModel = kernel.didLoadModelThisSession
    let phase = kernel.deliveringPhase

    let prevState = lastObservedState
    let prevOutcome = lastObservedOutcome
    let prevDidLoadModel = lastObservedDidLoadModel
    let prevPhase = lastObservedDeliveringPhase

    // Update the snapshot first so a re-entrant fire sees the latest tuple.
    lastObservedState = state
    lastObservedOutcome = outcome
    lastObservedDidLoadModel = didLoadModel
    lastObservedDeliveringPhase = phase

    let events = Self.deltaEvents(
      prevState: prevState,
      state: state,
      prevOutcome: prevOutcome,
      outcome: outcome,
      prevDidLoadModel: prevDidLoadModel,
      didLoadModel: didLoadModel,
      prevPhase: prevPhase,
      phase: phase,
      isStreaming: kernel.isStreamingSession)

    for event in events {
      emitLifecycleEvent(event)
    }
  }

  /// Pure interpretation of one observed lifecycle-tuple delta (#1548 D1).
  /// Returns EVERY applicable event in lifecycle order, because two tracked
  /// mutations can coalesce into one `withObservationTracking` fire (e.g.
  /// idle→arming then didLoadModel=true; or entry into Delivering then the
  /// phase advance) — never just the first-by-priority (impl-design consult,
  /// Dec 3). Extracted as a functional core so every gate + the coalesced case
  /// unit-tests directly without driving the observer.
  static func deltaEvents(
    prevState: RecordingSessionState,
    state: RecordingSessionState,
    prevOutcome: RecordingOutcome?,
    outcome: RecordingOutcome?,
    prevDidLoadModel: Bool,
    didLoadModel: Bool,
    prevPhase: DeliveringPhase,
    phase: DeliveringPhase,
    isStreaming: Bool
  ) -> [KernelLifecycleEvent] {
    var events: [KernelLifecycleEvent] = []

    if prevState == .idle, state == .arming {
      events.append(.pipelineStartingUp)
    }

    if !prevDidLoadModel, didLoadModel,
      prevState == .arming || state == .arming
    {
      // A real model-load began while Arming (was `→ .warmingUp`, same gate).
      events.append(.modelLoading)
    }

    if prevState == .arming, state == .live {
      // Capture established — the recording pill shows (was `→ .recording`;
      // #1548 D2 removed the first-buffer gate, so this fires sequentially the
      // moment capture is established, not on a first buffer).
      events.append(.recordingCommitted(isStreaming: isStreaming))
    }

    if prevState == .stopping, state == .delivering {
      // ASR begins (was `→ .transcribing`).
      events.append(.transcriptionStarted)
    }

    if prevPhase == .transcribing,
      prevState == .delivering || state == .delivering,
      case .finalizing = phase
    {
      // ASR returned non-empty text (was `.transcribing → .finalizing`).
      events.append(.asrCompleted)
    }

    if prevOutcome == nil, let outcome,
      let event = terminalEvent(for: outcome, isStreaming: isStreaming)
    {
      // Conclusion — the ending event (the paired `→ .idle` has none).
      events.append(event)
    }

    return events
  }

  /// Map a concluded session's `RecordingOutcome` to its terminal lifecycle
  /// event (#1548 D1). `.noTransport` projects to the existing
  /// `.failed(.noAudioCaptured)` telemetry (locked projection, plan §4 / §7) —
  /// no new Sentry/PostHog identity.
  static func terminalEvent(
    for outcome: RecordingOutcome,
    isStreaming: Bool
  ) -> KernelLifecycleEvent? {
    switch outcome {
    case .completed:
      return .pipelineCompleted
    case .failed(let reason):
      return .failed(reason)
    case .cancelled:
      return .cancelled
    case .discarded(let reason):
      return .discarded(reason)
    case .noSpeech(let source):
      return .noSpeech(source)
    case .audioInterrupted(let cause):
      // Default defensively to `.engineLost` if the cause was not stamped — a
      // lost recording with no cause is still an unowned loss (#1174 A3).
      return .audioInterrupted(cause: cause ?? .engineLost)
    case .asrInterrupted(let wasRecording):
      return .asrInterrupted(wasRecording: wasRecording)
    case .noTransport:
      return .failed(.noAudioCaptured)
    }
  }
}
