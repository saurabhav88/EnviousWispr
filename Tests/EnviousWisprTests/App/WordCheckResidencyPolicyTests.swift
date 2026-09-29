import Testing

@testable import EnviousWisprAppKit

/// When the word check may be put in memory (#3289). When this fails, a Mac holds about 500 MB
/// with nobody dictating (Sentry ENVIOUSWISPR-5Y), or an Apple Intelligence user's dictation or
/// file goes unchecked because nothing loaded the check for it.
@Suite(
  "WordCheckResidencyPolicy: only work that will use the check loads it (#3289)",
  .tags(.productOutcome))
struct WordCheckResidencyPolicyTests {
  /// The expected answer for every trigger, written out by hand from the approved plan (#3289 §3.1)
  /// rather than derived from the policy. `nil` means "the answer is needsWordCheck".
  private static let expected: [WordCheckResidencyPolicy.Trigger: Bool?] = [
    .launch: false,
    .settingsChanged: false,
    .onboardingChanged: false,
    .parakeetAdmitted: false,
    .deliveryAdmitted: false,
    .appCancelFinished: false,
    .recordingStarted: nil,
    .fileImportStarted: nil,
    .takeSelection: true,
    .userRetry: true,
  ]

  @Test("the table names every trigger the policy knows")
  func tableIsComplete() {
    #expect(Set(Self.expected.keys) == Set(WordCheckResidencyPolicy.Trigger.allCases))
    #expect(WordCheckResidencyPolicy.Trigger.allCases.count == 10)
  }

  @Test(
    "each trigger loads exactly when the plan says, for both values of needsWordCheck",
    arguments: WordCheckResidencyPolicy.Trigger.allCases, [false, true])
  func decision(trigger: WordCheckResidencyPolicy.Trigger, needsWordCheck: Bool) throws {
    let rule = try #require(Self.expected[trigger])
    let want = rule ?? needsWordCheck
    #expect(
      WordCheckResidencyPolicy.shouldLoad(trigger, needsWordCheck: needsWordCheck) == want,
      "\(trigger) with needsWordCheck=\(needsWordCheck)")
  }

  @Test("log names stay the ones the app log has always used")
  func logNames() {
    #expect(WordCheckResidencyPolicy.Trigger.launch.rawValue == "launch")
    #expect(WordCheckResidencyPolicy.Trigger.settingsChanged.rawValue == "settings")
    #expect(WordCheckResidencyPolicy.Trigger.onboardingChanged.rawValue == "onboarding_changed")
    #expect(WordCheckResidencyPolicy.Trigger.parakeetAdmitted.rawValue == "parakeet_admitted")
    #expect(WordCheckResidencyPolicy.Trigger.appCancelFinished.rawValue == "app_cancel_finished")
    #expect(WordCheckResidencyPolicy.Trigger.takeSelection.rawValue == "take")
    #expect(WordCheckResidencyPolicy.Trigger.userRetry.rawValue == "settings_retry")
  }
}
