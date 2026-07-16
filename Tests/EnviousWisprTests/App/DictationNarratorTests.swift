import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #1558 (E1) / #1564 (E2). Freezes the copy contract: `DictationNarrator` is
/// the SOLE author of the founder-locked sentences and processing labels, no
/// reason leaks raw internal detail, and every processing phase keeps its exact
/// byte form across the three render surfaces.
@Suite struct DictationNarratorTests {

  // MARK: - Terminal notices (E1)

  @Test("every reason maps to its exact founder-locked sentence")
  func everyReasonMapsToLockedCopy() {
    let expected: [TerminalNoticeReason: String] = [
      // Audio capture error bucket (our-fault start / capture).
      .prepareFailed: "Audio capture error. Try again.",
      .modelWedged: "Audio capture error. Try again.",
      .modelLoadFailed: "Audio capture error. Try again.",
      .captureStartFailed: "Audio capture error. Try again.",
      .micWouldNotOpen: "Audio capture error. Try again.",
      .captureStalled: "Audio capture error. Try again.",
      .zeroSignal: "Audio capture error. Try again.",
      // Transcription error bucket (our-fault transcribe).
      .asrFailed: "Transcription error. Try again.",
      .asrWedged: "Transcription error. Try again.",
      .asrInterrupted: "Transcription error. Try again.",
      .noAudioCaptured: "Transcription error. Try again.",
      .asrEmptyWithSpeech: "Transcription error. Try again.",
      .emptyAfterProcessing: "Transcription error. Try again.",
      .unknown: "Transcription error. Try again.",
      // User-actionable.
      .permissionDenied: "Microphone access is off.",
      .noMicrophoneFound: "No microphone found. Please connect one.",
      // Informational interruptions.
      .deviceRemoved: "Microphone disconnected.",
      .engineLost: "Recording interrupted.",
      .unknownInterruption: "Recording interrupted.",
    ]
    // The map must cover EVERY case — a new reason with no expected entry fails
    // here rather than silently defaulting.
    for reason in TerminalNoticeReason.allCases {
      guard let want = expected[reason] else {
        Issue.record("no expected copy for \(reason) — add it to the locked set")
        continue
      }
      #expect(DictationNarrator.copy(for: reason) == want)
    }
  }

  @Test("no sentence carries raw internal detail (the retired leak prefixes)")
  func noRawDetailLeak() {
    let bannedPrefixes = [
      "Model load failed:", "Recording failed:", "Transcription failed:",
      "Speech engine isn't responding",  // old ModelLoadWatchdog.userMessage
    ]
    for reason in TerminalNoticeReason.allCases {
      let copy = DictationNarrator.copy(for: reason)
      for banned in bannedPrefixes {
        #expect(!copy.contains(banned), "\(reason) copy must not contain '\(banned)'")
      }
    }
  }

  @Test("the terminal sentences use no em/en dashes (in-app copy rule)")
  func noDashesInTerminalCopy() {
    for reason in TerminalNoticeReason.allCases {
      let copy = DictationNarrator.copy(for: reason)
      #expect(!copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(reason) copy has a dash")
    }
  }

  // MARK: - Processing phases (E2, #1564)

  /// The active-pill / main-window form uses three ASCII periods and the
  /// 60-minute cap prefix. Byte-exact — these must match today's literals.
  @Test("processing pill copy is byte-exact ASCII")
  func processingPillCopyByteExact() {
    #expect(DictationNarrator.copy(for: .transcribing) == "Transcribing...")
    #expect(DictationNarrator.copy(for: .polishing) == "Polishing...")
    #expect(
      DictationNarrator.copy(for: .transcribingMaxDurationReached)
        == "60-minute limit reached. Transcribing...")
    // Guard the ASCII vs Unicode distinction explicitly: the pill must NOT carry
    // the single Unicode ellipsis the badge uses.
    #expect(!DictationNarrator.copy(for: .transcribing).contains("\u{2026}"))
  }

  /// The toolbar status-badge form uses ONE Unicode ellipsis (`\u{2026}`),
  /// preserving today's `StatusBadge` bytes — NOT the ASCII pill form.
  @Test("processing status-badge copy keeps the Unicode ellipsis")
  func processingBadgeCopyKeepsUnicodeEllipsis() {
    #expect(DictationNarrator.statusBadgeCopy(for: .transcribing) == "Transcribing\u{2026}")
    #expect(DictationNarrator.statusBadgeCopy(for: .polishing) == "Polishing\u{2026}")
    // The max-duration case collapses to the plain transcribing badge (Channel B
    // never emits it, but the switch must be total and byte-stable).
    #expect(
      DictationNarrator.statusBadgeCopy(for: .transcribingMaxDurationReached)
        == "Transcribing\u{2026}")
    // Must NOT be the ASCII three-period form.
    #expect(!DictationNarrator.statusBadgeCopy(for: .transcribing).contains("..."))
  }

  /// The tight sidebar chip form uses no ellipsis at all.
  @Test("processing short copy has no ellipsis")
  func processingShortCopyHasNoEllipsis() {
    #expect(DictationNarrator.shortCopy(for: .transcribing) == "Transcribing")
    #expect(DictationNarrator.shortCopy(for: .polishing) == "Polishing")
    #expect(DictationNarrator.shortCopy(for: .transcribingMaxDurationReached) == "Transcribing")
    for phase in ProcessingPhase.allCases {
      let short = DictationNarrator.shortCopy(for: phase)
      #expect(
        !short.contains("...") && !short.contains("\u{2026}"), "\(phase) short copy has an ellipsis"
      )
    }
  }

  @Test("processing copy uses no em/en dashes (in-app copy rule)")
  func noDashesInProcessingCopy() {
    for phase in ProcessingPhase.allCases {
      for copy in [
        DictationNarrator.copy(for: phase),
        DictationNarrator.statusBadgeCopy(for: phase),
        DictationNarrator.shortCopy(for: phase),
      ] {
        #expect(
          !copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(phase) copy has a dash")
      }
    }
  }
}
