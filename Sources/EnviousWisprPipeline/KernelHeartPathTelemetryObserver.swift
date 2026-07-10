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
// missed. PR-4b.1: the observer no longer claims the shared
// `AudioCaptureInterface` callbacks (`onCaptureSessionInterruption`,
// `onXPCReplyFailed`). Those are single-owner; the App-side routers stay as
// sole subscribers. The driver's `HeartPathTelemetryTarget` conformance
// already forwards into the observer's `handleCaptureSessionInterruption(_:)`
// and `handleXPCReplyFailed(_:)` methods via `WedgeRecoveryRouter`'s
// `resolveActiveTelemetryTarget()` (PR-4b.4 wires the App router's Parakeet
// branch). The capture-stall signal — which the kernel DOES consume for
// control flow — reaches the observer the same way, through the driver's
// `HeartPathTelemetryTarget` conformance (PR-4 §3.9).
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

  /// The last kernel state the observer emitted for — so a re-armed
  /// observation that fires without a state change emits nothing.
  private var lastObservedState: RecordingSessionState

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

  func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext) {
    emitter.xpcReplyFailed(ctx: ctx)
  }

  func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext) {
    emitter.captureSessionInterrupted(ctx: ctx)
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
      _ = kernel.state
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleStateChange()
        self.observeKernelState()
      }
    }
  }

  /// Emit the lifecycle event for the current kernel state, if it changed.
  /// Reads kernel sibling observables (`discardReason`, `didLoadModelThisSession`,
  /// `lastNoSpeechSource`, `finalizingSubStatus`) at mapping time so the event
  /// carries the right associated values without racing the state transition
  /// (PR-4b.2 §3.6 OQ-3, r7).
  private func handleStateChange() {
    let state = kernel.state
    guard state != lastObservedState else { return }
    let priorState = lastObservedState
    lastObservedState = state
    guard
      let event = Self.lifecycleEvent(
        for: state,
        priorState: priorState,
        discardReason: kernel.discardReason,
        didLoadModelThisSession: kernel.didLoadModelThisSession,
        lastNoSpeechSource: kernel.lastNoSpeechSource,
        lastAudioInterruptionCause: kernel.lastAudioInterruptionCause,
        isStreamingSession: kernel.isStreamingSession
      )
    else { return }
    emitLifecycleEvent(event)
  }

  /// Map a kernel state (plus the sibling observables that the event payloads
  /// depend on) to its lifecycle event. States with no §B.7 event (`idle` /
  /// `preparing`) map to `nil` — observing raw state still guarantees no
  /// terminal is missed.
  ///
  /// - parameter priorState: the state we just transitioned out of. Used to
  ///   gate `.finalizing` → `.asrCompleted` to the post-transcribing branch
  ///   only.
  /// - parameter didLoadModelThisSession: kernel-stamped truthy when the
  ///   adapter was NOT `.ready` at the warm-up gate (PR-4b.2 §3.6).
  /// - parameter lastNoSpeechSource: kernel-stamped at the two distinct
  ///   `.noSpeech` forward-path sites (VAD gate vs ASR-empty no-speech).
  /// - parameter isStreamingSession: kernel-stamped at `beginSession` —
  ///   `config.useStreamingASR && adapter.capabilities.supportsStreaming`.
  ///   Threaded through `.recordingCommitted(isStreaming:)` so the sink
  ///   emits the same flag old TP did (Codex review #11 r2).
  static func lifecycleEvent(
    for state: RecordingSessionState,
    priorState: RecordingSessionState,
    discardReason: DiscardReason?,
    didLoadModelThisSession: Bool,
    lastNoSpeechSource: NoSpeechSource?,
    lastAudioInterruptionCause: EngineInterruptionCause?,
    isStreamingSession: Bool
  ) -> KernelLifecycleEvent? {
    switch state {
    case .recording:
      return .recordingCommitted(isStreaming: isStreamingSession)
    case .transcribing:
      return .transcriptionStarted
    case .completed:
      return .pipelineCompleted
    case .failed(let reason):
      return .failed(reason)
    case .audioInterrupted:
      // The cause is a sibling observable stamped by `externalEngineInterrupted`
      // before the `→ .audioInterrupted` transition (the terminal's only path),
      // mirroring `discardReason` / `lastNoSpeechSource`. Default defensively to
      // `.engineLost` (capture) if somehow absent — a lost recording at this
      // terminal with no cause is still an unowned loss.
      return .audioInterrupted(cause: lastAudioInterruptionCause ?? .engineLost)
    case .asrInterrupted:
      // Bridge matrix #3 — old TP:1145 reported `was_recording == state == .recording`
      // at crash time. The kernel reaches `.asrInterrupted` from either
      // `.recording` (via `deliverRecordingExit(.asrInterruption)`) or
      // `.transcribing` (via `finishTerminal(.asrInterrupted)`); the prior
      // state distinguishes them.
      return .asrInterrupted(wasRecording: priorState == .recording)
    case .discarded:
      // The reason is a sibling observable set before the `→ discarded`
      // transition (PR-4 §3.8a); default defensively if somehow absent.
      return .discarded(discardReason ?? .releasedBeforeRecording)
    case .noSpeech:
      // Source stamped at the kernel transition site (PR-4b.2 §3.6 r7).
      // Default defensively to `.vadGate` if somehow absent — both sites
      // stamp, so an absent source means the kernel reached `.noSpeech`
      // via a path the inventory did not anticipate; better to emit a
      // breadcrumb that names "no speech" than to silently drop the event.
      return .noSpeech(lastNoSpeechSource ?? .vadGate)
    case .cancelled:
      return .cancelled
    case .warmingUp:
      // PR-4b.2 §3.6 — only fire `.modelLoading` if the adapter was not
      // already loaded (parity with old TP:363 conditional).
      return didLoadModelThisSession ? .modelLoading : nil
    case .stopping:
      return nil
    case .finalizing:
      // PR-4b.2 §3.6 — only fire `.asrCompleted` on the post-transcribing
      // path. Old TP:922 was inside the transcript branch; the kernel only
      // reaches `.finalizing` from `.transcribing` via `runFinalizing(asrText:)`
      // (`RecordingSessionKernel.swift:836` — the `.transcript(...)` arm of
      // the finalize switch). The `.empty` and no-speech arms jump straight
      // to terminal, so `priorState == .transcribing` IS the structural
      // signal that ASR returned non-empty text. (Codex review #11:
      // `kernel.deliveredTranscript` is set INSIDE `runFinalizing` AFTER the
      // `→ .finalizing` transition, so reading it at mapping time would
      // always be nil and the breadcrumb would never fire.)
      guard priorState == .transcribing else { return nil }
      return .asrCompleted
    case .preparing:
      // PR-5 Rung 5 Pass 2 #1 — startup breadcrumb. `.preparing` is the
      // single per-session entry point from `.idle` / terminal; the
      // observer fires on state-change only so this event lands exactly
      // once per session start.
      return .pipelineStartingUp
    case .idle:
      return nil
    }
  }
}
