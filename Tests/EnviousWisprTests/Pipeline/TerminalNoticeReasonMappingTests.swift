import EnviousWisprAudio
import EnviousWisprCore
import Testing

@testable import EnviousWisprPipeline

/// #1558 (heartpath E1). Freezes the engine → typed-reason maps: every
/// `RecordingFailureReason` and every `EngineInterruptionCause?` lands on the
/// intended `TerminalNoticeReason`. Both maps are exhaustive (no `default`), so
/// a new source case reds the build until it is assigned here.
@Suite struct TerminalNoticeReasonMappingTests {

  @Test("every RecordingFailureReason maps to its typed reason")
  func failureReasonMapping() {
    let cases: [(RecordingFailureReason, TerminalNoticeReason)] = [
      (.prepareFailed, .prepareFailed),
      (.permissionDenied, .permissionDenied),
      (.modelWedged, .modelWedged),
      (.modelLoadFailed, .modelLoadFailed),
      (.captureStartFailed, .captureStartFailed),
      (.noAudioCaptured, .noAudioCaptured),
      (.asrEmpty, .asrEmptyWithSpeech),
      (.asrFailed, .asrFailed),
      (.asrWedged, .asrWedged),
      (.emptyAfterProcessing, .emptyAfterProcessing),
      (.captureStalled, .captureStalled),
      (.zeroSignal, .zeroSignal),
    ]
    for (reason, expected) in cases {
      #expect(KernelDictationDriver.terminalNoticeReason(for: reason) == expected)
    }
  }

  @Test("interruption cause maps: deviceRemoved / engineLost / nil → neutral")
  func interruptionCauseMapping() {
    #expect(
      KernelDictationDriver.terminalNoticeReason(for: EngineInterruptionCause.deviceRemoved)
        == .deviceRemoved)
    #expect(
      KernelDictationDriver.terminalNoticeReason(for: EngineInterruptionCause.engineLost)
        == .engineLost)
    // A nil cause narrates as the neutral interruption (matches the retired
    // InterruptionMessages nil handling).
    #expect(
      KernelDictationDriver.terminalNoticeReason(for: EngineInterruptionCause?.none)
        == .unknownInterruption)
  }
}
