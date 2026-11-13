import CoreGraphics
import EnviousWisprCore
import Foundation

/// The decisions behind the Meetings tab card and a finished meeting's after view (#3147 PR4A,
/// plan §3.6), kept out of the views so each one is tested on its own: what the card says for
/// every meeting state, the inline title's edit steps, where note markers sit on the dock and
/// when they merge, who spoke and for how long, which turn playback is in, where a validated
/// summary source leads, and when the panes stack.
///
/// Nothing here reads files or the clock. Every input is what the meeting's owners already hold
/// in memory (`MeetingCoordinator`, `TranscriptCoordinator`, `MeetingDocumentsOwner`, the notes
/// and summary-reference protocols).
enum MeetingAfterPresentation {

  // MARK: - Card

  /// What the card says about one meeting, from its record (nil for a row whose meeting folder
  /// is gone) and its History row.
  struct Card: Equatable {
    let title: String
    /// The title is the date-based default, so the rename field starts empty.
    let isUntitled: Bool
    let startedAt: Date
    let callApp: String?
    let length: String?
    let speakers: String?
    /// Shown beside the title while the meeting is not ready (Recording, Waiting, …).
    let status: Status?
    let line: Line
    /// What the user must act on while a committed transcript stays shown (a retry waiting for
    /// disk space, or a retry that failed), so the retained preview never hides it.
    let attentionLine: String?
    /// The quiet facts under the line: the speech engine and who wrote the summary.
    let footer: [String]
    /// A sentence about the recording when it is gone, or nil.
    let audioLine: String?
    /// The title can be renamed here (a record this build can write, not being deleted).
    let canRename: Bool
  }

  struct Status: Equatable {
    let label: String
    let tone: Tone
  }

  enum Tone: Equatable {
    case neutral, busy, error
  }

  /// The card's one preview line.
  enum Line: Equatable {
    /// The first line of the meeting's summary.
    case summary(String)
    /// The transcript's visible words (hidden echo never reaches it).
    case preview(String)
    /// Why there is nothing to read yet, or what went wrong.
    case status(String, Tone)
  }

  /// The inputs the card needs, read by the view from the owners.
  struct CardInputs {
    var record: MeetingRecord?
    var row: Transcript?
    /// `MeetingCoordinator.processing?.meetingID`.
    var processingID: UUID?
    var queueWaitsForSpace = false
    /// `TranscriptCoordinator.meetingPreviewText(of:)` for `row`: the projection's text.
    var previewText: String?
    /// The meeting's current summary text, when it has one.
    var summary: String?
    /// `SummaryInputs.providerID` of that summary.
    var summaryProviderID: String?
  }

  static func card(_ inputs: CardInputs) -> Card {
    guard let record = inputs.record else {
      // A row whose meeting EnviousMeet no longer holds: its transcript only (legacy orphan).
      let row = inputs.row
      return Card(
        title: fallbackTitle, isUntitled: true, startedAt: row?.createdAt ?? .distantPast,
        callApp: nil, length: nil,
        speakers: MeetingsPresentation.speakers(row?.speakerAnalysis), status: nil,
        line: .preview(inputs.previewText ?? MeetingHistoryPresentation.unavailableMessage),
        attentionLine: nil, footer: row.map { [$0.backendType.displayName] } ?? [], audioLine: nil, canRename: false)
    }
    let status = MeetingsPresentation.status(record, processingID: inputs.processingID)
    let committed = record.committedTranscriptGeneration != nil
    let hasRow = committed && inputs.row != nil
    return Card(
      title: MeetingsPresentation.title(record),
      isUntitled: (record.title ?? "").isEmpty,
      startedAt: record.createdAt,
      callApp: record.callApp?.displayName,
      length: record.recordedDurationMs > 0
        ? MeetingsPresentation.duration(ms: record.recordedDurationMs) : nil,
      speakers: hasRow ? MeetingsPresentation.speakers(inputs.row?.speakerAnalysis) : nil,
      status: status == .ready ? nil : cardStatus(status, record: record, inputs: inputs),
      line: cardLine(record, status: status, hasRow: hasRow, inputs: inputs),
      attentionLine: hasRow ? attentionLine(record, status: status, inputs: inputs) : nil,
      footer: footer(record, committed: committed, inputs: inputs),
      audioLine: audioLine(record, committed: committed),
      canRename: record.isWritableByThisBuild && !record.deletionRequested)
  }

  private static func cardStatus(
    _ status: MeetingsPresentation.Status, record: MeetingRecord, inputs: CardInputs
  ) -> Status {
    let tone: Tone
    switch status {
    case .needsAttention: tone = .error
    case .recording, .saving, .transcribing: tone = .busy
    case .waiting where inputs.queueWaitsForSpace: tone = .error
    case .waiting, .interrupted, .ready, .notesOnly: tone = .neutral
    }
    return Status(label: MeetingsPresentation.statusLabel(status), tone: tone)
  }

  /// Summary first, then the visible transcript, then what is happening (the mock's order). A
  /// committed transcript keeps its preview while Transcribe again runs, waits or fails.
  private static func cardLine(
    _ record: MeetingRecord, status: MeetingsPresentation.Status, hasRow: Bool,
    inputs: CardInputs
  ) -> Line {
    if hasRow, let summary = inputs.summary.flatMap(summaryFirstLine) {
      return .summary(summary)
    }
    if hasRow, let preview = inputs.previewText {
      return .preview(preview)
    }
    switch status {
    case .recording:
      return .status(recordingLine, .busy)
    case .saving:
      return .status(savingLine, .busy)
    case .transcribing:
      return .status(transcribingLine, .busy)
    case .waiting where inputs.queueWaitsForSpace:
      return .status(waitingForSpaceLine, .error)
    case .waiting:
      return .status(waitingLine, .neutral)
    case .interrupted:
      return .status(interruptedLine, .neutral)
    case .notesOnly:
      return .status(notesOnlyLine, .neutral)
    case .needsAttention:
      return .status(
        MeetingsPresentation.failureLine(record) ?? needsAttentionLine, .error)
    case .ready:
      // Ready, but History has not listed its row yet, or the row could not be read.
      return .status(MeetingHistoryPresentation.unavailableMessage, .neutral)
    }
  }

  /// A reason the retained preview would otherwise hide. Only for a meeting whose committed
  /// transcript is shown; without one, `cardLine` already says it.
  private static func attentionLine(
    _ record: MeetingRecord, status: MeetingsPresentation.Status, inputs: CardInputs
  ) -> String? {
    switch status {
    case .waiting where inputs.queueWaitsForSpace: return waitingForSpaceLine
    case .needsAttention: return MeetingsPresentation.failureLine(record) ?? needsAttentionLine
    case .recording, .saving, .waiting, .interrupted, .transcribing, .ready, .notesOnly:
      return nil
    }
  }

  private static func footer(_ record: MeetingRecord, committed: Bool, inputs: CardInputs)
    -> [String]
  {
    var facts: [String] = []
    if committed, let engine = record.transcriptEngineUsed?.backendType.displayName {
      facts.append(engine)
    }
    if committed, inputs.summary != nil {
      if let name = inputs.summaryProviderID.flatMap(LLMProvider.init(rawValue:))?.displayName,
        !name.isEmpty
      {
        facts.append(summaryByLine(name))
      } else {
        facts.append(summaryReadyLine)
      }
    } else if committed {
      facts.append(noSummaryLine)
    }
    return facts
  }

  /// Only for a meeting that had a recording: a notes-only meeting never says its audio went.
  private static func audioLine(_ record: MeetingRecord, committed: Bool) -> String? {
    guard !record.audioKept, record.state != .notesOnly else { return nil }
    return committed ? recordingDeletedLine : recordingDeletedNoTranscriptLine
  }

  /// The first readable line of a Markdown summary: headings, list markers and emphasis
  /// stripped. Nil when the summary has no words.
  static func summaryFirstLine(_ markdown: String) -> String? {
    for raw in markdown.split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") { continue }
      for marker in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ ", "> "]
      where line.hasPrefix(marker) {
        line.removeFirst(marker.count)
        break
      }
      line = line.replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .trimmingCharacters(in: .whitespaces)
      if !line.isEmpty { return line }
    }
    return nil
  }

  // MARK: - Inline title

  /// The inline title's edit steps (plan §3.6): Return saves, Escape cancels, an empty name
  /// restores the untitled label, and a failed save keeps the typed name and offers Try again.
  struct TitleEdit: Equatable {
    enum Phase: Equatable {
      case idle
      case editing
      /// The rename was sent; the field waits for its answer.
      case saving
      /// The rename failed; the typed name stays.
      case failed
    }

    private(set) var phase: Phase = .idle
    var draft = ""

    var isEditing: Bool { phase != .idle }

    /// Opens the field with the stored name (empty for the date-based default).
    mutating func begin(storedTitle: String?) {
      guard phase == .idle else { return }
      draft = storedTitle ?? ""
      phase = .editing
    }

    /// Escape: back to the shown title, nothing written. Ignored while a rename is in flight,
    /// so its answer still lands.
    mutating func cancel() {
      guard phase != .saving else { return }
      phase = .idle
      draft = ""
    }

    enum Commit: Equatable {
      /// Nothing changed (same name, or a second Return while saving): close without writing.
      case unchanged
      /// Send this name to `MeetingCoordinator.rename`; an empty name clears the title.
      case rename(String)
      /// A rename is already in flight.
      case busy
    }

    /// Return (or Try again). The coordinator trims and caps; this only decides whether to call.
    mutating func commit(storedTitle: String?) -> Commit {
      switch phase {
      case .idle: return .unchanged
      case .saving: return .busy
      case .editing, .failed: break
      }
      let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      if typed == (storedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
        phase = .idle
        draft = ""
        return .unchanged
      }
      phase = .saving
      return .rename(typed)
    }

    /// The rename's answer: success closes the field, failure keeps the typed name.
    mutating func finish(saved: Bool) {
      guard phase == .saving else { return }
      if saved {
        phase = .idle
        draft = ""
      } else {
        phase = .failed
      }
    }
  }

  // MARK: - Note markers

  struct NoteMarker: Equatable, Identifiable {
    let id: UUID
    let ms: Int
    let kind: MeetingNoteBlock.Kind
    let text: String
  }

  /// Notes with a meeting time inside the recording, in time order. Migrated notes (no time),
  /// empty blocks and times past the end are not placed.
  static func noteMarkers(_ document: MeetingNotesDocument, durationMs: Int) -> [NoteMarker] {
    guard durationMs > 0 else { return [] }
    return document.blocks.compactMap { block -> NoteMarker? in
      let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let ms = block.startedAtMs, (0...durationMs).contains(ms), !text.isEmpty else {
        return nil
      }
      return NoteMarker(id: block.id, ms: ms, kind: block.kind, text: text)
    }
    .sorted { ($0.ms, $0.id.uuidString) < ($1.ms, $1.id.uuidString) }
  }

  /// Markers drawn on the dock's track. Markers closer than `minimumGap` points merge into one
  /// cluster ("3 notes") that opens a list.
  struct MarkerCluster: Equatable, Identifiable {
    let markers: [NoteMarker]
    var id: UUID { markers[0].id }
    /// Where the cluster sits: its first marker's time.
    var ms: Int { markers[0].ms }
  }

  static let markerMinimumGap: CGFloat = 18

  static func clusters(
    _ markers: [NoteMarker], durationMs: Int, trackWidth: CGFloat,
    minimumGap: CGFloat = markerMinimumGap
  ) -> [MarkerCluster] {
    guard durationMs > 0, trackWidth > 0 else { return [] }
    var result: [[NoteMarker]] = []
    var clusterStartX: CGFloat = -.infinity
    for marker in markers {
      let x = CGFloat(marker.ms) / CGFloat(durationMs) * trackWidth
      if !result.isEmpty, x - clusterStartX < minimumGap {
        result[result.count - 1].append(marker)
      } else {
        result.append([marker])
        clusterStartX = x
      }
    }
    return result.map(MarkerCluster.init(markers:))
  }

  static func clusterLabel(_ cluster: MarkerCluster) -> String {
    let count = cluster.markers.count
    if count == 1 {
      return String(
        localized: "1 note",
        comment: "Meeting player: a note marker on the timeline holding one note.")
    }
    return String(
      localized: "\(count) notes",
      comment: "Meeting player: a note marker holding several notes close together. Never 1.")
  }

  // MARK: - Participants

  struct Participant: Equatable, Identifiable {
    let id: String
    let name: String
    /// The speaker has a name (from the call app, the roster or a rename).
    let isNamed: Bool
    let spokenMs: Int
    /// Share of all measured speaking time, 0…1.
    let share: Double
  }

  /// Who spoke and for how long, from the visible turns' measured durations. Turns without
  /// both times are not counted. Unnamed and unclassified speakers are labelled as such, never
  /// given a guessed name.
  static func participants(turns: [Turn], speakerNames: [String: String]) -> [Participant] {
    var spoken: [String: Int] = [:]
    var order: [String] = []
    for turn in turns {
      guard let start = turn.startMs, let end = turn.endMs, end > start else { continue }
      if spoken[turn.speakerId] == nil { order.append(turn.speakerId) }
      spoken[turn.speakerId, default: 0] += end - start
    }
    let total = spoken.values.reduce(0, +)
    guard total > 0 else { return [] }
    return order.map { id in
      let ms = spoken[id] ?? 0
      let label = speakerLabel(id: id, speakerNames: speakerNames)
      return Participant(
        id: id, name: label.name, isNamed: label.isNamed, spokenMs: ms,
        share: Double(ms) / Double(total))
    }
    .sorted { ($1.spokenMs, $0.id) < ($0.spokenMs, $1.id) }
  }

  private static func speakerLabel(id: String, speakerNames: [String: String])
    -> (name: String, isNamed: Bool)
  {
    if id == TurnAssembler.unknownSpeakerID { return (unknownSpeakerLabel, false) }
    if id == TurnAssembler.bothSpeakersID { return (bothSpeakersLabel, false) }
    if let name = speakerNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    {
      return (name, true)
    }
    return (unnamedSpeakerLabel, false)
  }

  static func shareLabel(_ share: Double) -> String {
    share.formatted(.percent.precision(.fractionLength(0)))
  }

  // MARK: - Follow playback

  /// The turn playback is in: the last turn that started at or before the position. Nil
  /// before the first timed turn.
  static func activeTurnID(turns: [Turn], positionMs: Int) -> String? {
    var active: String?
    for turn in turns {
      guard let start = turn.startMs else { continue }
      if start <= positionMs { active = turn.id } else { break }
    }
    return active
  }

  /// Follow playback's state: following moves the transcript with playback; a deliberate user
  /// scroll (or View source) suspends it and offers Return to playback.
  enum Follow: Equatable {
    case off
    case following
    case suspended
  }

  // MARK: - Summary sources

  /// Where a validated summary source leads. Only `ValidatedMeetingSummarySource` sources come
  /// here; nothing is guessed from an ID match or shared words.
  enum SourceTarget: Equatable {
    case turn(String)
    case note(UUID)
  }

  /// The first source still shown: a turn of the visible transcript, else a note that exists.
  /// Nil hides View source (a hidden-echo or replaced turn, or a deleted note).
  static func sourceTarget(
    _ sources: [MeetingSummarySource], visibleTurnIDs: Set<String>, noteBlockIDs: Set<UUID>
  ) -> SourceTarget? {
    for source in sources {
      if case .turn(let id, _) = source, visibleTurnIDs.contains(id) { return .turn(id) }
    }
    for source in sources {
      if case .note(let id, _) = source, noteBlockIDs.contains(id) { return .note(id) }
    }
    return nil
  }

  /// The item came only from the user's notes ("from your notes").
  static func isFromNotes(_ sources: [MeetingSummarySource]) -> Bool {
    !sources.isEmpty
      && sources.allSatisfy {
        if case .note = $0 { return true }
        return false
      }
  }

  // MARK: - Layout

  /// Below this inner width the notes or summary stack above the transcript (mock
  /// MeetingLiveNarrow); the dock stays at the bottom either way.
  static let sideBySideMinimumWidth: CGFloat = 800

  static func stacksPanes(width: CGFloat) -> Bool { width < sideBySideMinimumWidth }

  /// The left pane. Your notes is selected first; switching never discards a draft.
  enum LeftPane: Hashable {
    case notes
    case summary
  }

  // MARK: - Dock

  /// Why the dock has no player.
  enum DockAbsence: Equatable {
    /// Delete recording, keep text ran.
    case recordingDeleted
    /// Nothing was recorded; notes only.
    case nothingRecorded
    /// The audio is still being saved or transcribed.
    case notReadyYet
    /// No record: the meeting folder is gone.
    case unavailable
  }

  static func dockAbsence(_ record: MeetingRecord?) -> DockAbsence {
    guard let record else { return .unavailable }
    if record.state == .notesOnly { return .nothingRecorded }
    if !record.audioKept { return .recordingDeleted }
    return .notReadyYet
  }

  static func dockAbsenceLine(_ absence: DockAbsence) -> String {
    switch absence {
    case .recordingDeleted: return recordingDeletedLine
    case .nothingRecorded:
      return String(
        localized: "Nothing was recorded for this meeting.",
        comment: "Meeting player: a meeting with notes only has no recording to play.")
    case .notReadyYet:
      return String(
        localized: "The recording can be played when the transcript is ready.",
        comment:
          "Meeting player: the audio is not playable while the meeting is saved or transcribed.")
    case .unavailable:
      return String(
        localized: "This meeting's recording isn't available.",
        comment: "Meeting player: the meeting's folder can't be read, so nothing can play.")
    }
  }

  // MARK: - Status strip

  /// The after view's status line under the header (plan §3.6 "After Stop, in place").
  enum StripState: Equatable {
    case none
    case finishingTranscript
    case waiting
    case waitingForSpace
    case writingSummary
    case summaryReady
  }

  static func strip(
    record: MeetingRecord?, processing: Bool, queueWaitsForSpace: Bool, writingSummary: Bool,
    hasSummary: Bool
  ) -> StripState {
    guard let record else { return .none }
    if processing { return .finishingTranscript }
    if record.state == .queued { return queueWaitsForSpace ? .waitingForSpace : .waiting }
    guard record.committedTranscriptGeneration != nil else { return .none }
    if writingSummary { return .writingSummary }
    return hasSummary ? .summaryReady : .none
  }

  static func stripLine(_ state: StripState) -> String? {
    switch state {
    case .none: return nil
    case .finishingTranscript:
      return String(
        localized: "Finishing the transcript…",
        comment: "Meeting after view: the transcript is still being made.")
    case .waiting: return waitingLine
    case .waitingForSpace: return waitingForSpaceLine
    case .writingSummary:
      return String(
        localized: "Writing the summary…",
        comment: "Meeting after view: the meeting summary is being written.")
    case .summaryReady:
      return String(
        localized: "Saved · Summary ready",
        comment: "Meeting after view: the meeting is saved and its summary is written.")
    }
  }

  // MARK: - Copy

  static var fallbackTitle: String {
    String(
      localized: "Meeting",
      comment: "History list: a meeting recorded with EnviousMeet whose details are not available.")
  }

  static var renameHelp: String {
    String(
      localized: "Rename meeting",
      comment: "Meetings: tooltip and VoiceOver label of the meeting title's rename control.")
  }

  static var renameFailedLine: String {
    String(
      localized: "The new name couldn't be saved.",
      comment:
        "Meetings: renaming a meeting failed; the typed name stays so the user can try again.")
  }

  static var recordingLine: String {
    String(
      localized: "Recording now. Open it to see the live words.",
      comment: "Meetings card: the meeting is being recorded.")
  }

  static var savingLine: String {
    String(
      localized: "Saving the recording",
      comment: "EnviousMeet: the meeting recording is being closed and saved.")
  }

  static var transcribingLine: String {
    String(
      localized: "Writing the transcript. Your recording is safe.",
      comment: "Meetings card: the transcript is being made.")
  }

  static var waitingLine: String {
    String(
      localized: "Waiting to be transcribed",
      comment: "History, a meeting: it waits for another meeting's transcript first.")
  }

  static var waitingForSpaceLine: String {
    String(
      localized: "Waiting for free disk space. Free up space, then choose Transcribe again.",
      comment: "History, a meeting: the transcript waits because the Mac is almost full.")
  }

  static var interruptedLine: String {
    String(
      localized: "The recording was cut short. What was recorded is kept and will be transcribed.",
      comment: "Meetings card: the app quit during the recording; the saved part is transcribed.")
  }

  static var notesOnlyLine: String {
    String(
      localized: "Nothing was recorded for this meeting. Your notes are in Notes.",
      comment: "History, a meeting that recorded nothing: where its notes are.")
  }

  static var needsAttentionLine: String {
    String(
      localized: "The transcript could not be made. Transcribe again to try once more.",
      comment: "EnviousMeet detail: why a meeting has no transcript, with what to do.")
  }

  static var recordingDeletedLine: String {
    String(
      localized: "Recording deleted. Notes, transcript and summary stay.",
      comment: "Meetings: the meeting's audio was deleted; everything written stays.")
  }

  static var recordingDeletedNoTranscriptLine: String {
    String(
      localized: "Recording deleted. Your notes stay.",
      comment: "Meetings: the meeting's audio was deleted before it had a transcript.")
  }

  static func summaryByLine(_ provider: String) -> String {
    String(
      localized: "Summary by \(provider)",
      comment: "Meetings card: who wrote the meeting summary. %@ is a provider like EG-1 or Ollama."
    )
  }

  static var summaryReadyLine: String {
    String(localized: "Summary ready", comment: "Meetings card: the meeting has a summary.")
  }

  static var noSummaryLine: String {
    String(localized: "No summary", comment: "Meetings card: the meeting has no summary yet.")
  }

  static var unknownSpeakerLabel: String {
    String(
      localized: "Unidentified speaker",
      comment: "Meeting participants: speech the app could not give to any one speaker.")
  }

  static var bothSpeakersLabel: String {
    String(
      localized: "Both",
      comment:
        "Transcript speaker label when two people spoke in a turn the app could not separate.")
  }

  static var unnamedSpeakerLabel: String {
    String(
      localized: "Unnamed speaker",
      comment: "Meeting participants: a speaker the app separated but has no name for.")
  }
}
