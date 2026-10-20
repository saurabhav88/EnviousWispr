import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #3886: the main window's error state offers the action that can fix the
/// failure. Try Again only clears the error, so a denied or missing
/// microphone sends the user to the setting that fixes it instead.
@MainActor
@Suite("StatusView error recovery", .tags(.productOutcome))
struct StatusViewErrorRecoveryTests {

  @Test(
    "denied microphone → Open Settings",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3886", "main window Try Again"))
  func permissionDeniedOpensMicrophoneSettings() {
    #expect(StatusView.errorRecovery(for: .permissionDenied) == .openMicrophoneSettings)
  }

  @Test(
    "no microphone found → Microphone Settings",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3886", "main window Try Again"))
  func noMicrophoneOpensDeviceSettings() {
    #expect(StatusView.errorRecovery(for: .noMicrophoneFound) == .openMicrophoneDeviceSettings)
  }

  @Test("every other error reason keeps Try Again")
  func otherReasonsKeepTryAgain() {
    let others = TerminalNoticeReason.allCases.filter {
      $0 != .permissionDenied && $0 != .noMicrophoneFound
    }
    // Control: the filter left real cases to check.
    #expect(others.count == TerminalNoticeReason.allCases.count - 2)
    for reason in others {
      #expect(StatusView.errorRecovery(for: reason) == .tryAgain, "\(reason.rawValue)")
    }
  }
}
