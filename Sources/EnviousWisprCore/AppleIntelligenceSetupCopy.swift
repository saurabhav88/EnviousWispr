import Foundation

/// Setup wording for the displaying Mac, independent of the report's saved OS version.
/// The disabled API result identifies a condition, not its cause or a guaranteed remedy (#4016).
public struct AppleIntelligenceSetupCopy: Sendable {
  public let title: String
  public let availabilityMessage: String
  public let onboardingMessage: String
  public let leaveMessage: String

  public static var current: Self {
    forOSMajorVersion(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
  }

  public static func forOSMajorVersion(_ major: Int) -> Self {
    if major >= 27 {
      return Self(
        title: String(
          localized: "Apple Intelligence wasn't enabled",
          comment: "Apple Intelligence setup title. The last check reported it not enabled; the cause is unknown."),
        availabilityMessage: String(
          localized: "At the last check, macOS reported that Apple Intelligence wasn't enabled on this Mac. You can keep dictating or choose another model in Settings > AI Polish.",
          comment: "Apple Intelligence status on macOS 27 or later. Reports the last observation, never a cause or a promised repair."),
        onboardingMessage: String(
          localized: "Apple Intelligence wasn't enabled at the last check. You can keep dictating or choose another model in Settings > AI Polish. System Settings may not offer a fix.",
          comment: "Onboarding Apple Intelligence notice on macOS 27 or later. The Open System Settings button is not a guaranteed remedy."),
        leaveMessage: String(
          localized: "Apple Intelligence wasn't enabled at the last check. Pick another model, or leave without AI polish. System Settings may not offer a fix.",
          comment: "Apple Intelligence leave-page dialog on macOS 27 or later. Leave means navigating away from the page."))
    }
    // Preserve the macOS 26 remedy; older supported systems use the existing unsupported-OS path.
    return Self(
      title: String(
        localized: "Apple Intelligence is turned off",
        comment: "Apple Intelligence setup title on macOS 26, which has the master switch."),
      availabilityMessage: String(
        localized: "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri.",
        comment: "Apple Intelligence setup instruction on macOS 26."),
      onboardingMessage: String(
        localized: "Turn it on to enable free, on-device AI polish. Dictation works fine without it.",
        comment: "Apple Intelligence onboarding instruction on macOS 26."),
      leaveMessage: String(
        localized: "Turn it on in System Settings, or pick another model.",
        comment: "Apple Intelligence leave-page instruction on macOS 26."))
  }
}
