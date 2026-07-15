import EnviousWisprAudio
import EnviousWisprCore
import Foundation
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
      (.noMicrophoneFound, .noMicrophoneFound),
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

  @Test("classifyCaptureStartError distinguishes no-device, permission, and generic (P2 #1563)")
  func captureStartErrorClassification() {
    // A missing input device must classify distinctly so the toggle/menu path
    // surfaces "No microphone found.", not the generic capture error.
    #expect(
      RecordingSessionKernel.classifyCaptureStartError(AudioError.noBuiltInMicrophoneFound)
        == .noMicrophoneFound)
    // Permission and generic classifications are unchanged.
    #expect(
      RecordingSessionKernel.classifyCaptureStartError(
        NSError(
          domain: "x", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "microphone permission denied"]))
        == .permissionDenied)
    #expect(
      RecordingSessionKernel.classifyCaptureStartError(NSError(domain: "x", code: 2))
        == .captureStartFailed)
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
