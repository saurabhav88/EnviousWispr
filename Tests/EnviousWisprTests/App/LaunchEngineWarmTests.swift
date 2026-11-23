import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4528: launch warms the selected speech engine only after first-run Setup.
///
/// **Product Outcome.** When this fails, a first launch downloads the Parakeet model before the
/// person chooses an engine in Setup (a person who picks Whisper gets an unasked-for download),
/// or a set-up Mac stops warming its engine at launch and the first dictation starts cold.
@Suite(.tags(.productOutcome))
struct LaunchEngineWarmTests {
  @Test("launch warms Parakeet only once Setup is complete")
  func warmFollowsSetupCompletion() {
    let states: [OnboardingState] = [.notStarted, .settingUp, .needsPermissions, .completed]
    for state in states {
      #expect(
        LaunchEngineWarm.allowed(selectedBackend: .parakeet, onboardingState: state)
          == (state == .completed), "\(state)")
    }
    #expect(!LaunchEngineWarm.allowed(selectedBackend: .whisper, onboardingState: .completed))
  }

  /// #4837: a Parakeet download that finishes while the app runs loads the engine, but never
  /// during Setup and never for a person on Whisper.
  @Test("an admitted download loads Parakeet only after Setup, with Parakeet selected and active")
  func downloadWarmNeedsSetupDoneAndParakeetActive() {
    let states: [OnboardingState] = [.notStarted, .settingUp, .needsPermissions, .completed]
    for state in states {
      #expect(
        LaunchEngineWarm.allowedAfterDownload(
          selectedBackend: .parakeet, activeBackend: .parakeet, onboardingState: state)
          == (state == .completed), "\(state)")
    }
    #expect(
      !LaunchEngineWarm.allowedAfterDownload(
        selectedBackend: .whisper, activeBackend: .parakeet, onboardingState: .completed))
    #expect(
      !LaunchEngineWarm.allowedAfterDownload(
        selectedBackend: .parakeet, activeBackend: .whisper, onboardingState: .completed))
  }
}
