import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Advice above a summary Apple Intelligence wrote in parts (#4044).
/// Says some cloud models plan in a much larger window. #4353 D2: there are no cloud defaults to
/// name, so it claims only "some", bound to known examples in `MeetingSummaryTests`.
/// It only informs; nothing switches by itself.
struct MeetingSummaryLongMeetingHint: View {
  /// Shown only for a summary saved as written in parts by Apple Intelligence while the summary
  /// engine (#4287: EnviousMeet's own choice, not dictation's AI Polish) is still Apple
  /// Intelligence. A summary without the record (written before #4044, or by the user) never
  /// shows it.
  static func shows(
    writtenInParts: Bool?, summaryProviderID: String?, settings: SettingsManager
  ) -> Bool {
    shows(
      writtenInParts: writtenInParts, summaryProviderID: summaryProviderID,
      currentProvider: settings.effectiveMeetingSummaryLLMProvider)
  }

  static func shows(
    writtenInParts: Bool?, summaryProviderID: String?, currentProvider: LLMProvider
  ) -> Bool {
    writtenInParts == true
      && summaryProviderID == LLMProvider.appleIntelligence.rawValue
      && currentProvider == .appleIntelligence
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        "Long meeting: this summary was written in parts. Some cloud models can fit longer meetings in one piece.",
        comment:
          "History, a meeting summarized in parts by Apple Intelligence. Explains that some cloud AI models (OpenAI, Gemini, Claude) can summarize longer meetings in a single pass. Says some, not all, and does not promise unlimited meeting length."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("history.meeting.summaryLongMeeting")

      MeetingSummarySettingsLink()
    }
  }
}

/// #4287: opens EnviousMeet's Summaries tab, where the summary engine is chosen.
struct MeetingSummarySettingsLink: View {
  @Environment(NavigationCoordinator.self) private var navigation

  /// The link's action, for tests: the one destination it requests.
  static func open(_ navigation: NavigationCoordinator) {
    navigation.request(.meetings(.summaries))
  }

  var body: some View {
    Button {
      Self.open(navigation)
    } label: {
      Text(
        "Open Summaries settings",
        comment: "History, a meeting: opens EnviousMeet's Summaries settings to choose or fix the summary engine."
      )
    }
    .buttonStyle(.link)
  }
}

/// #4353 D9: opens EnviousMeet's Summaries tab with the summary engine's model menu open, for a
/// summary that found no cloud model or a model that no longer works. It changes no setting and
/// writes nothing; the person picks a model, then Write again.
struct MeetingSummaryModelMenuLink: View {
  @Environment(NavigationCoordinator.self) private var navigation

  /// The link's action, for tests: the destination, then the summary card's model menu.
  static func open(_ navigation: NavigationCoordinator) {
    navigation.request(.meetings(.summaries))
    navigation.requestModelMenu(on: .meetingSummary)
  }

  var body: some View {
    Button(PolishSetupSurfaceCopy.selectNewCloudModel) {
      Self.open(navigation)
    }
    .buttonStyle(.link)
    .accessibilityIdentifier("history.meeting.summarySelectModel")
  }
}
