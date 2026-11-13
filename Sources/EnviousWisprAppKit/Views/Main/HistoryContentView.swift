import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// The History page (#3147 §3.3): the app's banners, then the diary of the chosen tab. The
/// banners, the failed-action alert and the Paste notice stay here, outside the diary, so
/// switching tabs or opening an item never loses them.
struct HistoryContentView: View {
  @Environment(PermissionsService.self) private var permissions
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @Environment(MeetingCoordinator.self) private var meetings
  /// #3875, #4101: why a History Paste did not happen, shown once History is back in front. Held
  /// by this page, outside the diary and its items, so deleting the row or opening another one
  /// does not lose it.
  @State private var pasteNotice = HistoryPasteNotice()

  var body: some View {
    VStack(spacing: 0) {
      if permissions.shouldShowAccessibilityWarning {
        AccessibilityWarningBanner()
      }
      // #3438: beside the Accessibility banner, outside the diary; both can show.
      PolishSetupBanner()
      // #3147 C9: the one-time notice that saved dictations now keep a recording (upgrades only).
      RecordingDisclosureBanner()
      // #3147: recordings past the storage warning threshold; beside the other banners.
      RecordingStorageBanner()
      // #3972 R34: why the last meeting Start or recording needs attention, inside the app only.
      if let notice = meetings.notice {
        MeetingNoticeBanner(notice: notice)
          .padding(.horizontal, 12)
          .padding(.top, 8)
      }

      HistoryDiaryView(
        coordinator: transcriptCoordinator,
        dictationCard: { rowID in
          // Stand-in until the dictation card is wired at integration: the row's summary card.
          if let row = row(rowID, in: .dictations) {
            TranscriptRowView(transcript: row)
          }
        },
        transcriptDestination: { rowID in
          if let row = row(rowID, in: .transcripts) {
            TranscriptDetailView(transcript: row, showPasteNotice: pasteNotice.show)
              .id(rowID)
          }
        },
        meetingDestination: { meetingID in
          if let meeting = meeting(meetingID) {
            MeetingHistoryDetailView(meeting: meeting, showPasteNotice: pasteNotice.show)
              .id(meetingID)
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.stPageBg)
    .task {
      transcriptCoordinator.loadIfNeeded()
    }
    .alert(
      actionFailureTitle,
      isPresented: Binding(
        get: { transcriptCoordinator.actionFailure != nil },
        set: { if !$0 { transcriptCoordinator.dismissActionFailure() } })
    ) {
      Button(String(localized: "OK", comment: "History: closes the message about a failed action.")) {
        transcriptCoordinator.dismissActionFailure()
      }
    }
    .alert(
      pasteNotice.text ?? "",
      isPresented: Binding(
        get: { pasteNotice.text != nil }, set: { if !$0 { pasteNotice.dismiss() } })
    ) {
      Button(String(localized: "OK", comment: "History: closes the Paste message.")) {
        pasteNotice.dismiss()
      }
    }
  }

  /// The listed row `rowID` in `tab`, as the coordinator holds it now.
  private func row(_ rowID: UUID, in tab: HistoryTab) -> Transcript? {
    transcriptCoordinator.matchingHistoryItems(in: tab).first { $0.id == .transcript(rowID) }?.row
  }

  /// The listed meeting `meetingID`, as the coordinator holds it now.
  private func meeting(_ meetingID: UUID) -> HistoryMeetingItem? {
    for item in transcriptCoordinator.matchingHistoryItems(in: .meetings) {
      if case .meeting(let meeting) = item, meeting.meetingID == meetingID { return meeting }
    }
    return nil
  }

  /// #4075 G10: the sentence for the failed action. Empty when none is showing.
  private var actionFailureTitle: String {
    switch transcriptCoordinator.actionFailure {
    case .delete:
      String(
        localized: "Couldn't delete this item. Try again.",
        comment: "History: deleting one dictation or transcript failed; nothing was removed.")
    case .keep:
      String(
        localized: "Couldn't keep this recording. Try again.",
        comment:
          "History: Keep on a held Escape Recovery dictation failed; it still counts down.")
    case .deleteAll:
      String(
        localized: "Couldn't delete all history. Try again.",
        comment: "History: Delete All did not finish.")
    case nil:
      ""
    }
  }
}

/// #4101: History's Paste notice, owned by `HistoryContentView` for the life of the page. The
/// detail views get `show` as a callback; replacing a detail view does not touch it.
@MainActor
@Observable
final class HistoryPasteNotice {
  private(set) var text: String?

  func show(_ notice: String) { text = notice }

  func dismiss() { text = nil }
}
