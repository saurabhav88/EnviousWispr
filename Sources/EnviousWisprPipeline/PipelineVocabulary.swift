import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// Pipeline vocabulary shared across the recording driver and its consumers:
// the event input (`PipelineEvent`), the UI output (`OverlayIntent`), the
// interruption message constants, and the heart-path telemetry-target protocol.
// The `DictationPipeline` driver protocol that once lived here was deleted in
// PR-9 of #827 — `KernelDictationDriver` is the single concrete driver and the
// App consumes it directly. `KernelOwnershipFreezeTests` keeps it deleted.

// #1558 (heartpath E1): `InterruptionMessages` — the former single authority
// for interruption copy — was deleted. The driver now stamps a typed
// `TerminalNoticeReason` (`.deviceRemoved` / `.engineLost` / `.unknownInterruption`)
// and `DictationNarrator` in AppKit authors the sentence.

/// #1408 (grounded review A1): what a COMPLETED take discloses about the
/// interruption that cut it short. Derived from the stamped
/// `EngineInterruptionCause` at the planner call sites; carried as a typed
/// value instead of a Bool so a non-disconnect salvage can no longer paste
/// potentially truncated text with no notice at all.
///
/// nil (no value) = a normal completion, nothing to disclose. The two cases
/// split on the ONLY evidence axis the pipeline has: was the input device
/// verified removed (`isDeviceLoss`), or did capture die some other way with
/// the microphone, as far as we know, still attached. Copy for each cell lives
/// at the factory (`PipelineStateChangeHandlerFactory`), the single copy
/// authority for post-completion notices.
public enum CompletionInterruptionDisclosure: Equatable, Sendable {
  /// Core Audio confirmed the input device went away mid-recording.
  case deviceRemoved
  /// Capture was interrupted by anything else: engine lost, capture session
  /// lost. No claim about the microphone is allowed.
  case otherInterruption

  /// nil cause → nil disclosure (normal completion). Every stamped cause on a
  /// COMPLETED take is a disclosure: the take survived an interruption, so the
  /// pasted text may be missing its tail.
  public init?(cause: EngineInterruptionCause?) {
    guard let cause else { return nil }
    self = cause.isDeviceLoss ? .deviceRemoved : .otherInterruption
  }
}

/// Events the recording driver handles.
public enum PipelineEvent: Sendable {
  case preWarm
  /// Toggle recording. Carries the per-recording configuration snapshot; pipelines
  /// consume the config on start transitions and ignore it on stop transitions.
  /// Settings mutated mid-recording apply to the next recording's snapshot.
  case toggleRecording(DictationSessionConfig)
  case requestStop
  case cancelRecording
  case reset
}

/// What the overlay should display — decoupled from internal pipeline state.
public enum OverlayIntent: Equatable, Sendable {
  case hidden
  case recording(audioLevel: Float)
  /// #1564 (heartpath E2): carries a TYPED `ProcessingPhase`; `DictationNarrator`
  /// in AppKit authors the "Transcribing..." / "Polishing..." / max-duration words.
  case processing(phase: ProcessingPhase)
  /// Transient notice shown when paste fell back to clipboard-only (Tier 3).
  /// Auto-dismissed by the overlay panel after a short delay.
  case clipboardFallback
  /// Educational notice shown once-per-session when paste cascade falls back
  /// to clipboard because Accessibility permission is denied. Includes an
  /// inline Grant button. Auto-dismissed after about 6 seconds.
  case accessibilityToast
  /// Transient warning notice for degraded-but-delivered results (e.g. polish failed).
  /// Orange icon, auto-dismissed by the overlay panel after 2.5 seconds.
  case warning(message: String)
  /// Transient error notice for a terminal capture / transcription failure.
  /// #1558: carries a TYPED reason; `DictationNarrator` authors the
  /// sentence. Auto-dismissed by the overlay panel after 3 seconds.
  case error(reason: TerminalNoticeReason)
  /// Transient interruption notice shown when the recording was cut short
  /// (device removed, or engine lost with the mic still attached). #1558:
  /// carries a TYPED reason. Distress lips (red pulse), auto-dismissed after 2 seconds.
  case interruption(reason: TerminalNoticeReason)
  /// Passive language-lock discoverability chip surfaced post-dictation when the
  /// detector observed N consecutive high-confidence accepts of the same non-English
  /// language. Renders State A (strikes 1+2: Lock + Dismiss) or State B (strike 3:
  /// Dismiss only with Settings copy). Auto-dismissed after 6 seconds; pauses on hover.
  case passiveChip(payload: LanguageChipPayload)
  /// Cold-boot warm-up notice (#879). Shown when the user presses while the
  /// active engine is not yet ready (fresh install, or first launch after a
  /// macOS update wiped the compiled-model cache). Replaces the bare
  /// "Preparing dictation…" wall: an honest, plain-English "getting ready"
  /// pill. `engineLabel` is the active engine's display name, shown as a
  /// secondary line. Auto-dismissed after about 2 seconds.
  case cachingModel(engineLabel: String)
  /// Cold-boot "ready" announcement (#879). Fired when a warm-up that the user
  /// raced (saw a `.cachingModel` pill for) finishes, so they know to press
  /// again. Auto-dismissed after about 1.5 seconds. Never fired at launch when
  /// no cold press preceded it.
  case engineReady
  /// Crash-recovery hold notice (#1063 PR2). Shown when the user presses to
  /// record while the one leftover recording from a prior abnormal exit is
  /// backfilling behind the shared engine — exactly the cold-engine
  /// `.cachingModel` shape, plus a Discard affordance for "I don't want to
  /// wait." No session is minted. Auto-dismissed after a few seconds; re-shown
  /// on each blocked press.
  case recoveringLastRecording
  /// Bluetooth cold-start education card (#1480). Shown once per launch when the
  /// configured input is a Bluetooth microphone and dictation is idle, sitting in
  /// the same top-middle slot as the recording pill. Unlike every other intent it
  /// has NO auto-dismiss: it persists until the user starts recording (which
  /// supersedes it via the single-slot dedup), taps "Got it" / close / "Adjust
  /// settings", the input changes away from Bluetooth, or the tips setting is
  /// turned off. Its decision + lifecycle are owned by `BluetoothAwarenessPresenter`.
  case bluetoothAwareness
}

/// Why a recording ended at a terminal state WITHOUT a durable transcript save,
/// classified for the crash-recovery cleanup signal (#1063 PR2). Derived from
/// the kernel's terminal `RecordingSessionState` by `KernelDictationDriver`.
///
/// - `discard`: the user (or the absence of speech) ended it — `.cancelled`,
///   `.discarded`, `.noSpeech`. Nothing worth recovering: delete the spool now.
/// - `failure`: a pipeline / audio / engine fault ended it — `.failed`,
///   `.audioInterrupted`, `.asrInterrupted`. The captured audio is the user's
///   words they wanted: RETAIN the spool so it is recovered on the next launch.
public enum RecordingTerminalKind: Equatable, Sendable {
  case discard
  case failure
}

/// Issue #285 — heart-path telemetry callbacks that the former root state routes to
/// whichever pipeline is currently recording. The underlying `AudioCapture*`
/// callback properties are single-owner on the shared capture instance, so
/// per-pipeline wiring would let the second-initialized pipeline steal them.
@MainActor
public protocol HeartPathTelemetryTarget: AnyObject {
  func handleCaptureStall(_ ctx: CaptureStallContext)
}
