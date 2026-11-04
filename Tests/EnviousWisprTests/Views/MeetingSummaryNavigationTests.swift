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

  // MARK: - #4353 D9

  @Test("#4353 Select a new cloud model opens the Summaries tab with the summary model menu")
  func modelMenuLinkOpensTheSummaryMenu() {
    let navigation = NavigationCoordinator()
    MeetingSummaryModelMenuLink.open(navigation)
    #expect(navigation.pendingDestination == .meetings(.summaries))
    #expect(navigation.pendingModelMenu?.surface == .meetingSummary)

    let plain = NavigationCoordinator()
    MeetingSummarySettingsLink.open(plain)
    #expect(plain.pendingDestination == .meetings(.summaries))
    #expect(plain.pendingModelMenu == nil, "the ordinary settings link opens no menu")
  }

  @Test("#4353 the cloud model problems name the provider or the attempted model and offer the menu")
  func cloudModelProblems() {
    let none = MeetingSummaryOwner.Problem.cloudNoModel(.gemini)
    let gone = MeetingSummaryOwner.Problem.cloudModelUnavailable(.openAI, "gpt-x")
    #expect(MeetingSummaryView.message(none) == "Choose a model for Gemini.")
    #expect(MeetingSummaryView.message(gone) == "gpt-x no longer works. Select a new cloud model.")
    for problem in [none, gone] {
      #expect(MeetingSummaryView.opensSummaryModelMenu(problem))
      #expect(MeetingSummaryView.opensSummarySettings(problem) == false)
    }
    for problem in [MeetingSummaryOwner.Problem.noProvider, .notReady, .providerFailed] {
      #expect(MeetingSummaryView.opensSummaryModelMenu(problem) == false)
    }
  }

  @Test("#4353 the setting comes first; an obsolete no-model failure hides; a gone model stays named")
  func cloudProblemPrecedence() {
    let gone = MeetingSummaryOwner.Problem.cloudModelUnavailable(.openAI, "gpt-x")
    #expect(
      MeetingSummaryView.shownProblem(activity: .failed(gone), configuration: .cloudNoModel(.claude))
        == .cloudNoModel(.claude))
    #expect(
      MeetingSummaryView.shownProblem(activity: .failed(.cloudNoModel(.openAI)), configuration: nil)
        == nil)
    #expect(MeetingSummaryView.shownProblem(activity: .failed(gone), configuration: nil) == gone)
  }
}
