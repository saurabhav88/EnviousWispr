import EnviousWisprCore
import SwiftUI

/// A meeting's Notes tab (#3972 R38, R46): the user's own text, typed during or after the
/// meeting. The draft lives in `MeetingDocumentsOwner`, never in this view, so closing the view
/// loses nothing; it saves one second after the last change, and at once when the view closes.
struct MeetingNotesEditor: View {
  let meetingID: UUID
  @Environment(MeetingCoordinator.self) private var meetings

  var body: some View {
    let documents = meetings.documents
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(
        text: Binding(
          get: { documents.notes(meetingID) },
          set: { documents.setNotes(meetingID, $0) })
      )
      .font(.stBody)
      .scrollContentBackground(.hidden)
      .padding(8)
      .frame(minHeight: 240)
      .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .topLeading) {
        if documents.notes(meetingID).isEmpty {
          Text(
            "Type your notes.",
            comment: "History, a meeting: the empty Notes box's placeholder."
          )
          .font(.stBody)
          .foregroundStyle(.stTextTertiary)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
        }
      }
      .accessibilityLabel(Text("Notes", comment: "History, a meeting: the notes box."))
      if documents.loadState(meetingID) == .failed {
        Text(
          "Your saved notes could not be read. What you type is kept and saved when they can be read.",
          comment: "History, a meeting: the notes file could not be read."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .task(id: meetingID) { await documents.load(meetingID) }
    .onDisappear {
      let documents = documents
      let meetingID = meetingID
      Task { await documents.flush(meetingID) }
    }
  }
}
