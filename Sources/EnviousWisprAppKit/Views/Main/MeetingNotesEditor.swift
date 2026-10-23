import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// A meeting's Notes tab (#3972 R38, R46): the user's own text, typed during or after the
/// meeting. The draft lives in `MeetingDocumentsOwner`, never in this view, so closing the view
/// loses nothing; it saves one second after the last change, and at once when the view closes.
/// The box takes typing only once the saved notes are on screen (`canEdit`): while they load,
/// or when they could not be read, it shows that instead of an empty box.
struct MeetingNotesEditor: View {
  let meetingID: UUID
  @Environment(MeetingCoordinator.self) private var meetings

  var body: some View {
    let documents = meetings.documents
    let editable = documents.canEdit(meetingID)
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
      .disabled(!editable)
      .overlay(alignment: .topLeading) {
        if editable, documents.notes(meetingID).isEmpty {
          Text(
            "Type your notes.", comment: "History, a meeting: the empty Notes box's placeholder."
          )
          .font(.stBody)
          .foregroundStyle(.stTextTertiary)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
        }
      }
      .overlay {
        if documents.loadState(meetingID) == .loading
          || documents.loadState(meetingID) == .notLoaded
        {
          ProgressView().controlSize(.small)
        }
      }
      .accessibilityLabel(Text("Notes", comment: "History, a meeting: the notes box."))
      if editable, !documents.notes(meetingID).isEmpty {
        Button {
          PasteService.copyToClipboard(documents.notes(meetingID), kind: .kept)
        } label: {
          Label(
            String(localized: "Copy", comment: "EnviousMeet: copies the visible transcript."),
            systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("history.meeting.copyNotes")
      }
      if documents.loadState(meetingID) == .failed {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(
            "Your saved notes could not be read.",
            comment: "History, a meeting: the notes file could not be read."
          )
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            Task { await documents.load(meetingID) }
          } label: {
            Text("Try again", comment: "History, a meeting: reads the saved notes again.")
          }
          .buttonStyle(.link)
        }
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
