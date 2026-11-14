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
}
