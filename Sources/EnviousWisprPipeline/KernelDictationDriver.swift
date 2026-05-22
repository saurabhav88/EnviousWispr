import EnviousWisprCore
import Foundation

// MARK: - KernelDictationDriver (epic #827, PR-4 §3.1)
//
// Adapts `RecordingSessionKernel` to the `DictationPipeline` surface the App
// layer consumes. The App calls the active engine through `DictationPipeline`
// and reads `state` / `overlayIntent` / `currentTranscript` / `lastPolishError`
// / the four limb-step accessors / `onStateChange` / DEBUG `forceCancelNow()`
// off the concrete pipeline type. The kernel exposes none of that — it has
// synchronous triggers and its own `RecordingSessionState` vocabulary.
//
// The driver translates: `PipelineEvent` -> kernel triggers, `RecordingSessionState`
// -> `PipelineState` / `OverlayIntent`. It is a permanent translation layer
// until PR-9 deletes `DictationPipeline`; it carries real behavior (event
// translation, state mapping, the limb-step home, the external-error surface)
// and is NOT a forwarding shim — the old `TranscriptionPipeline` path is gone.
//
// PR-4a ships this production-unwired: no App-layer caller constructs it.
// PR-4b re-points the 13 App files at this type.

/// The four text-processing limb steps the App configures and the kernel's
/// `processText` closure runs. Created once, shared by the driver (which
/// exposes the accessors) and `KernelFinalizationWiring` (whose `processText`
/// consumes them).
@MainActor
struct LimbSteps {
  let wordCorrection: WordCorrectionStep
  let fillerRemoval: FillerRemovalStep
  let emojiFormatter: EmojiFormatterStep
  let llmPolish: LLMPolishStep
}

/// Wraps `RecordingSessionKernel` as a `DictationPipeline` for the App layer.
@MainActor
@Observable
final class KernelDictationDriver: DictationPipeline, HeartPathTelemetryTarget {

  private let kernel: RecordingSessionKernel
  private let observer: KernelHeartPathTelemetryObserver
  private let outcome: KernelFinalizationOutcome
  private let steps: LimbSteps

  /// The per-session context the wiring's closures read (PR-4 §3.3 — "captured
  /// by the driver and threaded into the wiring"). PR-4a holds it; PR-4b's
  /// `handle(.toggleRecording)` is the writer — it records the frozen config
  /// and the frontmost app / focused element at recording start.
  private let context: KernelSessionContext

  /// External-error surface (PR-4 §3.7). `kernel.cancel()` alone maps to a
  /// `.hidden` overlay, so the driver owns the error state pushed in from
  /// outside (`setExternalError`). Cleared on the next start / reset.
  private var lastExternalError: String?

  /// Fired by the kernel-state observer whenever the mapped `PipelineState`
  /// changes. The App's `DictationLifecycleCoordinator` is the consumer.
  @ObservationIgnored
  var onStateChange: ((PipelineState) -> Void)?

  /// The last mapped state `onStateChange` fired for — so a re-armed
  /// observation that fires without a mapped-state change stays quiet.
  @ObservationIgnored
  private var lastFiredState: PipelineState

  init(
    kernel: RecordingSessionKernel,
    observer: KernelHeartPathTelemetryObserver,
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    steps: LimbSteps
  ) {
    self.kernel = kernel
    self.observer = observer
    self.outcome = outcome
    self.context = context
    self.steps = steps
    self.lastFiredState = Self.pipelineState(for: kernel.state, externalError: nil)
  }

  /// Begin observing the kernel for `onStateChange` fan-out.
  func start() {
    observeKernelState()
  }

  // MARK: Limb-step accessors (read by `PipelineSettingsSync` + custom-words)

  var wordCorrection: WordCorrectionStep { steps.wordCorrection }
  var fillerRemoval: FillerRemovalStep { steps.fillerRemoval }
  var emojiFormatter: EmojiFormatterStep { steps.emojiFormatter }
  var llmPolish: LLMPolishStep { steps.llmPolish }

  // MARK: Caller-visible signals

  /// The kernel's `RecordingSessionState` mapped to the legacy `PipelineState`.
  var state: PipelineState {
    Self.pipelineState(for: kernel.state, externalError: lastExternalError)
  }

  /// The transcript the `store` closure built for the last completed session.
  var currentTranscript: Transcript? { outcome.transcript }

  /// The polish error from the last session, or `nil`.
  var lastPolishError: String? { outcome.polishError }

  // MARK: DictationPipeline

  var overlayIntent: OverlayIntent {
    if let lastExternalError {
      return .error(message: lastExternalError)
    }
    switch kernel.state {
    case .idle, .completed, .cancelled, .discarded, .noSpeech:
      return .hidden
    case .preparing, .warmingUp:
      return .processing(label: "Preparing dictation...")
    case .recording:
      // The real level is supplied by `AudioCaptureManager` downstream — the
      // pipeline returns 0 here, exactly as `TranscriptionPipeline` did.
      return .recording(audioLevel: 0)
    case .stopping, .transcribing:
      return .processing(label: "Transcribing...")
    case .finalizing:
      switch kernel.finalizingSubStatus {
      case .transcribing:
        return .processing(label: "Transcribing...")
      case .polishing:
        return .processing(label: "Polishing...")
      }
    case .failed(let reason):
      return .error(message: Self.failureMessage(reason))
    case .audioInterrupted:
      return .interruption(message: InterruptionMessages.micDisconnected)
    case .asrInterrupted:
      return .error(message: Self.asrInterruptedMessage)
    }
  }

  func handle(event: PipelineEvent) async throws {
    switch event {
    case .preWarm:
      kernel.preWarm()
    case .toggleRecording(let config):
      switch kernel.state {
      case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
        .audioInterrupted, .asrInterrupted:
        // Start: clear the prior session's surfaces, then mint a new session.
        lastExternalError = nil
        outcome.transcript = nil
        outcome.polishError = nil
        kernel.start(config: config)
      case .recording:
        kernel.requestStop()
      case .preparing, .warmingUp, .stopping, .transcribing, .finalizing:
        // Mid-session — don't interrupt processing (PR-1 §B.1.2).
        break
      }
    case .requestStop:
      kernel.requestStop()
    case .cancelRecording:
      kernel.cancel()
    case .reset:
      lastExternalError = nil
      kernel.reset()
    }
  }

  /// Dumb external-error sink (PR-4 §3.7). Cancels the kernel session and
  /// holds the message so `state` / `overlayIntent` surface `.error` until the
  /// next start / reset clears it.
  func setExternalError(_ message: String) {
    kernel.cancel()
    outcome.transcript = nil
    lastExternalError = message
  }

  /// Intentional no-op (PR-4 §3.7). The kernel's `SessionID` structurally
  /// replaces the stall-recovery token (D11) — there is nothing to clear.
  func clearPendingStallRecovery() {}

  // MARK: HeartPathTelemetryTarget — forwards to the observer (PR-4 §3.9)

  func handleCaptureStall(_ ctx: CaptureStallContext) {
    observer.handleCaptureStall(ctx)
  }

  func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext) {
    observer.handleXPCReplyFailed(ctx)
  }

  func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext) {
    observer.handleCaptureSessionInterruption(ctx)
  }

  // MARK: DEBUG

  #if DEBUG
    /// Drives the kernel's cancel unwind — the kernel-era equivalent of
    /// `TranscriptionPipeline.forceCancelNow()`. Callable from `DebugFaultEndpoint`.
    package func forceCancelNow() async {
      kernel.cancel()
    }
  #endif

  // MARK: Kernel-state observation

  /// Arm `withObservationTracking` on `kernel.state`; the `onChange` closure
  /// hops to `@MainActor` before re-reading state and re-arming (PR-4 §3.7,
  /// Gemini concurrency premise — the explicit hop is the safe pattern).
  private func observeKernelState() {
    withObservationTracking {
      _ = kernel.state
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.fireStateChangeIfNeeded()
        self.observeKernelState()
      }
    }
  }

  private func fireStateChangeIfNeeded() {
    let mapped = state
    guard mapped != lastFiredState else { return }
    lastFiredState = mapped
    onStateChange?(mapped)
  }

  // MARK: State mapping — total, mechanical (PR-4 §3.7)

  /// Map a kernel state to the legacy `PipelineState`. Total over all 14 kernel
  /// states. `state.isActive` is `true` for every active kernel state, which
  /// the `PipelineSettingsSync` backend-switch guard depends on (§3.13).
  static func pipelineState(
    for state: RecordingSessionState, externalError: String?
  ) -> PipelineState {
    if let externalError {
      return .error(externalError)
    }
    switch state {
    case .idle, .cancelled, .discarded, .noSpeech:
      return .idle
    case .preparing, .warmingUp:
      return .loadingModel
    case .recording:
      return .recording
    case .stopping, .transcribing:
      return .transcribing
    case .finalizing:
      return .polishing
    case .completed:
      return .complete
    case .failed(let reason):
      return .error(failureMessage(reason))
    case .audioInterrupted:
      return .error(InterruptionMessages.micDisconnected)
    case .asrInterrupted:
      return .error(asrInterruptedMessage)
    }
  }

  /// Mirrors the shipped `TranscriptionPipeline` string verbatim (em-dash
  /// included) — PR-4 parity; the em-dash cleanup is a separate content change.
  static let asrInterruptedMessage = "Transcription service crashed — please try again"

  /// User-facing message for a `failed` terminal. The plan does not enumerate
  /// this map; each message mirrors today's `TranscriptionPipeline` string for
  /// the equivalent failure verbatim (parity — PR-4's bar is "user feels
  /// nothing change"), or a sensible message where the kernel splits a reason
  /// today's pipeline did not name distinctly. The `captureStalled` em-dash is
  /// preserved to match the shipped string byte-for-byte; fixing it is a
  /// separate content-lane change, out of PR-4 scope.
  static func failureMessage(_ reason: RecordingFailureReason) -> String {
    switch reason {
    case .prepareFailed:
      return "Couldn't start dictation. Please try again."
    case .permissionDenied:
      return "Microphone permission denied."
    case .modelWedged:
      return ModelLoadWatchdog.userMessage
    case .modelLoadFailed:
      return "Model load failed."
    case .captureStartFailed:
      return "Recording failed."
    case .noAudioCaptured:
      return "No audio captured"
    case .asrEmpty:
      return "Couldn't catch that -- try again"
    case .asrFailed:
      return "Transcription failed."
    case .asrWedged:
      return "Transcription stalled. Please try again."
    case .emptyAfterProcessing:
      return "No speech detected. Your clipboard is unchanged. Try again."
    case .storageFailed:
      return "Failed to save transcript"
    case .captureStalled:
      return "No audio detected — try again."
    }
  }
}
