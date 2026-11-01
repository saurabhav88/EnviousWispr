import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4287: the meeting page's summary remedies lead to EnviousMeet's Summaries tab, and the
/// long-meeting advice follows the summary engine, not dictation's AI Polish.
///
/// When these fail, the user is sent to AI Polish to fix a summary (where changing the engine
/// now changes dictation instead), or sees advice that does not match their summary engine.
@MainActor
@Suite("Meeting summary navigation (#4287)", .tags(.productOutcome))
struct MeetingSummaryNavigationTests {
  private static func freshSettings() -> SettingsManager {
    SettingsManager(defaults: TestDefaults.suite("ew.tests.4287.nav.\(UUID().uuidString)")!)
  }

  @Test("the meeting page's settings link opens the Summaries tab")
  func linkOpensSummaries() {
    let navigation = NavigationCoordinator()
    MeetingSummarySettingsLink.open(navigation)
    #expect(navigation.pendingDestination == .meetings(.summaries))
  }

  @Test("the engine problems name the summary engine and its settings, never AI Polish")
  func messagesNameSummaryEngine() {
    for problem in [MeetingSummaryOwner.Problem.noProvider, .notForSummaries, .notReady] {
      let message = MeetingSummaryView.message(problem)
      #expect(!message.contains("AI Polish"), "\(problem)")
    }
    #expect(MeetingSummaryView.message(.noProvider).contains("summary engine"))
    #expect(MeetingSummaryView.message(.notReady).contains("Summaries settings"))
    #expect(MeetingSummaryView.message(.ollamaTooOld).contains("0.12.6"))
  }

  @Test("the long-meeting advice follows the summary engine, whatever dictation uses")
  func hintFollowsSummaryEngine() {
    let settings = Self.freshSettings()
    settings.llmProvider = .appleIntelligence
    settings.meetingSummaryLLMProvider = .openAI
    #expect(
      !MeetingSummaryLongMeetingHint.shows(
        writtenInParts: true, summaryProviderID: "appleIntelligence", settings: settings))

    settings.llmProvider = .openAI
    settings.meetingSummaryLLMProvider = .appleIntelligence
    #expect(
      MeetingSummaryLongMeetingHint.shows(
        writtenInParts: true, summaryProviderID: "appleIntelligence", settings: settings))
  }
}
