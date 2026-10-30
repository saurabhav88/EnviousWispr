import EnviousWisprCore
import Foundation
import Testing

@Suite("Apple Intelligence setup guidance (#4016)", .tags(.productOutcome))
struct AppleIntelligenceSetupCopyTests {
  @Test("a restored disabled report gives guidance for the displaying Mac")
  func disabledReportUsesDisplayHost() {
    let gate = AIGateResult.passed(summary: "fixture")
    let report = AppleIntelligenceAvailabilityReport(
      overallStatus: .unavailable,
      gates: AIGateSet(
        build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate),
      failureReasons: [.appleIntelligenceDisabled], osVersion: "26.6", hardwareClass: "arm64")
    let expected = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
      ? "At the last check, macOS reported that Apple Intelligence wasn't enabled on this Mac. You can keep dictating or choose another model in Settings > AI Polish."
      : "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri."
    #expect(report.userVisibleMessage == expected)
    #expect(report.onboardingPolishNotice == .enableInSettings)
  }

  @Test("macOS 26 keeps every established disabled-state instruction")
  func macOS26Instructions() {
    let copy = AppleIntelligenceSetupCopy.forOSMajorVersion(26)
    #expect(copy.title == "Apple Intelligence is turned off")
    #expect(copy.availabilityMessage == "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri.")
    #expect(copy.onboardingMessage == "Turn it on to enable free, on-device AI polish. Dictation works fine without it.")
    #expect(copy.leaveMessage == "Turn it on in System Settings, or pick another model.")
  }

  @Test("macOS 27 and later report the last check without promising a Settings cure", arguments: [27, 28])
  func newerInstructions(major: Int) {
    let copy = AppleIntelligenceSetupCopy.forOSMajorVersion(major)
    #expect(copy.title == "Apple Intelligence wasn't enabled")
    #expect(copy.availabilityMessage == "At the last check, macOS reported that Apple Intelligence wasn't enabled on this Mac. You can keep dictating or choose another model in Settings > AI Polish.")
    #expect(copy.onboardingMessage == "Apple Intelligence wasn't enabled at the last check. You can keep dictating or choose another model in Settings > AI Polish. System Settings may not offer a fix.")
    #expect(copy.leaveMessage == "Apple Intelligence wasn't enabled at the last check. Pick another model, or leave without AI polish. System Settings may not offer a fix.")
  }
}
