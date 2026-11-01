import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Advice above a summary Apple Intelligence wrote in parts (#4044).
/// Names the larger planning windows of the three cloud defaults.
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
        "Long meeting: this summary was written in parts. The default OpenAI, Gemini and Claude models fit much longer meetings in one piece.",
        comment:
          "History, a meeting summarized in parts by Apple Intelligence. Explains that the default models of the three named providers support much longer meetings in a single summary call. This does not promise unlimited meeting length."
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
