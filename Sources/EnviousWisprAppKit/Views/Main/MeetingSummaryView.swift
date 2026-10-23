import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// A meeting's Summary tab (#3972 R39, R46, R60). The summary is written by the user's AI Polish
/// provider when the meeting is ready (`MeetingSummaryOwner`); the user may edit it, and an
/// edited summary is the user's own text, which Write again replaces only after the user
/// confirms. A summary written from inputs that differ from the meeting now is always shown as
/// out of date, never as current. The text lives in `MeetingDocumentsOwner`, never in this
/// view, and is saved one second after the last change and when the view closes.
struct MeetingSummaryView: View {
  let meetingID: UUID
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigation
  @State private var confirmingReplace = false

  var body: some View {
    if let record = meetings.record(id: meetingID) {
      switch record.state {
      case .ready: ready
      case .notesOnly, .failed:
        Text(
          "This meeting has no transcript, so it has no summary.",
          comment: "History, a meeting with no transcript: its Summary tab."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      case .recording, .stopping, .interrupted, .queued, .processing:
        Text(
          "A summary is written after the meeting is transcribed.",
          comment: "History, a meeting: the Summary tab before a summary exists."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      }
    }
  }

  @ViewBuilder private var ready: some View {
    let documents = meetings.documents
    let summaries = meetings.summaries
    let activity = summaries?.activity[meetingID]
    let writing = summaries?.isWriting(meetingID) ?? false
    VStack(alignment: .leading, spacing: 10) {
      switch activity {
      case .waiting:
        busy(
          String(
            localized: "Waiting for your dictation and other meeting work to finish.",
            comment: "History, a meeting: the summary waits before a model on this Mac is used."))
      case .writing:
        busy(
          String(
            localized: "Writing the summary.",
            comment: "History, a meeting: the summary is being written."))
      case .failed(let problem):
        problemView(problem)
      case nil:
        EmptyView()
      }

      if let text = documents.summary(meetingID) {
        if summaries?.isOutOfDate(meetingID) == true {
          Text(
            "The meeting changed after this summary was written. It may be out of date.",
            comment:
              "History, a meeting: the summary was written from an older transcript, names or notes."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history.meeting.summaryOutOfDate")
        }
        TextEditor(
          text: Binding(
            get: { documents.summary(meetingID) ?? text },
            set: { documents.setSummary(meetingID, $0) })
        )
        .font(.stBody)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 240)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
        .disabled(!documents.canEdit(meetingID))
        .accessibilityLabel(Text("Summary", comment: "History, a meeting: the summary box."))
        .accessibilityIdentifier("history.meeting.summary")
      } else if activity == nil {
        Text(
          settings.meetingWriteSummary
            ? String(
              localized: "No summary yet.",
              comment: "History, a meeting: it has no summary and none is being written.")
            : String(
              localized: "Summaries are off. You can still write one for this meeting.",
              comment: "History, a meeting: automatic summaries are turned off in settings."),
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      }

      HStack(spacing: 10) {
        Button {
          write()
        } label: {
          Text(
            documents.summary(meetingID) == nil
              ? String(
                localized: "Write summary", comment: "History, a meeting: writes its summary.")
              : String(
                localized: "Write again", comment: "History, a meeting: writes its summary again."))
        }
        .disabled(writing || settings.llmProvider == .none)
        .accessibilityIdentifier("history.meeting.writeSummary")
        if let text = documents.summary(meetingID), !text.isEmpty {
          Button {
            PasteService.copyToClipboard(text, kind: .kept)
          } label: {
            Label(
              String(localized: "Copy", comment: "EnviousMeet: copies the visible transcript."),
              systemImage: "doc.on.doc")
          }
          .accessibilityIdentifier("history.meeting.copySummary")
        }
      }
    }
    .task(id: meetingID) { await documents.load(meetingID) }
    .onDisappear {
      let documents = documents
      let meetingID = meetingID
      Task { await documents.flushSummary(meetingID) }
    }
    .alert(
      Text(
        "Replace your edited summary?",
        comment: "History, a meeting: confirms writing the summary again over the user's edits."),
      isPresented: $confirmingReplace
    ) {
      Button(
        String(localized: "Replace", comment: "History, a meeting: replaces the edited summary."),
        role: .destructive
      ) {
        meetings.summaries?.writeAgain(
          meetingID, replacing: documents.manifest(meetingID)?.summary?.sha256)
      }
      Button(
        String(localized: "Cancel", comment: "History, a meeting: keeps the edited summary."),
        role: .cancel
      ) {}
    } message: {
      Text(
        "You changed this summary. Writing it again replaces your changes.",
        comment: "History, a meeting: explains what Replace does to the edited summary.")
    }
  }

  /// Saves any typing first, then asks before replacing the user's own text.
  private func write() {
    let documents = meetings.documents
    Task {
      await documents.flushSummary(meetingID)
      if documents.manifest(meetingID)?.summary?.origin == .userEdited {
        confirmingReplace = true
      } else {
        meetings.summaries?.writeAgain(meetingID, replacing: nil)
      }
    }
  }

  @ViewBuilder private func problemView(_ problem: MeetingSummaryOwner.Problem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(Self.message(problem))
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("history.meeting.summaryProblem")
      if Self.opensAIPolish(problem) {
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
  }

  static func opensAIPolish(_ problem: MeetingSummaryOwner.Problem) -> Bool {
    switch problem {
    case .noProvider, .notForSummaries, .notReady, .ollamaTooOld: return true
    case .tooLong, .providerFailed, .notesUnreadable, .storageFailed: return false
    }
  }

  /// What went wrong, in the user's words; enumerated, so a new problem must be explained here.
  static func message(_ problem: MeetingSummaryOwner.Problem) -> String {
    switch problem {
    case .noProvider:
      return String(
        localized: "Choose an AI Polish provider to write summaries.",
        comment: "History, a meeting: no AI Polish provider is selected, so no summary.")
    case .notForSummaries:
      return String(
        localized: "The selected AI Polish model can't write summaries. Choose another model.",
        comment: "History, a meeting: the cleanup models (EG-1, S1-mini) cannot summarize.")
    case .notReady:
      return String(
        localized:
          "The AI Polish provider isn't ready. Check it in AI Polish settings, then try again.",
        comment: "History, a meeting: Ollama is not running or Apple Intelligence is not available."
      )
    case .ollamaTooOld:
      return String(
        localized: "Update Ollama to version 0.12.6 or later to write summaries with it.",
        comment: "History, a meeting: the Ollama app is too old for meeting summaries.")
    case .tooLong:
      return String(
        localized: "This meeting is too long for the selected model to summarize.",
        comment: "History, a meeting: the meeting needs more calls than a summary may make.")
    case .providerFailed:
      return String(
        localized: "The summary could not be written. Try again.",
        comment: "History, a meeting: the provider failed, timed out or answered with nothing.")
    case .notesUnreadable:
      return String(
        localized: "Your notes could not be read, so no summary was written.",
        comment: "History, a meeting: the notes file could not be read before the summary.")
    case .storageFailed:
      return String(
        localized: "The summary could not be saved. Try again.",
        comment: "History, a meeting: the meeting's files could not be written.")
    }
  }

  private func busy(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}
