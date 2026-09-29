/// When the word check may be put in memory (#3289). The residency twin of `WordCheckFetchPolicy`:
/// that one decides whether the model is on disk, this one whether a trigger may load it.
///
/// The rule: only work that will use the check loads it. Before #3289 the model loaded whenever
/// the settings said some engine might need it (launch, a settings change, finishing setup, the
/// model's own admission), so a Mac held about 500 MB with nobody dictating (Sentry
/// ENVIOUSWISPR-5Y). Every trigger is classified here, with no `default:`, so a new one cannot
/// load the model without someone deciding it should.
enum WordCheckResidencyPolicy {
  /// Every event that can reach a load. The raw value is the name the log has always used.
  enum Trigger: String, CaseIterable, Sendable {
    case launch
    case settingsChanged = "settings"
    case onboardingChanged = "onboarding_changed"
    case parakeetAdmitted = "parakeet_admitted"
    case deliveryAdmitted = "delivery_admitted"
    case appCancelFinished = "app_cancel_finished"
    case recordingStarted = "recording_started"
    case fileImportStarted = "file_import_started"
    case takeSelection = "take"
    case userRetry = "settings_retry"
  }

  /// `needsWordCheck`: for a recording or a file import, whether ITS frozen polish engine has no
  /// checker of its own. The other triggers ignore it.
  static func shouldLoad(_ trigger: Trigger, needsWordCheck: Bool) -> Bool {
    switch trigger {
    case .launch, .settingsChanged, .onboardingChanged, .parakeetAdmitted, .deliveryAdmitted,
      .appCancelFinished:
      // Background: nobody is dictating or transcribing yet. The download may still run
      // (`WordCheckFetchPolicy`), because disk is not memory.
      return false
    case .recordingStarted, .fileImportStarted:
      // Load while the user speaks, or as the file starts, so the check is ready when the text is.
      return needsWordCheck
    case .takeSelection, .userRetry:
      // A take asking for the check now, or the user pressing Try again.
      return true
    }
  }
}
