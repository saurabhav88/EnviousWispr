import EnviousWisprCore

/// #1558 (heartpath E1). The single, stateless authority that turns a typed
/// `TerminalNoticeReason` into the customer-facing sentence shown on the pill
/// and the main window when a dictation could not complete or was cut short.
///
/// This is the "what we say" half of the one-voice split: the engine emits the
/// fact (`TerminalNoticeReason`), this presenter — and ONLY this presenter —
/// authors the English. It lives in AppKit because the engine modules that
/// produce the reason sit below AppKit and cannot author UI copy without
/// inverting dependency direction. Stateless (an `enum` with a static func):
/// neither stored nor environment-injected. Promote to an injected instance
/// only if a test ever needs to swap the mapping.
///
/// The six sentences are founder-LOCKED (issue #1558, 2026-07-15). The design
/// rule: `[Category] error. Try again.` = our bug, just retry (a deliberate
/// self-triage channel — a user reporting "Transcription error" names the stage
/// with no logs); a plain sentence = a true event that happened. Raw internal
/// detail never reaches here — it stays owned by the producer's Sentry site.
enum TerminalNoticePresenter {
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
}
