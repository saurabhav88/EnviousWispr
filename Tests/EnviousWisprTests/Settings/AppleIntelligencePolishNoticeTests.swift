import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Issue #1080 — locks the onboarding polish-availability contract:
/// 1. `AppleIntelligenceAvailabilityReport.onboardingPolishNotice` maps the
///    launch availability verdict to exactly the two ACTIONABLE notices (turn
///    it on / update macOS) and stays silent for everything else.
/// 2. The validated System Settings deep-link string does not drift.
///
/// Matcher-set adversarial coverage (per workflow RULE): every failure reason
/// is exercised, including the unreachable hardware case and the status guard,
/// so a future-added reason defaults to silent rather than surfacing a notice.
@Suite("Onboarding polish availability notice (#1080)")
struct AppleIntelligencePolishNoticeTests {

  /// Synthetic report with an all-passed gate set (gates are irrelevant to the
  /// classifier, which reads only `overallStatus` + `failureReasons`).
  private func makeReport(
    status: AIAvailabilityStatus,
    reasons: [AIFailureReason]
  ) -> AppleIntelligenceAvailabilityReport {
    let gate = AIGateResult.passed(summary: "synthetic")
    let gates = AIGateSet(
      build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate)
    return AppleIntelligenceAvailabilityReport(
      overallStatus: status,
      gates: gates,
      failureReasons: reasons,
      osVersion: "synthetic",
      hardwareClass: "arm64")
  }

  // MARK: - Positives (the two actionable reasons)

  @Test("Apple Intelligence switched off maps to enableInSettings")
  func disabledMapsToEnableInSettings() {
    let report = makeReport(status: .unavailable, reasons: [.appleIntelligenceDisabled])
    #expect(report.onboardingPolishNotice == .enableInSettings)
  }

  @Test("Pre-macOS-26 maps to updateMacOS")
  func unsupportedOSMapsToUpdateMacOS() {
    let report = makeReport(status: .unavailable, reasons: [.unsupportedOS])
    #expect(report.onboardingPolishNotice == .updateMacOS)
  }

  // MARK: - Negatives (unavailable, but not an actionable reason)

  @Test("Every reason except the two actionable ones is silent under .unavailable")
  func allOtherReasonsAreSilent() {
    for reason in AIFailureReason.allCases
    where reason != .appleIntelligenceDisabled && reason != .unsupportedOS {
      #expect(
        makeReport(status: .unavailable, reasons: [reason]).onboardingPolishNotice == nil,
        "\(reason) should be silent")
    }
  }

  // MARK: - Status guard (only .unavailable can surface a notice)

  @Test("Available status is always silent")
  func availableIsSilent() {
    #expect(makeReport(status: .available, reasons: []).onboardingPolishNotice == nil)
  }

  @Test("Degraded / unknown status is silent even with an otherwise-actionable reason")
  func nonUnavailableStatusIsSilent() {
    // The guard is `overallStatus == .unavailable`. A degraded/unknown report
    // carrying a mapped reason must still stay silent.
    #expect(
      makeReport(status: .degraded, reasons: [.appleIntelligenceDisabled]).onboardingPolishNotice
        == nil)
    #expect(
      makeReport(status: .unknown, reasons: [.unsupportedOS]).onboardingPolishNotice == nil)
  }

  // MARK: - Precedence (defensive: the two are mutually exclusive in practice)

  // MARK: - Deep-link constant

  @Test("System Settings deep-link matches the validated Apple Intelligence & Siri pane")
  func deepLinkConstantDoesNotDrift() {
    // Validated 2026-06-19 on macOS 26.6: opening this lands on the
    // "Apple Intelligence & Siri" pane. Guards accidental edits.
    #expect(
      AppleIntelligenceSettings.systemSettingsURL
        == "x-apple.systempreferences:com.apple.Siri-Settings.extension")
  }
}
