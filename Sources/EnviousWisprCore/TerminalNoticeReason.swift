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
  /// #1920: NO PRODUCTION PRODUCER — the empty-decode path now ends at
  /// `asr_empty_despite_audio` and says nothing to the user. This raw value is
  /// retained because historical PostHog rows carry it; expect the series to
  /// drop to zero at that release boundary, and read that drop as the change,
  /// not as a fix. Do not give it a producer again.
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

/// #1891 (epic #1876 Phase 2b). A terminal fact that is NOT our software
/// failing: the microphone delivered nothing usable, so the take ended with no
/// text through no fault of the pipeline.
///
/// Deliberately a SEPARATE type from `TerminalNoticeReason`, not another case
/// on it. `TerminalNoticeReason` means "a terminal notice whose raw value is
/// the PostHog `pipeline.failed.error_code`", and both halves are wrong here:
/// only one of these two reasons emits `pipeline.failed` at all, and the
/// founder's model (#1876, 2026-07-31) splits capture endings into exactly two
/// customer buckets — OUR SOFTWARE ("[X] error. Try again.") and YOUR SETUP.
/// This type is the second bucket.
///
/// Two cases rather than one because the two producers have different
/// telemetry obligations even though they share a sentence: `.zeroSignal`
/// continues the existing `pipeline.failed` `zero_signal` series (340 events /
/// 50 users per 30d — the baseline the Phase 2 analysis rests on), while
/// `.vadGateNoSpeech` is already counted by `audio.vad_gate_no_speech` (#1845)
/// and must NOT manufacture a second, overlapping failure record.
///
/// Both narrate identically. Do not add a per-case sentence without a founder
/// decision: #1558 locked the customer copy set, and #1891 added exactly one
/// seventh sentence to it.
public enum TerminalAdvisoryReason: Equatable, Sendable, CaseIterable {
  /// The capture buffer was digitally silent — a closed lid in clamshell,
  /// vendor firmware mute, or a dead channel. Reaches here from
  /// `RecordingOutcome.failed(.zeroSignal)`; keeps emitting `pipeline.failed`
  /// with the unchanged `zero_signal` code.
  case zeroSignal

  /// The capture carried a signal floor but no speech evidence: every dead-air
  /// threshold was crossed (raw peak `<0.006`, whole-buffer RMS `<0.00125`,
  /// max 40 ms window RMS `<0.002`). An analog mute switch or a dead 3.5 mm
  /// line looks like this — an ADC keeps converting a broken line, so it can
  /// never read exact zero. Reaches here from `.noSpeech(.vadGate)`.
  ///
  /// NOT the same as a user who simply said nothing: that is
  /// `.asrEmptyNoSpeech`, which stays silent because the microphone was
  /// working and the user already knows they did not speak.
  case vadGateNoSpeech
}
