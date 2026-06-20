#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// Issue #1100 — locks the DEBUG-only onboarding-notice override that lets the
  /// #1080 note be validated on a Mac where Apple Intelligence is available.
  /// `onboardingPolishNoticeForDisplay` honors `debugForcedNotice` in DEBUG and
  /// otherwise returns the real launch-report classification (the section's prior
  /// inline `latestReport?.onboardingPolishNotice` read).
  @MainActor
  @Suite("Onboarding polish notice debug override (#1100)")
  struct OnboardingPolishNoticeDebugOverrideTests {

    /// The UserDefaults key `AIAvailabilityCoordinator.init()` loads the cached
    /// report from (`loadCachedReport`). Cleared and restored so a dev machine's
    /// cached report cannot make `latestReport` non-nil and flake the
    /// `.useReal`/`.forceNone` assertions. Mirrors LaunchAvailabilitySnapshotTests.
    private static let cacheKey = "aiDiagnosticsLatestReport"

    @Test(
      "debugForcedNotice maps to the display notice; useReal falls through to the real report",
      .bug(
        "https://github.com/saurabhav88/EnviousWispr/issues/1100",
        "debug onboarding-notice override")
    )
    func overrideMapsToDisplayNotice() {
      let defaults = UserDefaults.standard
      let original = defaults.data(forKey: Self.cacheKey)
      defer {
        if let original {
          defaults.set(original, forKey: Self.cacheKey)
        } else {
          defaults.removeObject(forKey: Self.cacheKey)
        }
      }
      // Clean cache → the coordinator starts with `latestReport == nil`, so
      // `.useReal`/`.forceNone` must both yield nil (no real notice to show).
      defaults.removeObject(forKey: Self.cacheKey)
      let coordinator = AIAvailabilityCoordinator()

      coordinator.debugForcedNotice = .useReal
      #expect(coordinator.onboardingPolishNoticeForDisplay == nil)

      coordinator.debugForcedNotice = .forceNone
      #expect(coordinator.onboardingPolishNoticeForDisplay == nil)

      coordinator.debugForcedNotice = .enableInSettings
      #expect(coordinator.onboardingPolishNoticeForDisplay == .enableInSettings)

      coordinator.debugForcedNotice = .updateMacOS
      #expect(coordinator.onboardingPolishNoticeForDisplay == .updateMacOS)
    }
  }
#endif
