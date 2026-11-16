import EnviousWisprCore
import EnviousWisprStorage
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
/// each keeps its own keyboard focus and VoiceOver action. Its surface also opens on a click.
/// While History is selecting, the diary draws this card with hit testing off inside its
/// tick button (as it does for `HistoryTranscriptCard`).
///
struct HistoryMeetingCard: View {
  let meetingID: UUID
  let onOpen: () -> Void
  let allowsPlayback: Bool
  let query: String
  let summary: HistoryCatalog.Summary?

  init(
    meetingID: UUID, onOpen: @escaping () -> Void, allowsPlayback: Bool = true, query: String = "",
    summary: HistoryCatalog.Summary? = nil
  ) {
    self.meetingID = meetingID
    self.onOpen = onOpen
    self.allowsPlayback = allowsPlayback
    self.query = query
    self.summary = summary
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: MeetingPlaybackSource?
  @State private var moreAnchor = HistoryMenuAnchorHolder()
  @State private var renameRequested = false
  @State private var copiedAt: Date?
  @State private var confirmingDeletion: Deletion?
  @State private var deleting = false
  @State private var deleteFailed = false

  private enum Deletion: Equatable {
    case recording
    case meeting
  }

  private typealias P = MeetingAfterPresentation

  private struct EchoDetailKey: Equatable {
    let id: UUID?
    let revision: UInt64?
  }

  var body: some View {
    let record = meetings.record(id: meetingID)
    let row = summary == nil ? meetingRow(record) : nil
    let source = allowsPlayback ? meetings.playbackSource(meetingID: meetingID) : nil
    if record != nil || row != nil || summary != nil {
      card(P.card(inputs(record: record, row: row)), source: source, record: record)
        .onChange(of: source) { _, _ in dropPlayer() }
        .onDisappear(perform: dropPlayer)
        .task(id: EchoDetailKey(id: echoRowID, revision: transcripts.catalogSession?.revision)) {
          // Reloads when the saved transcript changes, which a stale payload alone never would.
          guard let id = echoRowID else { return }
          _ = await transcripts.loadCatalogDetail(id)
        }
        .task(id: echoRowID) {
          guard let id = echoRowID else { return }
          await transcripts.holdCatalogDetail(id)
        }
    }
  }

  /// The catalog preview was made with probable echo hidden. When this session shows echo for
  /// the meeting's transcript and no summary leads the card, the card previews the live,
  /// echo-aware text instead (Codex whole-diff r5), as search already does.
  private var echoRowID: UUID? {
    guard let summary, summary.hasMeetingSummary != true, let id = summary.rowID,
      transcripts.isShowingEcho(rowID: id)
    else { return nil }
    return id
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
      record: record, row: row, catalog: summary, processingID: meetings.processing?.meetingID,
      queueWaitsForSpace: meetings.queueWaitsForSpace,
      previewText: shown ? previewText(row: row) : nil,
      summary: shown
        ? (documents.summary(meetingID)
          ?? (summary?.hasMeetingSummary == true ? summary?.preview : nil)) : nil,
      summaryProviderID: documents.manifest(meetingID)?.summary?.inputs?.providerID
        ?? summary?.summaryProvider)
  }

  private func previewText(row: Transcript?) -> String? {
    if let id = echoRowID, let echoRow = transcripts.currentRow(id: id) {
      return transcripts.meetingPreviewText(of: echoRow)
    }
    return summary?.preview ?? row.map(transcripts.meetingPreviewText(of:))
  }

  private func card(_ card: P.Card, source: MeetingPlaybackSource?, record: MeetingRecord?)
    -> some View
  {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      // The rename controls are siblings of Open and "···", never inside them. A row whose
      // meeting folder is gone has no record to rename, so it shows its name only.
      if card.canRename {
        MeetingInlineTitle(meetingID: meetingID, beginRequest: $renameRequested, searchQuery: query)
      } else {
        HistoryParagraphText.searchText(card.title, query: query)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      line(card.line)
      if let attention = card.attentionLine {
        line(.status(attention, .error))
      }
      footerOrPlayback(card, source: source, record: record)
      if deleteFailed {
        Text(
          "That didn't work. Try again.",
          comment: "History meeting card: deleting a meeting or its recording failed."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
      buttonRow(card, record: record)
    }
    .historyDiaryCard()
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .confirmationDialog(
      Text(verbatim: Self.confirmationTitle(confirmingDeletion ?? .meeting)),
      isPresented: Binding(
        get: { confirmingDeletion != nil }, set: { if !$0 { confirmingDeletion = nil } }),
      presenting: confirmingDeletion
    ) { kind in
      Button(role: .destructive) {
        delete(kind)
      } label: {
        Text("Delete", comment: "EnviousMeet: confirms a deletion.")
      }
    } message: { kind in
      Text(verbatim: Self.confirmationMessage(kind))
    }
  }

  // MARK: - Footer and playback

  /// One quiet line in the Dictations footer's style (#4611). With a recording to play, the line
  /// starts with the small play button and the facts follow it; while it plays the same line
  /// shows the clock and waveform, so the card keeps its height.
  @ViewBuilder
  private func footerOrPlayback(
    _ card: P.Card, source: MeetingPlaybackSource?, record: MeetingRecord?
  )
    -> some View
  {
    if let source, source.durationMs > 0 {
      HistoryInlinePlayback(
        player: playerSource == source ? player : nil,
        toggle: { toggle(source) }
      ) {
        footer(card, record: record)
      }
    } else {
      footer(card, record: record)
    }
  }

  private enum Fact: Hashable {
    case status(String, tone: P.Tone)
    case clock(String)
    case engine(String)
    case text(String)
    case speakers(String)
    case recordingDeleted(String)
  }

  private func facts(_ card: P.Card, record: MeetingRecord?) -> [Fact] {
    var facts: [Fact] = []
    if let status = card.status { facts.append(.status(status.label, tone: status.tone)) }
    if let record, record.recordedDurationMs > 0,
      let clock = HistoryTranscriptPresentation.footerClock(
        seconds: TimeInterval(record.recordedDurationMs) / 1000)
    {
      facts.append(.clock(clock))
    } else if record == nil, let length = card.length {
      facts.append(.text(length))
    }
    let engine = record?.transcriptEngineUsed?.backendType.displayName ?? summary?.backendName
    for (index, fact) in card.footer.enumerated() {
      facts.append(index == 0 && fact == engine ? .engine(fact) : .text(fact))
    }
    if let people = card.speakers { facts.append(.speakers(people)) }
    if let audio = card.audioLine { facts.append(.recordingDeleted(audio)) }
    return facts
  }

  /// Plain facts are joined by a dot; the status chip needs none.
  private static func isInline(_ fact: Fact) -> Bool {
    if case .status = fact { return false }
    return true
  }

  private func footer(_ card: P.Card, record: MeetingRecord?) -> some View {
    let shown = facts(card, record: record)
    return HStack(spacing: DesignSpacing.sm) {
      ForEach(Array(shown.enumerated()), id: \.element) { index, fact in
        if index > 0, Self.isInline(fact), Self.isInline(shown[index - 1]) { HistoryFooterDot() }
        factView(fact)
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
    .lineLimit(1)
  }

  @ViewBuilder
  private func factView(_ fact: Fact) -> some View {
    switch fact {
    case .status(let label, let tone):
      statusChip(P.Status(label: label, tone: tone))
    case .clock(let clock):
      Text(verbatim: clock).monospacedDigit()
    case .engine(let name):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "waveform").accessibilityHidden(true)
        Text(verbatim: name)
      }
    case .text(let text):
      Text(verbatim: text)
    case .speakers(let names):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "person.2").accessibilityHidden(true)
        Text(verbatim: names)
      }
      .truncationMode(.middle)
    case .recordingDeleted(let reason):
      HistoryUnplayableMark(
        label: LocalizedStringResource(
          "Recording deleted",
          comment:
            "History meeting card footer: this meeting's recording was deleted. Hover gives the full sentence."
        ),
        reason: reason)
    }
  }

  // MARK: - Buttons

  /// Open, Copy and More, in the Dictations card's place and order (#4611).
  private func buttonRow(_ card: P.Card, record: MeetingRecord?) -> some View {
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: String(localized: "Copy", comment: "EnviousMeet: copies the visible transcript."),
      copiedAt: copiedAt, now: Date(), holdSeconds: TranscribeFileExport.copiedHoldSeconds)
    return HStack(spacing: DesignSpacing.md) {
      Button(action: onOpen) {
        EnviousButtonLabel(
          LocalizedStringResource("Open", comment: "History meeting card: opens the meeting."),
          size: .medium, trailingSystemImage: "chevron.right")
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)
      .accessibilityLabel(
        Text(
          "Open \(card.title)",
          comment: "History meeting card: VoiceOver label of Open. %@ is the meeting's name."))

      Button {
        // Read at the press from the live row, never this card's snapshot.
        guard let text = deliveryText() else { return }
        TranscribeFileExport.copy(text)
        let pressed = Date()
        copiedAt = pressed
        Task {
          try? await Task.sleep(for: .seconds(TranscribeFileExport.copiedHoldSeconds))
          if copiedAt == pressed { copiedAt = nil }
        }
      } label: {
        Image(systemName: copy.systemImage)
          .frame(width: 16, height: 16)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: canDeliver(record))
      .help(Text(verbatim: copy.title))
      .accessibilityLabel(Text(verbatim: copy.title))

      Button {
        guard let anchor = moreAnchor.view else { return }
        historyMenu.toggle(items: moreItems(card, record: record), from: anchor)
      } label: {
        Image(systemName: "ellipsis")
          .fontWeight(.bold)
          .frame(width: 16, height: 16)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .background(HistoryMenuAnchor(holder: moreAnchor))
      .help(Text("More actions", comment: "History transcript: opens the More menu."))
      .accessibilityLabel(Text("More actions", comment: "History transcript: opens the More menu."))
    }
    .fixedSize()
  }

  /// The card's More menu, built when it opens: Rename and the two deletions, each enabled by
  /// the same rules as the meeting page's More menu.
  private func moreItems(_ card: P.Card, record: MeetingRecord?) -> [HistoryMenuItem] {
    let offered = record.map {
      MeetingsPresentation.actions($0, isActive: isActive($0), canTranscribeAgain: false)
    }
    return [
      .init(
        id: "rename",
        title: String(localized: "Rename", comment: "EnviousMeet: saves the meeting's new name."),
        systemImage: "pencil", isEnabled: card.canRename, kind: .action { renameRequested = true }),
      .divider("d1"),
      .init(
        id: "delete-recording",
        title: String(
          localized: "Delete recording, keep text",
          comment:
            "History meeting, More menu: deletes the meeting's audio; notes, transcript and summary stay."
        ),
        systemImage: "waveform.slash", isEnabled: offered?.deleteAudio == true && !deleting,
        isDestructive: true, kind: .action { confirmingDeletion = .recording }),
      .init(
        id: "delete-meeting",
        title: String(
          localized: "Delete meeting",
          comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
        systemImage: "trash", isEnabled: offered?.delete == true && !deleting,
        isDestructive: true, kind: .action { confirmingDeletion = .meeting }),
    ]
  }

  private func isActive(_ record: MeetingRecord) -> Bool {
    if meetings.processing?.meetingID == record.id { return true }
    switch meetings.phase {
    case .recording(let id, _), .stopping(let id): return id == record.id
    case .starting, .idle: return false
    }
  }

  // MARK: - Copy and delete

  private func canDeliver(_ record: MeetingRecord?) -> Bool {
    // A row whose meeting folder is gone has no record; the press reads the live row (and does nothing without one).
    guard let record else { return true }
    return !record.deletionRequested && record.committedTranscriptGeneration != nil
  }

  /// The visible words of the CURRENT row, read at the press (as the meeting page does).
  private func deliveryText() -> String? {
    guard let row = deliveryRow() else { return nil }
    return MeetingHistoryPresentation.deliveryText(
      row, projection: transcripts.meetingProjection(of: row), timesOn: false, mode: .cleaned)
  }

  private func deliveryRow() -> Transcript? {
    if let record = meetings.record(id: meetingID) {
      guard !record.deletionRequested, record.committedTranscriptGeneration != nil else {
        return nil
      }
      // A card is drawn from the catalog, so its transcript may not be loaded yet: the press reads it.
      return transcripts.verifiedRowForDelivery(id: record.transcriptID, fetchIfNeeded: true)
    }
    // An orphan card drawn from the catalog names its own row; the coordinator's list may not hold it yet.
    guard let id = summary?.rowID ?? transcripts.rowIDs(ofMeeting: meetingID).last else {
      return nil
    }
    return transcripts.verifiedRowForDelivery(id: id, fetchIfNeeded: true)
  }

  private static func confirmationTitle(_ kind: Deletion) -> String {
    switch kind {
    case .recording:
      String(
        localized: "Delete this meeting's recording?",
        comment: "History meeting: confirmation title before deleting only the audio.")
    case .meeting:
      String(
        localized: "Delete this meeting?",
        comment: "History meeting: confirmation title before deleting the whole meeting.")
    }
  }

  private static func confirmationMessage(_ kind: Deletion) -> String {
    switch kind {
    case .recording:
      String(
        localized:
          "Delete this meeting's audio? The transcript stays, but you cannot transcribe it again.",
        comment: "EnviousMeet: confirmation before Delete audio.")
    case .meeting:
      String(
        localized: "Delete this meeting, its audio and its transcript? This cannot be undone.",
        comment: "EnviousMeet: confirmation before Delete meeting.")
    }
  }

  private func delete(_ kind: Deletion) {
    confirmingDeletion = nil
    guard !deleting, meetings.record(id: meetingID) != nil else { return }
    // Playback stops before any file of this meeting is touched.
    dropPlayer()
    deleting = true
    deleteFailed = false
    let scope: HistoryDeleteKind = kind == .recording ? .recordingsOnly : .textAndRecordings
    Task {
      let outcome = await transcripts.deleteHistoryItem(id: .meeting(meetingID), kind: scope)
      deleting = false
      deleteFailed = HistoryDictationPresentation.deletionFailed(outcome)
    }
  }

  private func toggle(_ source: MeetingPlaybackSource) {
    if let player, playerSource == source {
      if player.state == .playing { player.pause() } else { player.play() }
    } else {
      beginPlayback(source)
    }
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
      // A meeting with no words (a few seconds of silence) draws no empty line (#4611).
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        HistoryParagraphText.searchText(text, query: query)
          .font(.stCardText)
          .foregroundStyle(.stTextBody)
          .lineLimit(2)
      }
    case .status(let text, let tone):
      Text(verbatim: text)
        .font(.stCardText)
        .foregroundStyle(tone == .error ? Color.stError : Color.stTextSecondary)
        .lineLimit(2)
    }
  }
}
