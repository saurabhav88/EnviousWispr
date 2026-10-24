import EnviousWisprCore
import SwiftUI

/// The name field, Rename and status line of one meeting in History (#4001 step 2b-A). The
/// name draft lives HERE, so typing a name re-renders this header only, not the meeting's
/// transcript in `MeetingHistoryDetailView`. Present only in that view's record-backed branch;
/// the draft is seeded once when it appears, as the detail view did, never on a title update.
struct MeetingDetailHeader: View {
  let meetingID: UUID
  let record: MeetingRecord
  let audioSize: MeetingsPresentation.AudioSize

  @Environment(MeetingCoordinator.self) private var meetings
  @State private var titleDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        TextField(
          String(
            localized: "Meeting name", comment: "EnviousMeet: the rename field's placeholder."),
          text: $titleDraft
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { rename() }
        .disabled(!record.isWritableByThisBuild)
        .accessibilityIdentifier("meetings.detail.title")
        Button {
          rename()
        } label: {
          Text("Rename", comment: "EnviousMeet: saves the meeting's new name.")
        }
        .disabled(titleDraft == (record.title ?? "") || !record.isWritableByThisBuild)
      }
      let status = MeetingsPresentation.status(
        record, processingID: meetings.processing?.meetingID)
      Text(
        [
          MeetingsPresentation.statusLabel(status),
          MeetingsPresentation.duration(ms: record.recordedDurationMs),
          MeetingsPresentation.audioSizeLine(audioSize),
        ].joined(separator: " · ")
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      if let failure = MeetingsPresentation.failureLine(record) {
        Text(failure)
          .font(.stBody)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { titleDraft = record.title ?? "" }
  }

  private func rename() {
    let title = titleDraft
    Task { await meetings.rename(meetingID: meetingID, title: title) }
  }
}
