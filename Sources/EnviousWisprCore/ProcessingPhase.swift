import Foundation

/// #1564 (heartpath E2). A presentation-neutral, typed enumeration of the
/// processing phase the pipeline is in while it turns a finished recording into
/// text. The engine emits one of these facts; a single stateless presenter in
/// AppKit (`DictationNarrator`) authors the user-facing words.
///
/// This is the processing-family half of the one-voice split, mirroring
/// `TerminalNoticeReason` for the terminal-failure family: the engine reports
/// WHICH phase it is in, the UI decides WHAT to say. Keeping the fact separate
/// from the sentence is the point — if the engine emitted the English it would
/// be making the presentation decision this refactor is centralising.
///
/// Lives in `EnviousWisprCore` (the bottom module) so both `OverlayIntent`
/// (Pipeline) and the AppKit narrator/views can reference the shared value
/// without those modules importing each other. Unlike `TerminalNoticeReason`,
/// no Core-level state carrier holds a `ProcessingPhase` — the window/badge/
/// sidebar surfaces derive it inline from their existing `PipelineState` switch
/// arms — so this is placement-by-shared-value, not a state-carrier mirror.
///
/// No raw value: E2 adds no telemetry consumer for the phase, so a `String`
/// raw would be speculative public API.
public enum ProcessingPhase: Equatable, Sendable, CaseIterable {
  /// Turning captured speech into text.
  case transcribing
  /// The AI cleanup pass over the transcribed text.
  case polishing
  /// Transcribing after a 60-minute-cap auto-stop. Still transcribing; the pill
  /// prefixes the cap notice. Only the pill channel (the driver) can emit this;
  /// the window/badge/sidebar never do.
  case transcribingMaxDurationReached
}
