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
  /// The SHA-256 of the user's own summary awaiting the replace confirmation.
  @State private var confirmingReplace: String?

  var body: some View {
    if let record = meetings.record(id: meetingID) {
      // #3973 C2: a committed transcript keeps its summary shown while Transcribe again runs,
      // waits or fails.
      if record.committedTranscriptGeneration != nil {
        ready
      } else {
        unready(record)
      }
    }
  }

  @ViewBuilder private func unready(_ record: MeetingRecord) -> some View {
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

  @ViewBuilder private var ready: some View {
    let documents = meetings.documents
    let summaries = meetings.summaries
    let activity = summaries?.activity[meetingID]
    let writing = summaries?.isWriting(meetingID) ?? false
    let requesting = summaries?.requesting.contains(meetingID) ?? false
    // From the current setting, whatever any attempt did (R39): no provider, or one that
    // cannot summarize, is explained with the way to fix it.
    let configurationProblem = summaries?.configurationProblem()
    // #4148: a ready meeting with no summary and no visible transcript text has nothing a
    // model could summarize; say so instead of any attempt's progress or problem. Only once its
    // documents are read: before that (or after a failed read) the summary is unknown, and
    // Write summary stays the way to read them again.
    let nothingToSummarize =
      documents.loadState(meetingID) == .loaded && documents.summary(meetingID) == nil
      && summaries?.hasNothingToSummarize(meetingID) == true
    VStack(alignment: .leading, spacing: 10) {
      if !nothingToSummarize {
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
        case .failed, nil:
          if let shown = Self.shownProblem(
            activity: activity, configuration: configurationProblem)
          {
            problemView(shown)
          }
        }
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
        if MeetingSummaryLongMeetingHint.shows(
          writtenInParts: documents.manifest(meetingID)?.summary?.writtenInParts,
          summaryProviderID: documents.manifest(meetingID)?.summary?.inputs?.providerID,
          settings: settings)
        {
          MeetingSummaryLongMeetingHint()
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
        if documents.summarySaveFailed(meetingID) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(
              "Your summary changes could not be saved.",
              comment:
                "History, a meeting: saving the user's edits to the summary failed; the edits stay in the app until a save works."
            )
            .font(.stHelper)
            .foregroundStyle(.stError)
            .fixedSize(horizontal: false, vertical: true)
            Button {
              Task { await documents.flushSummary(meetingID) }
            } label: {
              Text("Try again", comment: "History, a meeting: saves the summary changes again.")
            }
            .buttonStyle(.link)
          }
          .accessibilityIdentifier("history.meeting.summarySaveFailed")
        }
      } else if nothingToSummarize {
        Text(
          "Nothing to summarize. No transcript text remains once probable echo is hidden.",
          comment:
            "History, a ready meeting's Summary tab: summaries always leave out probable echo (lines the microphone picked up from the call sound), and no other transcript text is left; this does not mean recording failed."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
        .accessibilityIdentifier("history.meeting.nothingToSummarize")
      } else if activity == nil, configurationProblem == nil {
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
        .disabled(writing || requesting || configurationProblem != nil || nothingToSummarize)
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
      isPresented: Binding(
        get: { confirmingReplace != nil }, set: { if !$0 { confirmingReplace = nil } })
    ) {
      Button(
        String(localized: "Replace", comment: "History, a meeting: replaces the edited summary."),
        role: .destructive
      ) {
        // Exactly the text the user confirmed: an edit made after this is kept.
        if let approved = confirmingReplace {
          meetings.summaries?.writeAgain(meetingID, replacing: approved)
        }
        confirmingReplace = nil
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

  /// One press: the owner reads and saves the documents first, then starts the attempt or asks
  /// before replacing the user's own text (`MeetingSummaryOwner.requestWrite`).
  private func write() {
    guard let summaries = meetings.summaries else { return }
    Task {
      if case .needsConfirmation(let approved) = await summaries.requestWrite(meetingID) {
        confirmingReplace = approved
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
      if Self.opensSummarySettings(problem) {
        MeetingSummarySettingsLink()
      }
    }
  }

  /// The problem the tab explains: the current setting first (an older failure is obsolete once
  /// the provider or model changed to one that cannot summarize), else the last failure.
  static func shownProblem(
    activity: MeetingSummaryOwner.Activity?, configuration: MeetingSummaryOwner.Problem?
  ) -> MeetingSummaryOwner.Problem? {
    if let configuration { return configuration }
    if case .failed(let problem) = activity { return problem }
    return nil
  }

  /// #4287: the problems the summary engine choice fixes, with a link to EnviousMeet's
  /// Summaries tab, where that engine is chosen.
  static func opensSummarySettings(_ problem: MeetingSummaryOwner.Problem) -> Bool {
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
        localized: "Choose a summary engine to write summaries.",
        comment: "History, a meeting: no summary engine is chosen on EnviousMeet's Summaries tab, so no summary.")
    case .notForSummaries:
      return String(
        localized: "This engine can't write summaries. Choose another one.",
        comment: "History, a meeting: the chosen summary engine or model (an EG-1 or S1-mini Ollama model) cannot summarize.")
    case .notReady:
      return String(
        localized:
          "The summary engine isn't ready. Check it in Summaries settings, then try again.",
        comment: "History, a meeting: the summary engine (Ollama not running, Apple Intelligence not available, no key) is not ready."
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
