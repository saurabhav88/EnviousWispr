import EnviousWisprCore

/// #1558 (E1) / #1564 (E2). The single, stateless authority that turns the
/// engine's typed facts into the customer-facing words shown on the pill, the
/// main window, the toolbar badge, and the sidebar status chip.
///
/// This is the "what we say" half of the one-voice split: the engine emits the
/// fact (`TerminalNoticeReason` for terminal failures/interruptions,
/// `ProcessingPhase` for the transcribe/polish stages), this narrator — and
/// ONLY this narrator — authors the English. It lives in AppKit because the
/// engine modules that produce the facts sit below AppKit and cannot author UI
/// copy without inverting dependency direction. Stateless (an `enum` with
/// static funcs): neither stored nor environment-injected. Promote to an
/// injected instance only if a test ever needs to swap the mapping.
///
/// Renamed from `TerminalNoticePresenter` in E2 once it began authoring more
/// than terminal notices. As later parts move their families here it becomes
/// the SOLE voice (heartpath step 6, "one voice").
enum DictationNarrator {

  // MARK: - Terminal failures / interruptions (E1)

  /// The six sentences are founder-LOCKED (issue #1558, 2026-07-15). The design
  /// rule: `[Category] error. Try again.` = our bug, just retry (a deliberate
  /// self-triage channel — a user reporting "Transcription error" names the
  /// stage with no logs); a plain sentence = a true event that happened. Raw
  /// internal detail never reaches here — it stays owned by the producer's
  /// Sentry site.
  static func copy(for reason: TerminalNoticeReason) -> String {
    switch reason {
    // Our-fault start / capture failures → retry.
    case .prepareFailed, .modelWedged, .modelLoadFailed, .captureStartFailed,
      .micWouldNotOpen, .captureStalled, .zeroSignal:
      return "Audio capture error. Try again."
    // Our-fault transcribe failures (incl. "couldn't catch that") → retry.
    case .asrFailed, .asrWedged, .asrInterrupted, .noAudioCaptured,
      .asrEmptyWithSpeech, .emptyAfterProcessing, .unknown:
      return "Transcription error. Try again."
    // User-actionable.
    case .permissionDenied:
      return "Microphone access is off."
    case .noMicrophoneFound:
      return "No microphone found. Please connect one."
    // Informational interruptions (audio was saved).
    case .deviceRemoved:
      return "Microphone disconnected."
    case .engineLost, .unknownInterruption:
      return "Recording interrupted."
    }
  }

  // MARK: - Processing / phase labels (E2, #1564)

  // The processing words are founder-LOCKED unchanged (2026-07-15). Three
  // byte-distinct render forms are preserved: the active pill and main window
  // use three ASCII periods; the toolbar status badge uses ONE Unicode ellipsis
  // (`\u{2026}`); the tight sidebar chip uses no ellipsis. They are three
  // presentation forms of one authority, not three authorities.

  /// Active-pill / main-window form: three ASCII periods, plus the 60-minute
  /// cap prefix on the max-duration variant.
  static func copy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing:
      return "Transcribing..."
    case .polishing:
      return "Polishing..."
    case .transcribingMaxDurationReached:
      return "60-minute limit reached. Transcribing..."
    }
  }

  /// Toolbar status-badge form: one Unicode ellipsis (preserves today's bytes).
  static func statusBadgeCopy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing, .transcribingMaxDurationReached:
      return "Transcribing\u{2026}"
    case .polishing:
      return "Polishing\u{2026}"
    }
  }

  /// Tight sidebar status chip: no ellipsis (max-duration collapses to the
  /// plain word — Channel B never emits the max-duration case anyway).
  static func shortCopy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing, .transcribingMaxDurationReached:
      return "Transcribing"
    case .polishing:
      return "Polishing"
    }
  }
}
