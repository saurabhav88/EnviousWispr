import EnviousWisprCore
import SwiftUI

/// A meeting's title, renamed in place on the Meetings card and the after-view header
/// (#3147 PR4A, plan §3.6). The editing itself is `HistoryInlineTitle`, shared with imported
/// transcripts (#4611); this wrapper supplies the record's title and its one rename owner,
/// `MeetingCoordinator.rename(meetingID:title:)`, which trims, caps at 120 characters and
/// waits for commit settlement. A row whose meeting folder is gone shows nothing here.
struct MeetingInlineTitle: View {
  let meetingID: UUID
  var font: Font = .stRowTitle
  /// Set to true by the owner (Rename in More) to open the field; reset by the shared title.
  var beginRequest: Binding<Bool> = .constant(false)
  var searchQuery = ""

  @Environment(MeetingCoordinator.self) private var meetings

  private typealias P = MeetingAfterPresentation

  var body: some View {
    if let record = meetings.record(id: meetingID) {
      let card = P.card(P.CardInputs(record: record))
      HistoryInlineTitle(
        identity: meetingID, title: card.title, canRename: card.canRename,
        renameHelp: P.renameHelp,
        fieldLabel: String(
          localized: "Meeting name", comment: "EnviousMeet: the rename field's placeholder."),
        storedTitle: { [meetings, meetingID] in meetings.record(id: meetingID)?.title },
        rename: { [meetings, meetingID] title in
          await meetings.rename(meetingID: meetingID, title: title)
        },
        font: font, beginRequest: beginRequest, searchQuery: searchQuery)
    }
  }
}
