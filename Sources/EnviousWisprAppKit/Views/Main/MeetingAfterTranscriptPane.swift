import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// A meeting page's transcript pane (#4586 N6): the committed transcript or what the meeting is
/// doing instead, the Show probable echo toggle, the missing-Accessibility note, and the speaker
/// roster behind Rename speaker's suggestions. The roster is this pane's alone, so its read lives
/// here and runs only while the pane is on screen (`loadsRoster`). Layout, scrolling, Follow
/// playback and View source stay with the page.
struct MeetingAfterTranscriptPane: View {
  let meetingID: UUID
  let record: MeetingRecord
  let row: Transcript?
  let projection: MeetingHistoryPresentation.Projection?
  /// The player when it can play.
  let player: MeetingPlaybackController?
  let highlightedTurnID: String?
  /// Nil while Follow playback is off.
  let activeTurnID: String?
  let mode: FileImportCoordinator.DocumentView
  let timesOn: Bool
  let didReadTranscript: Bool
  /// Transcribe again is offered now (and no page action is running).
  let canTranscribeAgain: Bool
  /// False while recording and while the narrow layout hides the transcript behind Your notes.
  let loadsRoster: Bool

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  @State private var rosterRead: KeyedRosterRead<RosterKey>?

  struct RosterKey: Hashable {
    let meetingID: UUID
    let audioKept: Bool
    let deletionRequested: Bool
    let state: MeetingState
  }

  private var rosterKey: RosterKey {
    RosterKey(
      meetingID: meetingID, audioKept: record.audioKept,
      deletionRequested: record.deletionRequested, state: record.state)
  }

  var body: some View {
    transcriptColumn(record, row: row, projection: projection)
      .task(id: loadsRoster ? rosterKey : nil) {
        guard loadsRoster else {
          rosterRead = nil
          return
        }
        // Stored with the request it answers; shown only while that is still the request.
        let key = rosterKey
        let read = await meetings.callSpeakerEvidence(meetingID: meetingID)
        guard !Task.isCancelled else { return }
        rosterRead = KeyedRosterRead(key: key, evidence: read)
      }
  }

  @ViewBuilder
  private func transcriptColumn(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      transcriptState(record, row: row)
      if let row, let projection {
        if transcripts.meetingHasProbableEcho(row) { transcriptToolbar(row) }
        if rosterRead?.permissionMissing(for: rosterKey) == true {
          speakerNamesPermissionNote
        }
        switch projection {
        case .visible(let turns, _):
          MeetingAfterTurnList(
            rowID: row.id, turns: turns, rawText: row.text,
            speakerNames: row.speakerNames ?? [:], player: player,
            renameSuggestions: SpeakerRenameSuggestions(
              row: row, roster: rosterRead?.roster(for: rosterKey)),
            highlightedTurnID: highlightedTurnID,
            activeTurnID: activeTurnID,
            language: row.language, mode: mode, timesOn: timesOn
          )
          .equatable()
          .font(.stCardText)
        case .everythingHidden:
          Text(MeetingHistoryPresentation.everythingHiddenMessage)
            .font(.stBody)
            .foregroundStyle(.stTextSecondary)
        case .unavailable:
          Text(MeetingHistoryPresentation.unavailableMessage)
            .font(.stBody)
            .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }

  /// What the meeting is doing now when it has no committed transcript to show, or why the
  /// committed one is not there (legacy `transcriptTab`).
  @ViewBuilder
  private func transcriptState(_ record: MeetingRecord, row: Transcript?) -> some View {
    switch meetings.phase {
    case .recording(let id, _) where id == meetingID:
      MeetingBusyLine(text: String(localized: "Live transcript"))
    case .stopping(let id) where id == meetingID:
      supersededLiveWords()
    default:
      let committed = record.committedTranscriptGeneration != nil
      if committed, row != nil {
        EmptyView()
      } else if committed, !didReadTranscript {
        MeetingBusyLine(text: 
          String(
            localized: "Loading the transcript",
            comment: "History, a ready meeting: waiting for History's first read attempt to finish."
          ))
      } else if committed {
        // #4001 H12: committed, History has been read, and the row is still not there.
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          Text(
            "This meeting's transcript could not be opened.",
            comment: "History, a ready meeting whose saved transcript is missing or unreadable."
          )
          .font(.stBody)
          .foregroundStyle(.stTextPrimary)
          if canTranscribeAgain {
            Text(
              "Choose Transcribe again to make it from the recording.",
              comment:
                "History, a ready meeting whose transcript could not be opened: the way back."
            )
            .font(.stBody)
            .foregroundStyle(.stTextSecondary)
          }
        }
        .accessibilityElement(children: .combine)
      } else if record.state == .notesOnly {
        Text(
          "Nothing was recorded for this meeting, so it has no transcript.",
          comment: "History meeting: the transcript pane of a meeting that recorded nothing."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      } else {
        // #3973: processing, queued or failed: the live words stay until a transcript is ready.
        supersededLiveWords()
      }
    }
  }

  @ViewBuilder
  private func supersededLiveWords() -> some View {
    if let live = meetings.liveTranscript, live.meetingID == meetingID {
      MeetingLiveWordsView(transcript: live, superseded: true)
    }
  }

  /// Show probable echo; Timestamps and Follow playback are in the transcript's settings button
  /// (#4611 D3), Return to playback floats over the transcript (D13).
  private func transcriptToolbar(_ row: Transcript) -> some View {
    WrappingHStack(spacing: DesignSpacing.lg) {
      // #3973 C2: the shown row's own generation decides.
      if transcripts.meetingHasProbableEcho(row) {
        Toggle(
          isOn: Binding(
            get: { transcripts.isShowingEcho(rowID: row.id) },
            set: { transcripts.setShowEcho($0, rowID: row.id) })
        ) {
          Text(
            "Show probable echo",
            comment:
              "History, a meeting: shows the lines hidden because they repeat the call sound picked up by the microphone."
          )
          .font(.stRowLabel)
        }
        .toggleStyle(BrandedToggleStyle(onColor: .stAccentSolid))
        .fixedSize()
      }
    }
  }

  /// #4013: this meeting recorded without Accessibility, so it has no speaker names to offer.
  private var speakerNamesPermissionNote: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      Text(MeetingHistoryPresentation.speakerNamesPermissionMessage)
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        navigation.request(.meetings(.permissions))
        appWindowCoordinator.showWindow()
      } label: {
        EnviousButtonLabel(
          verbatim: MeetingHistoryPresentation.speakerNamesPermissionButton,
          size: .medium)
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)
    }
  }
}

/// A small spinner and a line saying what is still happening.
struct MeetingBusyLine: View {
  let text: String

  var body: some View {
    HStack(spacing: DesignSpacing.sm) {
      ProgressView().controlSize(.small)
      Text(verbatim: text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}
