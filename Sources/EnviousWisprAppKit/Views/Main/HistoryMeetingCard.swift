import EnviousWisprCore
import SwiftUI

/// One meeting in the Meetings tab (#3147 PR4A, plan §3.6, approved mock Meetings.dc.html): the
/// start time and call app, the renamable title, who spoke, Open, a status chip while the
/// meeting is not ready, one preview line (the summary's first line, else the visible
/// transcript, else what is happening to it), and the quiet facts (speech engine, who wrote the
/// summary, a recording that was deleted).
///
/// **It keeps every state of the legacy `MeetingRowView`**: recording, saving, waiting (and
/// waiting for disk space), interrupted, transcribing, needs attention with its failure reason,
/// notes only, ready, and a row whose meeting folder is gone. The preview is
/// `TranscriptCoordinator.meetingPreviewText`, so hidden echo never reaches it (R19), and a
/// committed transcript keeps its preview while Transcribe again runs, waits or fails.
///
/// **Open and the title's rename controls are sibling buttons**, never one inside the other, so
/// each keeps its own keyboard focus and VoiceOver action. The card itself is not a button.
/// While History is selecting, the diary draws this card with hit testing off inside its
/// tick button (as it does for `HistoryTranscriptCard`).
///
struct HistoryMeetingCard: View {
  let meetingID: UUID
  let onOpen: () -> Void
  let allowsPlayback: Bool

  init(meetingID: UUID, onOpen: @escaping () -> Void, allowsPlayback: Bool = true) {
    self.meetingID = meetingID
    self.onOpen = onOpen
    self.allowsPlayback = allowsPlayback
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(MeetingCoordinator.self) private var meetings
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: MeetingPlaybackSource?

  private typealias P = MeetingAfterPresentation

  var body: some View {
    let record = meetings.record(id: meetingID)
    let row = meetingRow(record)
    let source = allowsPlayback ? meetings.playbackSource(meetingID: meetingID) : nil
    if record != nil || row != nil {
      card(P.card(inputs(record: record, row: row)), source: source)
        .onChange(of: source) { _, _ in dropPlayer() }
        .onDisappear(perform: dropPlayer)
    }
  }

  /// The History row this card previews: the meeting's committed row when EnviousMeet holds it,
  /// else the row that still names the meeting (an orphan, listed as History lists it).
  private func meetingRow(_ record: MeetingRecord?) -> Transcript? {
    if let record { return transcripts.currentRow(id: record.transcriptID) }
    return transcripts.rowIDs(ofMeeting: meetingID).compactMap(transcripts.currentRow(id:)).last
  }

  private func inputs(record: MeetingRecord?, row: Transcript?) -> P.CardInputs {
    let documents = meetings.documents
    // A meeting being deleted shows no words of it (Codex C8 r2).
    let shown = record?.deletionRequested != true
    return P.CardInputs(
      record: record, row: row, processingID: meetings.processing?.meetingID,
      queueWaitsForSpace: meetings.queueWaitsForSpace,
      previewText: shown ? row.map(transcripts.meetingPreviewText(of:)) : nil,
      summary: shown ? documents.summary(meetingID) : nil,
      summaryProviderID: documents.manifest(meetingID)?.summary?.inputs?.providerID)
  }

  private func card(_ card: P.Card, source: MeetingPlaybackSource?) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack(alignment: .top, spacing: DesignSpacing.lg) {
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
          // The rename controls sit beside Open, never inside it. A row whose meeting folder is
          // gone has no record to rename, so it shows its name only.
          if card.canRename {
            MeetingInlineTitle(meetingID: meetingID)
          } else {
            Text(verbatim: card.title)
              .font(.stRowTitle)
              .foregroundStyle(.stTextPrimary)
              .lineLimit(1)
          }
          if let people = card.speakers {
            Label {
              Text(verbatim: people)
            } icon: {
              Image(systemName: "person.2").accessibilityHidden(true)
            }
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
          }
          if let length = card.length {
            Text(verbatim: length)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let status = card.status {
          statusChip(status)
        }
        Button(action: onOpen) {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Open", comment: "History meeting card: opens the meeting."),
            size: .medium, trailingSystemImage: "chevron.right")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: true)
        .accessibilityLabel(
          Text(
            "Open \(card.title)",
            comment: "History meeting card: VoiceOver label of Open. %@ is the meeting's name."))
      }
      if let source, source.durationMs > 0 {
        if let player, playerSource == source {
          MeetingPlaybackControls(player: player, showsWaveform: false)
            .id(ObjectIdentifier(player))
        } else {
          Button {
            beginPlayback(source)
          } label: {
            EnviousButtonLabel(
              verbatim: HistoryTranscriptPresentation.playLabel(.play),
              size: .medium, systemImage: HistoryTranscriptPresentation.playSymbol(.play))
          }
          .settingsButton(.filled, size: .medium, isEnabled: true)
        }
      }
      line(card.line)
      if let attention = card.attentionLine {
        line(.status(attention, .error))
      }
      if let audio = card.audioLine {
        Label {
          Text(verbatim: audio)
        } icon: {
          Image(systemName: "waveform.slash").accessibilityHidden(true)
        }
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
      if !card.footer.isEmpty {
        Text(verbatim: card.footer.joined(separator: " · "))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .lineLimit(1)
      }
    }
    .historyRowCard(isSelected: false)
  }

  private func beginPlayback(_ source: MeetingPlaybackSource) {
    guard meetings.playbackSource(meetingID: meetingID) == source else { return }
    let next = MeetingPlaybackController(
      source: source, output: MeetingPlaybackEngineOutput(), meetingID: meetingID,
      arbiter: meetings.playbackArbiter)
    playerSource = source
    player = next
    next.play()
  }

  private func dropPlayer() {
    player?.stop()
    player = nil
    playerSource = nil
  }

  private func statusChip(_ status: P.Status) -> some View {
    let tint: Color =
      switch status.tone {
      case .error: .stError
      case .busy: .stAccent
      case .neutral: .stTextSecondary
      }
    return HStack(spacing: DesignSpacing.xxs) {
      if status.tone == .busy {
        ProgressView().controlSize(.mini).accessibilityHidden(true)
      }
      Text(verbatim: status.label)
    }
    .historyChip(tint: tint, fill: tint.opacity(0.14))
  }

  @ViewBuilder private func line(_ line: P.Line) -> some View {
    switch line {
    case .summary(let text), .preview(let text):
      Text(verbatim: text)
        .font(.stBody)
        .foregroundStyle(.stTextBody)
        .lineLimit(2)
    case .status(let text, let tone):
      Text(verbatim: text)
        .font(.stBody)
        .foregroundStyle(tone == .error ? Color.stError : Color.stTextSecondary)
        .lineLimit(2)
    }
  }
}
