import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
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
// control flow — reaches the observer through the kernel's
// `captureStallTelemetry` fan-out seam (PR-4 §3.9).
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
  /// the recording-started breadcrumb.
  case recordingCommitted
  /// The session entered `transcribing` — the `asr` "Transcription started"
  /// breadcrumb.
  case transcriptionStarted
  /// The session reached `completed` — the `pipeline` "Pipeline complete"
  /// breadcrumb.
  case pipelineCompleted
  /// The session reached a `failed` terminal — a per-reason `captureError`.
  /// `model.load_wedged` is the `.modelWedged` case.
  case failed(RecordingFailureReason)
  /// The session reached `audioInterrupted` — a microphone-disconnect event.
  case audioInterrupted
  /// The session reached `asrInterrupted` — the `captureError(xpcServiceError)`.
  case asrInterrupted
  /// The session reached `discarded` — PR-1 §B.7.4, carrying the abort reason.
  case discarded(DiscardReason)
  /// The session reached `noSpeech` — the VAD no-speech outcome.
  case noSpeech
  /// The session reached `cancelled` — a user-cancelled recording.
  case cancelled
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
    emitter: HeartPathTelemetryEmitter = HeartPathTelemetryEmitter(
      backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
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

  /// Capture-stall telemetry. Reached through the kernel's `captureStallTelemetry`
  /// fan-out seam (PR-4 §3.9) and through the driver's `HeartPathTelemetryTarget`
  /// conformance. `HeartPathTelemetryEmitter` dedups per session, so a
  /// double-call is harmless.
  func handleCaptureStall(_ ctx: CaptureStallContext) {
    emitter.stallFired(ctx: ctx, isActivelyCapturing: audioCapture.isActivelyCapturing)
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
  private func handleStateChange() {
    let state = kernel.state
    guard state != lastObservedState else { return }
    lastObservedState = state
    guard let event = Self.lifecycleEvent(for: state, discardReason: kernel.discardReason)
    else { return }
    emitLifecycleEvent(event)
  }

  /// Map a kernel state to its lifecycle event. States with no §B.7 event
  /// (`idle` / `preparing` / `warmingUp` / `stopping` / `finalizing`) map to
  /// `nil` — observing raw state still guarantees no terminal is missed.
  static func lifecycleEvent(
    for state: RecordingSessionState, discardReason: DiscardReason?
  ) -> KernelLifecycleEvent? {
    switch state {
    case .recording:
      return .recordingCommitted
    case .transcribing:
      return .transcriptionStarted
    case .completed:
      return .pipelineCompleted
    case .failed(let reason):
      return .failed(reason)
    case .audioInterrupted:
      return .audioInterrupted
    case .asrInterrupted:
      return .asrInterrupted
    case .discarded:
      // The reason is a sibling observable set before the `→ discarded`
      // transition (PR-4 §3.8a); default defensively if somehow absent.
      return .discarded(discardReason ?? .releasedBeforeRecording)
    case .noSpeech:
      return .noSpeech
    case .cancelled:
      return .cancelled
    case .idle, .preparing, .warmingUp, .stopping, .finalizing:
      return nil
    }
  }
}
