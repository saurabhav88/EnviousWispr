import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #1558 (heartpath E1). Freezes the copy contract: the presenter is the SOLE
/// author of the six founder-locked terminal-notice sentences, and no reason
/// leaks raw internal detail.
@Suite struct TerminalNoticePresenterTests {

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
      #expect(TerminalNoticePresenter.copy(for: reason) == want)
    }
  }

  @Test("no sentence carries raw internal detail (the retired leak prefixes)")
  func noRawDetailLeak() {
    let bannedPrefixes = [
      "Model load failed:", "Recording failed:", "Transcription failed:",
      "Speech engine isn't responding",  // old ModelLoadWatchdog.userMessage
    ]
    for reason in TerminalNoticeReason.allCases {
      let copy = TerminalNoticePresenter.copy(for: reason)
      for banned in bannedPrefixes {
        #expect(!copy.contains(banned), "\(reason) copy must not contain '\(banned)'")
      }
    }
  }

  @Test("the six sentences use no em/en dashes (in-app copy rule)")
  func noDashesInCopy() {
    for reason in TerminalNoticeReason.allCases {
      let copy = TerminalNoticePresenter.copy(for: reason)
      #expect(!copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(reason) copy has a dash")
    }
  }
}
