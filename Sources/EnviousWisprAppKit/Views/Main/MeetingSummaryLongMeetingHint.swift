import EnviousWisprCore
import SwiftUI

/// Advice above a summary Apple Intelligence wrote in parts (#4044).
/// Names the larger planning windows of the three cloud defaults.
/// It only informs; nothing switches by itself.
struct MeetingSummaryLongMeetingHint: View {
  /// Shown only for a summary saved as written in parts by Apple Intelligence while AI Polish
  /// is still on Apple Intelligence. A summary without the record (written before #4044, or
  /// by the user) never shows it.
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
        "Long meeting: this summary was written in parts. The default OpenAI, Gemini and Claude models fit much longer meetings in one piece. AI Polish also uses that choice for dictation.",
        comment:
          "History, a meeting summarized in parts by Apple Intelligence. Explains that the default models of the three named providers support much longer meetings in a single summary call. The AI Polish provider and model choice also applies to dictation. This does not promise unlimited meeting length."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("history.meeting.summaryLongMeeting")

      AIPolishSettingsLink()
    }
  }
}

/// Opens AI Polish settings, where the summary provider is chosen.
struct AIPolishSettingsLink: View {
  @Environment(NavigationCoordinator.self) private var navigation

  var body: some View {
    Button {
      navigation.request(.aiPolish)
    } label: {
      Text(
        "Open AI Polish settings",
        comment: "History, a meeting: opens the AI Polish settings to fix the summary provider."
      )
    }
    .buttonStyle(.link)
  }
}
