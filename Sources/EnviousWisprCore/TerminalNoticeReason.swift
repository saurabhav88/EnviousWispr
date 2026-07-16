import Foundation

/// #1558 (heartpath E1). A presentation-neutral, typed enumeration of the
/// distinct terminal-failure / interruption FACTS the UI narrates when a
/// dictation could not complete or was cut short.
///
/// This is the "what happened" half of the one-voice split: the engine
/// (Pipeline / AppKit-side start path) maps its internal outcomes into exactly
/// one case here, and a single stateless presenter in AppKit
/// (`DictationNarrator`) maps a case to the customer sentence. Keeping the
/// fact separate from the sentence is the whole point — if the engine emitted
/// the six customer buckets it would be making the presentation decision this
/// refactor is centralising.
///
/// Lives in `EnviousWisprCore` (the bottom module) because both Core-level
/// state carriers — `PipelineState.error` and `PipelineActivity.error` — hold
/// it, and Core cannot reference the Pipeline/Audio types the reasons are
/// mapped FROM without inverting dependency direction.
///
/// `String`-raw so the telemetry boundary can read a stable code without
/// re-deriving one. The raw value is NEVER shown to a user: it is the stable
/// PostHog `pipeline.failed.error_code`; Sentry keeps its existing
/// producer-owned taxonomy. Customer copy lives ONLY in the AppKit presenter.
public enum TerminalNoticeReason: String, Equatable, Sendable, CaseIterable {
  // Start / capture-stage failures → "Audio capture error. Try again."
  case prepareFailed = "prepare_failed"
  case modelWedged = "model_wedged"
  case modelLoadFailed = "model_load_failed"
  case captureStartFailed = "capture_start_failed"
  case micWouldNotOpen = "mic_would_not_open"
  case captureStalled = "capture_stalled"
  case zeroSignal = "zero_signal"

  // Transcribe-stage failures → "Transcription error. Try again."
  case asrFailed = "asr_failed"
  case asrWedged = "asr_wedged"
  case asrInterrupted = "asr_interrupted"
  case noAudioCaptured = "no_audio_captured"
  case asrEmptyWithSpeech = "asr_empty_with_speech"
  case emptyAfterProcessing = "empty_after_processing"

  // User-actionable
  case permissionDenied = "permission_denied"
  case noMicrophoneFound = "no_microphone_found"

  // Informational interruptions (audio saved)
  case deviceRemoved = "device_removed"
  case engineLost = "engine_lost"
  /// A capture interruption arrived with no stamped `EngineInterruptionCause`
  /// (nil). Narrates as the neutral "Recording interrupted." — the same choice
  /// the retired `InterruptionMessages` made for a nil cause.
  case unknownInterruption = "unknown_interruption"

  /// Reserved typed fallback with no current producer. Both engine maps are
  /// exhaustive (no `default`), so this is never the result of an unmapped
  /// enum case; any future explicit producer must own its own telemetry first.
  case unknown
}
