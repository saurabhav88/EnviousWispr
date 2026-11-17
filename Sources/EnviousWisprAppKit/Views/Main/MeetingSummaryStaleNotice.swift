import EnviousWisprCore
import SwiftUI

/// #4611: the notice above a meeting summary written from an older meeting. It says what
/// changed, offers Refresh summary (the same list of AI models as the More menu's "Write
/// summary again with") and Dismiss, which hides it for the meeting as it is now, saved with the
/// meeting; a newer change shows it again.
struct MeetingSummaryStaleNotice: View {
  let meetingID: UUID
  /// The More menu's summary items, built when the menu opens.
  let refreshItems: () -> [HistoryMenuItem]
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @State private var anchor = HistoryMenuAnchorHolder()

  var body: some View {
    // A new version being written or compared already answers the notice (#4611 D14); after a
    // failed attempt the notice and its buttons come back.
    if !Self.previewAnswers(meetings.summaries?.previews[meetingID]),
      let notice = meetings.summaries?.staleNotice(meetingID)
    {
      let documents = meetings.documents
      let message = Self.message(notice.cause)
      InsetNotice(verbatim: message.detail, title: message.title) {
        Button {
          guard let view = anchor.view else { return }
          historyMenu.toggle(items: refreshItems(), from: view)
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Refresh summary",
              comment:
                "History, a meeting: the out-of-date summary notice; opens the list of AI models to write the summary again."
            ),
            size: .medium, systemImage: "sparkles")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: true)
        .background(HistoryMenuAnchor(holder: anchor))
        .accessibilityIdentifier("history.meeting.summaryOutOfDate.refresh")
        if let clicked = notice.current {
          Button {
            // The meeting as the person saw it at the click: its notes draft and inputs.
            let notesAtClick = documents.notes(meetingID)
            Task {
              // Typed notes are saved first, so Dismiss records the meeting as it now is. Any
              // change after the click (newer notes, or anything else) cancels the dismissal.
              _ = await documents.flush(meetingID)
              guard !documents.hasUnsavedNotes(meetingID),
                MeetingDocumentHash.sameBytes(documents.notes(meetingID), notesAtClick),
                let fresh = meetings.summaries?.staleNotice(meetingID)?.current,
                Self.sameExceptNotesRevision(fresh, clicked)
              else { return }
              await documents.dismissSummaryNotice(meetingID, for: fresh)
            }
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Dismiss",
                comment:
                  "History, a meeting: hides the out-of-date summary notice until the meeting changes again."
              ),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
          .accessibilityIdentifier("history.meeting.summaryOutOfDate.dismiss")
        }
      }
      .accessibilityIdentifier("history.meeting.summaryOutOfDate")
    }
  }

  /// The click's inputs and the inputs after saving the typed notes differ at most in the
  /// notes revision that save made.
  static func sameExceptNotesRevision(_ a: SummaryInputs, _ b: SummaryInputs) -> Bool {
    var b = b
    b.notesRevision = a.notesRevision
    return a == b
  }

  private static func previewAnswers(_ preview: MeetingSummaryOwner.Preview?) -> Bool {
    switch preview {
    case .generating?, .comparing?: true
    case .failed?, nil: false
    }
  }

  /// The notice's two lines: what changed (reading colour), then what Refresh does.
  static func message(_ cause: MeetingSummaryOwner.StaleCause) -> (title: String, detail: String) {
    switch cause {
    case .notes:
      (
        String(
          localized: "Your notes changed after this summary was written.",
          comment: "History, a meeting: the user's notes changed after the AI summary was written."),
        String(
          localized: "Refresh the summary to include your changes.",
          comment: "History, a meeting: under the notes-changed line; what Refresh summary does.")
      )
    case .transcript:
      (
        String(
          localized: "The transcript changed after this summary was written.",
          comment:
            "History, a meeting: the transcript changed (Transcribe again, or an edit) after the AI summary was written."),
        String(
          localized: "Refresh the summary to match it.",
          comment: "History, a meeting: under the transcript-changed line; what Refresh summary does.")
      )
    case .speakerNames:
      (
        String(
          localized: "Speaker names changed after this summary was written.",
          comment: "History, a meeting: a speaker was renamed after the AI summary was written."),
        String(
          localized: "Refresh the summary to use the new names.",
          comment: "History, a meeting: under the speaker-names line; what Refresh summary does.")
      )
    case .meetingDetails:
      (
        String(
          localized: "Meeting details changed after this summary was written.",
          comment:
            "History, a meeting: the meeting's details (such as calendar facts) changed after the AI summary was written."),
        String(
          localized: "Refresh the summary to include them.",
          comment: "History, a meeting: under the meeting-details line; what Refresh summary does.")
      )
    case .summarySetup:
      (
        String(
          localized: "This summary was written with an older summary setup.",
          comment:
            "History, a meeting: the summary engine or model in Settings, the model's version or the app's summary instructions (after an app update) changed after the AI summary was written."),
        String(
          localized: "Refresh the summary to use the current one.",
          comment: "History, a meeting: under the older-setup line; what Refresh summary does.")
      )
    case .several:
      (
        String(
          localized: "This meeting changed after this summary was written.",
          comment:
            "History, a meeting: more than one thing (notes, transcript, names, settings) changed after the AI summary was written."),
        String(
          localized: "Refresh the summary to bring it up to date.",
          comment: "History, a meeting: under the meeting-changed line; what Refresh summary does.")
      )
    }
  }
}

/// An outlined button that opens the summary's AI model list (the More menu's "Write summary
/// again with") under itself, through the app's own History menu.
struct MeetingSummaryModelMenuButton: View {
  let title: LocalizedStringResource
  let items: () -> [HistoryMenuItem]
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @State private var anchor = HistoryMenuAnchorHolder()

  var body: some View {
    Button {
      guard let view = anchor.view else { return }
      historyMenu.toggle(items: items(), from: view)
    } label: {
      EnviousButtonLabel(title, size: .medium, systemImage: "sparkles")
    }
    .settingsButton(.outlined, size: .medium, isEnabled: true)
    .background(HistoryMenuAnchor(holder: anchor))
  }
}
