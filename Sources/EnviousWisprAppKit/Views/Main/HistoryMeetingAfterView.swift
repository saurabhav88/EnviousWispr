import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// A finished meeting in full inside History (#3147 PR4A, plan §3.6 "After view"): the
/// renamable title and its facts, Copy / Share / Save as… / More, a status line while the
/// transcript or summary is still being made, then two panes: on the left Your notes / AI
/// summary (Your notes first; switching never discards a draft), on the right the transcript
/// with Follow playback and Rename speaker; and the 88 pt docked player with note markers and
/// Participants. Below 800 pt the left pane stacks above the transcript; the dock stays.
///
/// **What it keeps from the legacy detail (`MeetingHistoryDetailView`, removed in PR4A)**, every row of the
/// brief's acceptance matrix:
/// - The meeting is re-read by `meetingID` on every render and action. A committed transcript
///   stays shown while Transcribe again runs, waits or fails; loading is told apart from a
///   missing or unreadable transcript; queued, waiting-for-space, processing (with its
///   progress), stopping and recording states are shown truthfully, never a blank pane.
/// - Notes-only meetings open on Your notes and say nothing was recorded. A row whose meeting
///   folder is gone shows its transcript and deletes only when the folder is confirmed absent.
/// - The transcript is `TranscriptCoordinator.meetingProjection` (hidden echo, the Show
///   probable echo toggle, the all-hidden and unavailable explanations), its speaker rename and
///   roster suggestions and the missing-Accessibility note.
/// - One shared player per playable source (`MeetingCoordinator.playbackSource`), known to the
///   now-playing arbiter; replaced when the inventory changes; stopped when the view goes, the
///   source goes, or before either deletion. "Play from here" on a turn seeks then plays.
/// - Copy (`.kept`), Share (read when the receiving app asks) and Paste (into the previous app,
///   with the notice on the page that outlives this view) deliver the CURRENT visible words.
///   Save reads after its panel closes, includes the notes, and refuses unreadable notes.
/// - Delete recording, keep text and Delete meeting confirm their scope, stop playback first,
///   await the real outcome and say when it failed.
/// - Summary editing, its save-failure Try again and edited-summary protection stay in
///   `MeetingSummaryView`, which this view embeds unchanged.
///
/// **Notes** come only through `MeetingNotesAccessing` (the app-owned draft); **summary links**
/// only through `MeetingSummaryReferencing`: View source appears for an item only when the
/// validator accepted its sources, scrolls and highlights the source, and never starts playback.
struct HistoryMeetingAfterView: View {
  let meetingID: UUID
  let notes: any MeetingNotesAccessing
  let references: any MeetingSummaryReferencing
  /// #4101: why a Paste did not happen, shown by the surface that outlives this view.
  let showPasteNotice: @MainActor (String) -> Void
  /// Brings that surface back to the front when Paste needs the user.
  let restorePasteSurface: @MainActor () -> Void
  let back: () -> Void
  /// Previous and next meeting in the Meetings list (#4611).
  let neighbors: HistoryNeighbors

  init(
    meetingID: UUID,
    notes: any MeetingNotesAccessing,
    references: any MeetingSummaryReferencing,
    showPasteNotice: @escaping @MainActor (String) -> Void,
    restorePasteSurface: @escaping @MainActor () -> Void,
    back: @escaping () -> Void,
    neighbors: HistoryNeighbors = .none
  ) {
    self.meetingID = meetingID
    self.notes = notes
    self.references = references
    self.showPasteNotice = showPasteNotice
    self.restorePasteSurface = restorePasteSurface
    self.back = back
    self.neighbors = neighbors
  }

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication
  @Environment(HistoryRepolishRunner.self) private var historyRepolish
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @State private var moreAnchor = HistoryMenuAnchorHolder()

  // Panes
  @State private var leftPane: P.LeftPane = .notes
  /// Meetings show only the cleaned transcript (founder, #4611: no view switch on meetings).
  private let transcriptMode: FileImportCoordinator.DocumentView = .cleaned
  /// The header's Timestamps switch (#4611): shows or hides each turn's start time.
  @State private var timesOn = true
  @State private var transcriptPolish = HistoryPolishPreview()
  @State private var summaryPolishNotice = false
  @State private var keepingSummary = false
  @State private var editingSummary = false
  /// #4611: Your notes' edit mode, owned here so Edit notes sits on the tab row. Nil until the
  /// person chooses: the pane then starts in its default mode.
  @State private var editingNotes: Bool?
  /// #4611 D1: which pane's Copy just copied, and when (its Copied shows for 2 s).
  @State private var copiedPane: PaneCopy?
  @State private var copiedPaneAt: Date?
  @State private var follow: P.Follow = .following
  @State private var activeTurnID: String?
  @State private var highlightedTurnID: String?
  @State private var highlightedNoteID: UUID?
  /// A request to bring a note into view. A fresh request each time, so choosing the same note
  /// again scrolls back to it.
  @State private var noteRequest: NoteRequest?
  @State private var openedDuringRecording: UUID?
  @State private var narrowPane: MeetingSessionPane = .notes
  @State private var notesActions = MeetingNotesEditorActions()

  // Player
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: MeetingPlaybackSource?
  @State private var retainedRate: Float = 1

  // Actions
  @State private var confirming: Confirmation?
  @State private var pendingTranscription: MeetingEngineChoice?
  @State private var actionInFlight = false
  @State private var saveError: String?
  @State private var notice: Notice?
  @State private var completedTranscriptRead: TranscriptReadKey?
  @State private var orphanRowID: UUID?
  /// Bumped when the view shows another meeting or goes away, so an action that finishes later
  /// never writes its result (a notice, a player, a refusal) into another meeting's screen.
  @State private var presentation = 0

  private typealias P = MeetingAfterPresentation

  enum Confirmation: Equatable {
    case deleteAudio
    case deleteMeeting
  }

  private struct Notice: Equatable {
    let text: String
    let isError: Bool
    /// A failed deletion offers Try again here, even when the menu no longer offers it (the
    /// deletion mark was already saved).
    var retry: Confirmation? = nil
  }

  private struct NoteRequest: Equatable {
    let id: UUID
    let nonce = UUID()
  }

  private struct TranscriptReadKey: Equatable {
    let meetingID: UUID
    let transcriptID: UUID?
    let generation: UUID?
    let catalogRevision: UInt64
  }

  private var transcriptReadKey: TranscriptReadKey? {
    guard let revision = transcripts.catalogSession?.revision else { return nil }
    let record = meetings.record(id: meetingID)
    return TranscriptReadKey(
      meetingID: meetingID, transcriptID: record?.transcriptID,
      generation: record?.committedTranscriptGeneration, catalogRevision: revision)
  }

  private var didReadTranscript: Bool {
    if let key = transcriptReadKey { return completedTranscriptRead == key }
    return transcripts.historyReadFinished
  }

  var body: some View {
    Group {
      if let record = meetings.record(id: meetingID), !record.deletionRequested {
        content(record)
          // Cloud review P1: reads the meeting's notes and summary when the page opens, whatever
          // pane shows. A meeting started this session is not read at launch, and Edit notes
          // shows only once its notes are read. `flush` reads notes not yet read and saves
          // nothing that was not typed.
          .task(id: meetingID) { _ = await notes.flush(meetingID) }
          .onChange(of: isRecordingThisMeeting, initial: true) { _, recording in
            if recording { openedDuringRecording = meetingID }
          }
          .task(id: meetings.playbackSource(meetingID: meetingID)) { reconcilePlayer() }
      } else if meetings.record(id: meetingID) == nil, let row = orphanRow {
        MeetingOrphanPage(
          meetingID: meetingID, row: row, neighbors: neighbors, mode: transcriptMode, back: back,
          deliveryText: { deliveryText() }, paste: { pasteTapped() },
          save: { save(defaultName: $0) }
        )
        .id(meetingID)
        .onAppear { dropPlayer() }
      } else {
        removedPlaceholder
          .onAppear { dropPlayer() }
      }
    }
    .background(Color.stPageBg)
    .task(id: transcriptReadKey) {
      guard let key = transcriptReadKey else { return }
      let foundOrphan: UUID?
      if let id = key.transcriptID {
        if key.generation != nil { _ = await transcripts.loadCatalogDetail(id) }
        foundOrphan = nil
      } else {
        foundOrphan = await transcripts.loadCatalogOrphan(key.meetingID)
      }
      guard !Task.isCancelled, transcriptReadKey == key else { return }
      orphanRowID = foundOrphan
      completedTranscriptRead = key
    }
    .task(id: transcriptReadKey?.transcriptID ?? orphanRowID) {
      // A meeting with a record holds its transcript; one whose folder is gone holds its orphan row.
      if let id = transcriptReadKey?.transcriptID ?? orphanRowID {
        await transcripts.holdCatalogDetail(id)
      }
    }
    .onDisappear {
      presentation += 1
      transcriptPolish.cancel()
      meetings.summaries?.discardPreview(meetingID)
      dropPlayer()
    }
    .onChange(of: meetingID) {
      // A reused view never carries one meeting's screen state into another.
      presentation += 1
      actionInFlight = false
      dropPlayer()
      leftPane = .notes
      narrowPane = .notes
      editingSummary = false
      editingNotes = nil
      follow = .following
      timesOn = true
      activeTurnID = nil
      highlightedTurnID = nil
      highlightedNoteID = nil
      noteRequest = nil
      confirming = nil
      notice = nil
      orphanRowID = nil
      completedTranscriptRead = nil
    }
    .confirmationDialog(
      Text(Self.confirmationTitle(confirming)), isPresented: confirmingBinding,
      presenting: confirming
    ) { kind in
      Button(role: .destructive) {
        perform(kind)
      } label: {
        if kind == .deleteAudio {
          Text(
            "Delete recording",
            comment: "History meeting page: confirms deleting only the meeting's recording.")
        } else {
          Text("Delete", comment: "EnviousMeet: confirms a deletion.")
        }
      }
    } message: { kind in
      Text(verbatim: Self.confirmationMessage(kind))
    }
    .confirmationDialog(
      Text(
        "Transcribe again with \(pendingTranscription.map(MeetingTranscriptEngineRowTitles.title(of:)) ?? "")?",
        comment:
          "History meeting: confirmation title before Transcribe again with. %@ is a speech model name."
      ),
      isPresented: Binding(
        get: { pendingTranscription != nil },
        set: { if !$0 { pendingTranscription = nil } }),
      presenting: pendingTranscription
    ) { engine in
      Button {
        pendingTranscription = nil
        transcribeAgain(engine)
      } label: {
        Text(
          "Transcribe again",
          comment: "History meeting: confirms Transcribe again with.")
      }
    } message: { _ in
      Text(
        "The new text replaces this meeting's transcript, including speaker names and cleanup. Your recording is kept.",
        comment: "History meeting: confirmation message before Transcribe again with.")
    }
    .alert(
      Text("Couldn't save the file", comment: "History: the save panel's file could not be written."),
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(String(localized: "OK", comment: "EnviousMeet: closes the Save error.")) {}
    } message: {
      Text(verbatim: saveError ?? "")
    }
  }

  /// The row that still names this meeting when EnviousMeet no longer holds it.
  private var orphanRow: Transcript? {
    if transcripts.catalogSession != nil {
      guard let orphanRowID, let row = transcripts.currentRow(id: orphanRowID),
        row.meetingID == meetingID
      else { return nil }
      return row
    }
    return transcripts.rowIDs(ofMeeting: meetingID).compactMap(transcripts.currentRow(id:)).last
  }

  /// The committed transcript's row. A ready meeting's row stays shown while Transcribe again
  /// runs, waits or fails (#3973 C2).
  private func committedRow(_ record: MeetingRecord) -> Transcript? {
    guard record.committedTranscriptGeneration != nil else { return nil }
    return transcripts.currentRow(id: record.transcriptID)
  }

  private var removedPlaceholder: some View {
    VStack(spacing: DesignSpacing.md) {
      HistoryDestinationBar(tab: .meetings, close: back)
      Image(systemName: "person.2.wave.2")
        .font(.stRowTitle)
        .foregroundStyle(.stTextSecondary)
        .accessibilityHidden(true)
      Text(verbatim: MeetingHistoryPresentation.unavailableMessage)
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      // A deletion that failed after its mark was saved still says so and offers Try again.
      noticeView
    }
    .padding(.horizontal, SettingsLayout.contentH)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var noticeView: some View {
    if let notice {
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
        Text(verbatim: notice.text)
          .font(.stHelper)
          .foregroundStyle(notice.isError ? Color.stError : Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if let retry = notice.retry {
          Button {
            perform(retry)
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Try again", comment: "History meeting: runs the failed deletion again."),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
          .font(.stHelper)
          .disabled(actionInFlight)
        }
      }
    }
  }

  // MARK: - Layout

  private func content(_ record: MeetingRecord) -> some View {
    let row = committedRow(record)
    let projection = row.map(transcripts.meetingProjection(of:))
    let visibleTurns: [Turn] = {
      if case .visible(let turns, _)? = projection { return turns }
      return []
    }()
    let snapshot = notes.snapshot(for: meetingID)
    return VStack(spacing: 0) {
      header(record, row: row, projection: projection)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.top, SettingsLayout.contentTop)
        .padding(.bottom, DesignSpacing.lg)
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          panes(
            record, row: row, projection: projection, snapshot: snapshot,
            visibleTurns: visibleTurns, width: geometry.size.width, proxy: proxy
          )
          .onChange(of: noteRequest) { _, request in
            // A chosen note marker (or a note View source) brings its note into view, after the
            // notes pane has mounted when it was not showing.
            guard let request else { return }
            // Cloud review P2 (twice): below 800 pt the notes and transcript share one scroll
            // view, so following playback would scroll any revealed note (marker or View source)
            // away. Every note reveal comes through this request.
            if P.stacksPanes(width: geometry.size.width) { suspendFollow() }
            Task { @MainActor in
              await Task.yield()
              withAnimation { proxy.scrollTo(request.id, anchor: .center) }
            }
          }
          .background {
            if let player {
              MeetingFollowDriver(
                player: player, turns: visibleTurns, activeTurnID: $activeTurnID,
                following: follow == .following,
                scroll: { id in
                  proxy.scrollTo(TurnRowKey(turnID: id, occurrence: 0), anchor: .center)
                },
                scrollsWhenPlaybackStarts: true
              )
              .id(ObjectIdentifier(player))
            }
          }
        }
      }
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.bottom, DesignSpacing.xl)
      if !isRecordingThisMeeting {
        dock(record)
          .id(player.map(ObjectIdentifier.init))
      }
    }
    .onAppear {
      if record.state == .notesOnly { leftPane = .notes }
    }
  }

  private var isRecordingThisMeeting: Bool {
    if case .recording(let id, _) = meetings.phase { return id == meetingID }
    return false
  }

  @ViewBuilder
  private func panes(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?,
    snapshot: MeetingNotesSnapshot, visibleTurns: [Turn], width: CGFloat, proxy: ScrollViewProxy
  ) -> some View {
    let canDeliver: Bool = {
      if case .visible? = projection { return true } else { return false }
    }()
    let visibleTurnIDs = Set(visibleTurns.map(\.id))
    if isRecordingThisMeeting || openedDuringRecording == meetingID {
      MeetingSessionPanes(
        width: width, recording: isRecordingThisMeeting, selection: $narrowPane
      ) {
        leftColumn(
          record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy,
          canDeliver: canDeliver)
      } transcript: {
        sessionTranscript(record, row: row, projection: projection, width: width)
      }
    } else if P.stacksPanes(width: width) {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.xxl) {
          leftColumn(
            record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy,
            canDeliver: canDeliver)
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            transcriptHeader(row: row, projection: projection)
            transcriptPane(record, row: row, projection: projection, loadsRoster: true)
          }
        }
        .padding(.horizontal, DesignSpacing.xl)
        .padding(.vertical, DesignSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(
        Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
      )
      .meetingUserScroll { suspendFollow() }
      .overlay(alignment: .bottom) { returnToPlaybackOverlay(projection: projection) }
    } else {
      HStack(spacing: DesignSpacing.xl) {
        // #4611 D1: each pane's header row stays put above its scrolling body.
        paneCard {
          leftHeader(snapshot: snapshot)
        } body: {
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            leftBody(
              record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy,
              canDeliver: canDeliver)
          }
          .padding(.horizontal, DesignSpacing.xl)
          .padding(.vertical, DesignSpacing.xl)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: P.notesPaneWidth(width: width))
        paneCard(onUserScroll: { suspendFollow() }) {
          transcriptHeader(row: row, projection: projection)
        } body: {
          transcriptPane(record, row: row, projection: projection, loadsRoster: true)
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, DesignSpacing.xl)
            .padding(.vertical, DesignSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) { returnToPlaybackOverlay(projection: projection) }
      }
    }
  }

  /// A pane: its header row, a divider, then its body scrolling under them.
  /// `onUserScroll`: a deliberate scroll of the body (the transcript's suspends Follow playback).
  private func paneCard<Header: View, Body: View>(
    onUserScroll: (() -> Void)? = nil,
    @ViewBuilder header: () -> Header, @ViewBuilder body: () -> Body
  ) -> some View {
    VStack(spacing: 0) {
      header()
        .padding(.horizontal, DesignSpacing.lg)
        .padding(.vertical, DesignSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      if let onUserScroll {
        ScrollView { body() }.meetingUserScroll(onUserScroll)
      } else {
        ScrollView { body() }
      }
    }
    .background(
      Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
    )
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
  }

  /// Whether this transcript can follow playback, and whether its turns carry times.
  private func transcriptOptions(_ projection: MeetingHistoryPresentation.Projection?)
    -> (canFollow: Bool, hasTimes: Bool)
  {
    guard case .visible(let turns, _)? = projection else { return (false, false) }
    // Same rule as the transcript page: following needs audio and at least one turn time.
    let hasTimes = turns.contains { $0.startMs != nil }
    return (playablePlayer != nil && hasTimes, hasTimes)
  }

  /// The player when it can play. A read failure keeps its player in `.unavailable` (the dock
  /// still shows why); turn times, note times and Follow offer playback only through this.
  private var playablePlayer: MeetingPlaybackController? {
    guard let player, player.state != .unavailable else { return nil }
    return player
  }

  /// #4611 D1 / D3: "Transcript", its Copy, and the settings button that holds Follow playback
  /// and Timestamps.
  @ViewBuilder
  fileprivate func transcriptHeader(
    row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    let options = transcriptOptions(projection)
    let canDeliver: Bool = {
      if case .visible? = projection { return true } else { return false }
    }()
    HStack(alignment: .center, spacing: DesignSpacing.md) {
      Text("Transcript", comment: "History meeting: the transcript pane's title.")
        .font(.stRowLabel)
        .foregroundStyle(.stTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      HStack(spacing: DesignSpacing.xs) {
        paneCopyButton(.transcript, isEnabled: canDeliver) { deliveryText() }
        MeetingTranscriptSettingsButton(
          follow: options.canFollow
            ? Binding(get: { follow != .off }, set: { follow = $0 ? .following : .off }) : nil,
          timestamps: options.hasTimes ? $timesOn : nil,
          followUnavailable: options.canFollow
            ? nil
            : playablePlayer == nil
              ? Text(
                "Needs audio",
                comment: "History meeting: why Follow playback is off, there is no recording.")
              : Text(
                "Needs timestamps",
                comment: "History meeting: why Follow playback is off, no turn has a time."),
          timestampsUnavailable: options.hasTimes
            ? nil
            : Text(
              "No times saved",
              comment: "History meeting: why Timestamps is off, this transcript has no times."))
      }
      .fixedSize()
    }
    .frame(minHeight: 34)
  }

  /// #4611 D4 / D13: floats over the bottom of the transcript only while following is paused by
  /// scrolling away (Follow playback still on); no strip otherwise.
  @ViewBuilder
  private func returnToPlaybackOverlay(projection: MeetingHistoryPresentation.Projection?)
    -> some View
  {
    // Founder 2026-11-17: with no turn reached yet (0:00, before the first turn) there is
    // nothing to return to, so the button does not show.
    if transcriptOptions(projection).canFollow, follow == .suspended,
      player?.state == .playing, activeTurnID != nil
    {
      returnToPlaybackButton
        .shadow(color: .black.opacity(0.28), radius: 9, y: 6)
        .padding(.bottom, DesignSpacing.xl)
    }
  }

  // MARK: - Header

  /// The shared page header (founder, #4611): back, previous / next and More at the right (D9),
  /// the title, then the facts row with "3 speakers" (who spoke) and the engine chip. Follow
  /// playback and Timestamps live in the transcript pane's settings (D3). Under it, only when they
  /// apply: who the calendar invited (#4286), the fallback engine note and a failure.
  private func header(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    let visibleTurns: [Turn] = {
      if case .visible(let turns, _)? = projection { return turns }
      return []
    }()
    let facts = facts(record, row: row)
    let participants = P.participants(turns: visibleTurns, speakerNames: row?.speakerNames ?? [:])
    let speakers: AnyView? =
      if let label = facts.speakers, !participants.isEmpty {
        AnyView(
          MeetingSpeakersButton(
            label: label, participants: participants,
            colorIndices: P.speakerColorIndices(turns: visibleTurns)))
      } else {
        nil
      }
    return HistoryDocumentHeader(
      tab: .meetings, back: back,
      facts: facts, neighbors: neighbors,
      // No Polished / Marked up / Original here (founder, #4611): it does not apply to meetings.
      showsViewRow: false,
      timestamps: nil,
      trailingNavigation: true, speakersAccessory: speakers, engineChip: true,
      engineInline: true
    ) {
      MeetingInlineTitle(meetingID: meetingID, font: .stDayTitle)
    } actions: {
      actions(record, row: row, projection: projection)
    } picker: {
      EmptyView()
    } switches: {
      EmptyView()
    } below: {
      if let invited = MeetingsPresentation.invitedLine(meetings.documents.context(meetingID)) {
        Text(verbatim: invited)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .textSelection(.enabled)
      }
      if record.transcriptEngineFallbackReason != nil, let used = record.transcriptEngineUsed {
        Text(MeetingsCopy.usedFallback(used))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let failure = MeetingsPresentation.failureLine(record) {
        Text(verbatim: failure)
          .font(.stBody)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
      statusStrip(record)
      HistoryPolishPreviewContent(preview: transcriptPolish)
      // #4611 D14: a new summary's progress shows in the summary pane; only its comparison
      // sheet hangs here, so it opens from either tab.
      summaryComparisonSheet
      noticeView
    }
  }

  /// The facts row: date, what is still happening (when not ready), the length, speakers,
  /// Recording deleted (its sentence on hover), the speech engine that wrote the transcript
  /// shown (#3973 C3), and the polish model only when the shown transcript was really polished.
  private func facts(_ record: MeetingRecord, row: Transcript?) -> HistoryDocumentFacts {
    let status = MeetingsPresentation.status(record, processingID: meetings.processing?.meetingID)
    let polish = row.map(HistoryTranscriptPresentation.provenance(for:))
    let unplayable: HistoryDocumentFacts.Unplayable? =
      P.dockAbsence(record) == .recordingDeleted
      ? .init(
        label: LocalizedStringResource(
          "Recording deleted",
          comment:
            "History meeting card footer: this meeting's recording was deleted. Hover gives the full sentence."
        ),
        reason: P.recordingDeletedLine)
      : nil
    return HistoryDocumentFacts(
      createdAt: record.createdAt,
      status: status == .ready ? nil : MeetingsPresentation.statusLabel(status),
      length: HistoryTranscriptPresentation.footerClock(
        seconds: Double(record.recordedDurationMs) / 1000),
      speakers: MeetingsPresentation.speakers(row?.speakerAnalysis),
      unplayable: unplayable,
      engine: record.transcriptEngineUsed?.backendType.displayName,
      polishModel: polish.flatMap { $0.aiPolished ? $0.polishModel : nil })
  }

  /// What is still being made: the transcript pass (with its progress), the queue, the summary.
  @ViewBuilder private func statusStrip(_ record: MeetingRecord) -> some View {
    if case .recording(let id, let startedAt) = meetings.phase, id == meetingID {
      MeetingLivePanel(
        meetingID: meetingID, startedAt: startedAt, callApp: record.callApp,
        microphoneAvailable: record.trackStatus[.microphone] == .captured)
    } else if case .stopping(let id) = meetings.phase, id == meetingID {
      if let line = P.stripLine(.finishingTranscript) { MeetingBusyLine(text: line) }
    } else if let processing = meetings.processing, processing.meetingID == meetingID {
      MeetingProcessingPanel(processing: processing)
    } else {
      // #4611 D14: a new version written for comparison shows in the summary pane, not here.
      let previewing = keepingSummary || meetings.summaries?.previews[meetingID] != nil
      let state = P.strip(
        record: record, processing: false, queueWaitsForSpace: meetings.queueWaitsForSpace,
        writingSummary: !previewing && (meetings.summaries?.isWriting(meetingID) ?? false),
        hasSummary: meetings.documents.summary(meetingID) != nil)
      let writingProvider = meetings.summaries?.writingProvider(for: meetingID)
      let statusLine: String? =
        if state == .writingSummary, let writingProvider {
          String(
            localized: "Writing the summary with \(writingProvider.displayName)…",
            comment: "History meeting: summary progress with the selected engine name.")
        } else {
          P.stripLine(state)
        }
      // #4611: a finished summary needs no line; the strip is only for work still going on.
      if let line = statusLine, state != .summaryReady {
        HStack(spacing: DesignSpacing.sm) {
          switch state {
          case .writingSummary, .waiting:
            ProgressView().controlSize(.small)
          case .summaryReady:
            Image(systemName: "checkmark.circle").foregroundStyle(.stSuccess)
              .accessibilityHidden(true)
          case .waitingForSpace:
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.stError)
              .accessibilityHidden(true)
          case .none, .finishingTranscript:
            EmptyView()
          }
          Text(verbatim: line)
            .font(.stHelper)
            .foregroundStyle(state == .waitingForSpace ? Color.stError : Color.stTextSecondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  // MARK: - Actions

  private func actions(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    let canDeliver: Bool = {
      if case .visible? = projection { return true }
      return false
    }()
    // #4611 D2: copying lives on each pane's own header row now.
    return moreButton(record, canDeliver: canDeliver)
      .fixedSize()
  }

  /// The app's own More menu (#4611), under a round button.
  private func moreButton(_ record: MeetingRecord, canDeliver: Bool) -> some View {
    HistoryDocumentMoreButton(anchor: moreAnchor) {
      guard let anchor = moreAnchor.view else { return }
      historyMenu.toggle(items: moreItems(record, canDeliver: canDeliver), from: anchor)
    }
  }

  /// The AI models that can write the summary again: the More menu's "Write summary again with"
  /// submenu, and the out-of-date notice's Refresh summary (#4611). Built when a menu opens.
  fileprivate func summaryModelItems(_ record: MeetingRecord, canDeliver: Bool) -> [HistoryMenuItem]
  {
    let savedSummary = meetings.documents.manifest(meetingID)?.summary?.inputs
    let available =
      committedRow(record) != nil && canDeliver && !isActive(record) && !actionInFlight
    return HistoryPolishMenu.menuItems(
      surface: .summary, choices: historyRepolish.choices(.summary),
      currentProvider: savedSummary?.providerID,
      currentModel: savedSummary?.modelOverride?.model,
      currentSize: savedSummary?.modelOverride?.egOneSize,
      isEnabled: available && !keepingSummary
        && meetings.summaries?.isWriting(meetingID) != true,
      select: { choice in beginSummaryPreview(choice) },
      setUp: {
        navigation.request(.meetings(.summaries))
        appWindowCoordinator.showWindow()
      })
  }

  /// The More menu's items, built when it opens, from the view's live state.
  private func moreItems(_ record: MeetingRecord, canDeliver: Bool) -> [HistoryMenuItem] {
    let offered = MeetingsPresentation.actions(
      record, isActive: isActive(record),
      canTranscribeAgain: meetings.canTranscribeAgain(meetingID) && !actionInFlight)
    let engines = meetings.transcribeAgainEngines
    let row = committedRow(record)
    let available = row != nil && canDeliver && !isActive(record) && !actionInFlight
    let labels = TranscriptDocumentPresenter.exportButtonLabels(mode: transcriptMode)
    let title = MeetingsPresentation.title(record)
    // No Rename: the title's pencil renames (founder #4611, 2026-11-17).
    var items: [HistoryMenuItem] = [
      .init(
        // #4611 D5: each delivery names what it delivers.
        id: "paste",
        title: String(
          localized: "Paste transcript into app",
          comment:
            "History meeting, More menu: pastes the visible transcript into the previous app."),
        systemImage: "arrow.right.doc.on.clipboard",
        isEnabled: !permissions.accessibilityGranted || canDeliver, kind: .action { pasteTapped() }),
      .init(
        id: "share",
        title: transcriptMode == .markedUp
          ? labels.share
          : String(
            localized: "Share transcript…",
            comment: "History meeting, More menu: shares the visible transcript."),
        systemImage: "square.and.arrow.up", isEnabled: canDeliver,
        kind: .action { share() }),
      .init(
        id: "save",
        title: transcriptMode == .markedUp
          ? labels.save
          : String(
            localized: "Save notes and transcript…",
            comment:
              "History meeting, More menu: saves the notes and the transcript as a text file."),
        systemImage: "square.and.arrow.down", isEnabled: canDeliver,
        kind: .action { save(defaultName: title) }),
      .divider("d1"),
    ]
    items.append(
      .init(
        id: "polish",
        title: String(
          localized: "Polish transcript with",
          comment:
            "History meeting, More menu: opens the list of AI models to polish the transcript again."
        ),
        systemImage: "sparkles",
        kind: .submenu(
          HistoryPolishMenu.menuItems(
            surface: .transcript, choices: historyRepolish.choices(.transcript),
            currentProvider: row?.llmProvider, currentModel: row?.llmModel,
            currentSize: row?.historyPolishEGOneSize,
            isEnabled: available && transcriptPolish.canStart,
            select: { choice in
              guard let row else { return }
              transcriptPolish.start(
                rowID: row.id, choice: choice, runner: historyRepolish, history: transcripts)
            },
            setUp: {
              navigation.request(.transcribeFile)
              appWindowCoordinator.showWindow()
            }))))
    items.append(
      .init(
        id: "summary",
        title: meetings.documents.summary(meetingID) == nil
          ? String(
            localized: "Write summary with",
            comment:
              "History meeting, More menu: opens the list of AI models to write the first summary.")
          : String(
            localized: "Write summary again with",
            comment:
              "History meeting, More menu: opens the list of AI models to write the summary again."),
        systemImage: "sparkles",
        kind: .submenu(summaryModelItems(record, canDeliver: canDeliver))))
    var speech: [HistoryMenuItem] = engines.map { engine in
      let title = MeetingTranscriptEngineRowTitles.title(of: engine)
      return .init(
        id: "asr-\(title)",
        title: engine == record.transcriptEngineUsed
          ? HistoryTranscriptView.currentChoiceTitle(title) : title,
        isEnabled: offered.transcribeAgain, kind: .action { pendingTranscription = engine })
    }
    if engines.isEmpty {
      // #4578 (plan §3.10 item 8): with no speech engine downloaded, say how to get one back.
      speech.append(
        .init(
          id: "asr-none",
          title: String(
            localized: "No speech models are ready",
            comment:
              "History transcript, Transcribe again with menu: no installed speech model can be used."
          ),
          isEnabled: false, kind: .action {}))
      speech.append(
        .init(
          id: "asr-setup",
          title: String(
            localized: "Download a speech engine in Settings to transcribe again.",
            comment:
              "History, Transcribe again with menu: tooltip while no speech engine is downloaded."),
          kind: .action {
            navigation.request(.transcribeFile)
            appWindowCoordinator.showWindow()
          }))
    }
    items.append(.divider("d2"))
    items.append(
      .init(
        id: "transcribe-again",
        title: String(
          localized: "Transcribe again with",
          comment:
            "History transcript, More menu: transcribes the original file again with a chosen speech model."
        ),
        systemImage: "arrow.clockwise", isEnabled: offered.transcribeAgain || engines.isEmpty,
        kind: .submenu(speech)))
    items.append(.divider("d3"))
    items.append(
      .init(
        id: "delete-recording",
        title: String(
          localized: "Delete recording, keep text",
          comment:
            "History meeting, More menu: deletes the meeting's audio; notes, transcript and summary stay."
        ),
        systemImage: "waveform.slash", isEnabled: offered.deleteAudio && !actionInFlight,
        isDestructive: true, kind: .action { confirming = .deleteAudio }))
    items.append(
      .init(
        id: "delete-meeting",
        title: String(
          localized: "Delete meeting",
          comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
        systemImage: "trash", isEnabled: offered.delete && !actionInFlight,
        isDestructive: true, kind: .action { confirming = .deleteMeeting }))
    return items
  }
  private func beginSummaryPreview(_ choice: HistoryPolishChoice) {
    summaryPolishNotice = false
    meetings.summaries?.startPreview(meetingID, with: choice)
  }

  /// #4611 D14: a new summary's progress, its save and its failure, inside the summary pane where
  /// the new text will land. The current summary stays under it until Keep new.
  @ViewBuilder fileprivate func summaryPreviewInPane(
    refreshItems: @escaping () -> [HistoryMenuItem]
  ) -> some View {
    if let summaries = meetings.summaries {
      if keepingSummary {
        InsetNotice(
          verbatim: String(
            localized: "Saving…", comment: "History meeting: the kept new summary is being saved."),
          busy: true
        ) { EmptyView() }
      } else if let preview = summaries.previews[meetingID] {
        switch preview {
        case .generating:
          InsetNotice(
            verbatim: String(
              localized: "Your current summary stays until you pick.",
              comment: "History meeting: under Writing a new summary; nothing is replaced yet."),
            title: String(
              localized: "Writing a new summary…",
              comment: "History meeting: a new summary is being written for comparison."),
            busy: true
          ) {
            Button {
              summaries.discardPreview(meetingID)
            } label: {
              EnviousButtonLabel(
                LocalizedStringResource(
                  "Cancel", comment: "History meeting: stops writing the new summary."),
                size: .medium)
            }
            .settingsButton(.quiet, size: .medium, isEnabled: true)
          }
        case .comparing:
          EmptyView()
        case .failed:
          // Founder 2026-11-17: the failure read like part of the summary; it is a warning box
          // with the way to try again.
          summaryProblemNotice(
            title: String(
              localized: "Couldn't write a new summary.",
              comment: "History meeting: writing a new summary for comparison failed."),
            refreshItems: refreshItems,
            dismiss: { meetings.summaries?.discardPreview(meetingID) })
        }
      } else if summaryPolishNotice {
        summaryProblemNotice(
          title: String(
            localized: "The saved summary changed.",
            comment:
              "History meeting: the summary changed while a new one was being kept, so it was not saved."
          ),
          refreshItems: refreshItems,
          dismiss: { summaryPolishNotice = false })
      }
    }
  }

  /// A failed new summary (founder 2026-11-17: the same box as the out-of-date notice, nudging to
  /// a different model): a warning saying so, Try another model (the same list as the More
  /// menu's "Write summary again with") and Dismiss.
  private func summaryProblemNotice(
    title: String, refreshItems: @escaping () -> [HistoryMenuItem], dismiss: @escaping () -> Void
  ) -> some View {
    InsetNotice(
      verbatim: String(
        localized: "Try writing it with a different model.",
        comment:
          "History meeting: under a failed new summary; nudges the user to pick another AI model."),
      title: title, systemImage: "exclamationmark.triangle", tint: .stWarning
    ) {
      MeetingSummaryModelMenuButton(
        title: LocalizedStringResource(
          "Try another model",
          comment:
            "History meeting: after a failed new summary, opens the list of AI models to try again."
        ),
        items: refreshItems)
      Button(action: dismiss) {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Dismiss", comment: "History meeting: hides the failed new summary message."),
          size: .medium)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
    }
    .accessibilityIdentifier("history.meeting.summaryPreviewFailed")
  }

  /// #4611 D8: the new summary beside the current one, in a sheet over the page, from either tab.
  @ViewBuilder private var summaryComparisonSheet: some View {
    if let summaries = meetings.summaries, !keepingSummary,
      case .comparing(let candidate)? = summaries.previews[meetingID]
    {
      HistoryPolishComparison(
        current: candidate.current ?? String(localized: "No summary yet"),
        new: candidate.text, model: candidate.choice.title,
        title: LocalizedStringResource(
          "Compare summaries",
          comment: "History meeting: the sheet comparing the current and the new summary."),
        formatted: true,
        keep: {
          keepingSummary = true
          Task {
            summaryPolishNotice =
              !(await summaries.keepPreview(meetingID, candidateID: candidate.id))
            keepingSummary = false
          }
        },
        discard: { summaries.discardPreview(meetingID) }
      )
      .id(candidate.id)
    }
  }

  private var confirmingBinding: Binding<Bool> {
    Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
  }

  /// The delete confirmation's title; the orphan page asks for `.deleteMeeting`.
  static func confirmationTitle(_ kind: Confirmation?) -> String {
    switch kind {
    case .deleteAudio?:
      return String(
        localized: "Delete this meeting's recording?",
        comment: "History meeting: confirmation title before deleting only the audio.")
    case .deleteMeeting?, nil:
      return String(
        localized: "Delete this meeting?",
        comment: "History meeting: confirmation title before deleting the whole meeting.")
    }
  }

  static func confirmationMessage(_ kind: Confirmation) -> String {
    switch kind {
    case .deleteAudio:
      return String(
        localized:
          "Notes, transcript and summary stay. The recording is permanently deleted, so you can't play it or transcribe it again.",
        comment: "History meeting page: confirmation message before deleting only the recording.")
    case .deleteMeeting:
      return String(
        localized:
          "Its notes, transcript, summary and recording are removed from this Mac. This can't be undone.",
        comment: "History meeting page: confirmation message before deleting the whole meeting.")
    }
  }

  private func isActive(_ record: MeetingRecord) -> Bool {
    if meetings.processing?.meetingID == record.id { return true }
    switch meetings.phase {
    case .recording(let id, _), .stopping(let id): return id == record.id
    case .starting, .idle: return false
    }
  }

  // MARK: - Commands

  /// The visible words of the CURRENT row, read at delivery (Copy press, Share request, Paste).
  /// Copy, Share and Save follow the Timestamps setting; Paste passes `includeTimes: false`.
  private func deliveryText(
    mode: FileImportCoordinator.DocumentView? = nil, includeTimes: Bool? = nil
  ) -> String? {
    guard let row = deliveryRow() else { return nil }
    return MeetingHistoryPresentation.deliveryText(
      row, projection: transcripts.meetingProjection(of: row),
      timesOn: includeTimes ?? timesOn, mode: mode ?? transcriptMode)
  }

  /// The row whose words are delivered now: the committed row of a meeting EnviousMeet holds
  /// (nothing while it is being deleted), else the row of a meeting whose folder is gone.
  private func deliveryRow() -> Transcript? {
    if let record = meetings.record(id: meetingID) {
      guard !record.deletionRequested, record.committedTranscriptGeneration != nil else {
        return nil
      }
      return transcripts.verifiedRowForDelivery(id: record.transcriptID)
    }
    guard let orphanRow else { return nil }
    return transcripts.verifiedRowForDelivery(id: orphanRow.id)
  }

  private func perform(_ kind: Confirmation) {
    confirming = nil
    // A meeting whose folder is gone deletes from `MeetingOrphanPage`.
    guard !actionInFlight, meetings.record(id: meetingID) != nil else { return }
    // Playback stops before any file of this meeting is touched.
    dropPlayer()
    actionInFlight = true
    notice = nil
    let scope: HistoryDeleteKind = kind == .deleteAudio ? .recordingsOnly : .textAndRecordings
    let shown = presentation
    Task {
      let outcome = await transcripts.deleteHistoryItem(id: .meeting(meetingID), kind: scope)
      guard shown == presentation else { return }
      actionInFlight = false
      // A refused or unsaved deletion leaves the audio: bring its player back.
      reconcilePlayer()
      if HistoryDictationPresentation.deletionFailed(outcome) {
        notice = Notice(
          text: kind == .deleteAudio
            ? String(
              localized: "The recording couldn't be deleted. Try again.",
              comment: "History meeting: Delete recording, keep text failed.")
            : String(
              localized: "The meeting couldn't be deleted. Try again.",
              comment: "History meeting: Delete meeting failed."),
          isError: true, retry: kind)
      }
    }
  }

  private func transcribeAgain(_ engine: MeetingEngineChoice) {
    guard !actionInFlight, meetings.record(id: meetingID) != nil else { return }
    actionInFlight = true
    notice = nil
    let coordinator = meetings
    let id = meetingID
    let shown = presentation
    Task {
      let started = await coordinator.transcribeAgain(meetingID: id, engine: engine)
      guard shown == presentation else { return }
      actionInFlight = false
      if !started {
        notice = Notice(
          text: String(
            localized: "Transcribe again couldn't start. Try again in a moment.",
            comment: "History meeting: Transcribe again with was refused."),
          isError: true)
      }
    }
  }

  private func pasteTapped() {
    guard permissions.accessibilityGranted else {
      navigation.request(.appSettings(.permissions))
      return
    }
    // #4101: into the app the user came from, with the text read at the press.
    historyPaste.paste(
      destination: previousApplication.lastOtherApplication,
      allowed: { true },
      text: { deliveryText(mode: .cleaned, includeTimes: false) },
      showHistory: { restorePasteSurface() },
      showNotice: { showPasteNotice($0) })
  }

  /// The text is read when the receiving app asks for it, so a sheet left open never hands over
  /// lines that were deleted or hidden meanwhile.
  private func share() {
    HistoryDelivery.share(from: moreAnchor.view) { deliveryText() }
  }

  /// The document is read AFTER the panel closes, so a meeting deleted meanwhile saves nothing.
  private func save(defaultName: String) {
    guard let row = deliveryRow() else { return }
    let rowID = row.id
    HistoryDelivery.save(
      defaultName: defaultName,
      document: {
        switch await MeetingExport.document(
          meetingID: meetingID, rowID: rowID, documents: meetings.documents,
          transcripts: transcripts, mode: transcriptMode, timesOn: timesOn)
        {
        case .document(let document):
          return .text(document)
        case .notesUnreadable:
          return .refused(
            String(
              localized: "Your notes could not be read, so nothing was saved. Try again.",
              comment:
                "History, a meeting: Save stopped because the meeting's notes file could not be read."
            ))
        case .nothingToDeliver:
          return .nothing
        }
      },
      onError: { saveError = $0 })
  }

  // MARK: - Player

  /// Keeps a player only for the meeting's current playable source: the same source keeps it
  /// (and its place), a changed inventory or length replaces it, and no source drops it.
  private func reconcilePlayer() {
    let source = meetings.playbackSource(meetingID: meetingID)
    switch MeetingPlaybackSource.change(from: player == nil ? nil : playerSource, to: source) {
    case .keep:
      return
    case .drop:
      dropPlayer()
    case .replace:
      let rate = player?.playbackRate ?? retainedRate
      dropPlayer()
      if let source {
        // #3147: known to the shared now-playing owner, so another recording starting pauses
        // this one and a deletion stops it before its files go.
        let next = MeetingPlaybackController(
          source: source, output: MeetingPlaybackEngineOutput(), meetingID: meetingID,
          arbiter: meetings.playbackArbiter)
        next.setPlaybackRate(rate)
        player = next
        playerSource = source
      }
    }
  }

  private func dropPlayer() {
    if let player { retainedRate = player.playbackRate }
    player?.stop()
    player = nil
    playerSource = nil
  }

  // MARK: - Dock

  /// #4611 D10: the player card under the panes. Who spoke lives in the header's speakers button
  /// (D9), so a meeting with no recording to play has no card; the facts line says why.
  @ViewBuilder
  private func dock(_ record: MeetingRecord) -> some View {
    let absence = P.dockAbsence(record)
    // Only a recording still being made ready keeps its card.
    if player != nil || absence == .notReadyYet {
      MeetingAfterPlayerBar(content: player.map { .player($0) } ?? .unavailable(absence))
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.bottom, DesignSpacing.xl)
    }
  }

  // MARK: - Follow playback

  private func showNote(_ id: UUID) {
    leftPane = .notes
    narrowPane = .notes
    // A note shown from a marker or View source opens in read mode, where it is highlighted
    // (#4611: the edit state lives here, and a recreated notes pane sees no request change).
    editingNotes = false
    highlightedNoteID = id
    noteRequest = NoteRequest(id: id)
  }

  private func suspendFollow() {
    // Same as the transcript page: scrolling suspends following only while playing.
    guard player?.state == .playing else { return }
    if follow == .following { follow = .suspended }
  }
}

// MARK: - Left pane

extension HistoryMeetingAfterView {
  /// The left pane's header row and body together, for the layouts that scroll them as one
  /// (stacked panes, the meeting still on screen from its recording).
  @ViewBuilder
  fileprivate func leftColumn(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, visibleTurnIDs: Set<String>,
    proxy: ScrollViewProxy, canDeliver: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      if !isRecordingThisMeeting {
        leftHeader(snapshot: snapshot)
      }
      leftBody(
        record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy,
        canDeliver: canDeliver)
    }
  }

  /// #4611 D1: one row: Your notes | AI summary, then Edit and Copy for the tab shown. D6: while
  /// the summary is edited, a full-width row under it carries the save status and Done editing.
  fileprivate func leftHeader(snapshot: MeetingNotesSnapshot) -> some View {
    let summaryBusy =
      keepingSummary || meetings.summaries?.isWriting(meetingID) == true
      || {
        if case .generating? = meetings.summaries?.previews[meetingID] {
          return true
        } else {
          return false
        }
      }()
    return VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      HStack(alignment: .center, spacing: DesignSpacing.md) {
        BrandedSegmentedPicker(
          options: [
            (
              String(
                localized: "Your notes", comment: "History meeting: the user's own notes pane."),
              nil, P.LeftPane.notes
            ),
            (
              String(
                localized: "AI summary", comment: "History meeting: the meeting summary pane."),
              nil, P.LeftPane.summary
            ),
          ],
          selection: $leftPane,
          hint: { pane in
            switch pane {
            case .notes:
              String(
                localized: "Your own notes for this meeting",
                comment: "History meeting: hover hint on the Your notes tab.")
            case .summary:
              summaryBusy
                ? String(
                  localized: "AI summary, writing a new version",
                  comment:
                    "History meeting: hover hint on the AI summary tab while a summary is written.")
                : String(
                  localized: "The AI-written summary of this meeting",
                  comment: "History meeting: hover hint on the AI summary tab.")
            }
          },
          busy: { $0 == .summary && summaryBusy }
        )
        .fixedSize()
        .accessibilityLabel(
          Text(
            "Notes or summary",
            comment: "History meeting: chooses between the user's notes and the AI summary."))
        Spacer(minLength: 0)
        if !(leftPane == .summary && editingSummary) {
          paneActions(snapshot: snapshot)
        }
      }
      if leftPane == .summary, editingSummary {
        HStack(alignment: .center, spacing: DesignSpacing.md) {
          Text(
            meetings.documents.hasUnsavedSummary(meetingID)
              ? String(localized: "Saving…", comment: "History meeting: the notes are being saved.")
              : String(
                localized: "Saved on this Mac", comment: "History meeting: the notes are saved.")
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          Spacer(minLength: 0)
          Button {
            editingSummary = false
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Done editing", comment: "History meeting: ends editing the summary or the notes."),
              size: .medium)
          }
          .settingsButton(.filled, size: .medium, isEnabled: true)
        }
      }
    }
  }

  /// Edit (or Done editing) and Copy for the tab shown. Visible words stay short ("Edit",
  /// "Copy"); the spoken name and tooltip say what each acts on.
  @ViewBuilder
  fileprivate func paneActions(snapshot: MeetingNotesSnapshot) -> some View {
    switch leftPane {
    case .notes:
      let editing = editingNotes ?? (openedDuringRecording == meetingID)
      let notesText = meetings.documents.notes(meetingID)
      let hasNotes = !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      HStack(spacing: DesignSpacing.xs) {
        if editing {
          Button {
            editingNotes = false
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Done editing", comment: "History meeting: ends editing the summary or the notes."),
              size: .medium, systemImage: "checkmark")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        } else if snapshot.canEdit, hasNotes {
          paneEditButton(
            spoken: String(
              localized: "Edit notes", comment: "History meeting: makes the notes editable.")
          ) { editingNotes = true }
        }
        paneCopyButton(.notes, isEnabled: hasNotes) { meetings.documents.notes(meetingID) }
      }
      .fixedSize()
    case .summary:
      let summary = meetings.documents.summary(meetingID)
      let hasSummary = summary.map { !$0.isEmpty } ?? false
      HStack(spacing: DesignSpacing.xs) {
        if references.document(for: meetingID) != nil || summary != nil {
          paneEditButton(
            spoken: String(
              localized: "Edit summary", comment: "History meeting: makes the summary editable.")
          ) { editingSummary = true }
        }
        paneCopyButton(.summary, isEnabled: hasSummary) { meetings.documents.summary(meetingID) }
      }
      .fixedSize()
    }
  }

  fileprivate func paneEditButton(spoken: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Edit", comment: "History meeting: a pane's Edit button (notes or summary)."),
        size: .medium, systemImage: "pencil")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
    .help(Text(verbatim: spoken))
    .accessibilityLabel(Text(verbatim: spoken))
  }

  /// What a pane's Copy copies.
  enum PaneCopy: Equatable {
    case notes, summary, transcript

    var spoken: String {
      switch self {
      case .notes:
        String(localized: "Copy notes", comment: "History meeting: copies the meeting's notes.")
      case .summary:
        String(localized: "Copy summary", comment: "History meeting: copies the AI summary.")
      case .transcript:
        String(
          localized: "Copy transcript", comment: "History meeting: copies the visible transcript.")
      }
    }
  }

  /// #4611 D1: Copy reads the pane's latest text when pressed (empty text copies nothing), then
  /// shows Copied for 2 s at the same width and says so to VoiceOver. One Copied for the page:
  /// copying another pane clears the previous pane's.
  fileprivate func paneCopyButton(
    _ kind: PaneCopy, isEnabled: Bool, text: @escaping () -> String?
  ) -> some View {
    let feedback = Binding<Date?>(
      get: { copiedPane == kind ? copiedPaneAt : nil },
      set: { pressed in
        if let pressed {
          copiedPane = kind
          copiedPaneAt = pressed
        } else if copiedPane == kind {
          copiedPane = nil
        }
      })
    return HistoryPaneCopyButton(spoken: kind.spoken, isEnabled: isEnabled, feedback: feedback) {
      text().flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  @ViewBuilder
  fileprivate func leftBody(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, visibleTurnIDs: Set<String>,
    proxy: ScrollViewProxy, canDeliver: Bool
  ) -> some View {
    switch leftPane {
    case .notes:
      MeetingAfterNotesPane(
        meetingID: meetingID, notes: notes, snapshot: snapshot,
        highlightedNoteID: highlightedNoteID,
        requestNonce: noteRequest?.nonce,
        onPlayFrom: { ms in
          player?.seek(toMs: ms)
          player?.play()
        },
        playbackAvailable: playablePlayer != nil,
        playbackMs: { notesClockMs() },
        startsEditing: isRecordingThisMeeting || openedDuringRecording == meetingID,
        editing: $editingNotes,
        recording: isRecordingThisMeeting,
        markMoment: markMoment,
        toggleActionItem: toggleLiveActionItem,
        editorActions: notesActions)
    case .summary:
      summaryPane(
        record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy,
        canDeliver: canDeliver)
    }
  }

  private func markMoment() {
    guard let time = meetings.recordingPositionMs(meetingID: meetingID) else { return }
    notesActions.append(
      MeetingNoteBlock(kind: .mark, text: String(localized: "Moment marked")),
      for: meetingID, atMs: time)
  }

  private func toggleLiveActionItem() {
    guard isRecordingThisMeeting else { return }
    notesActions.toggleTask(for: meetingID)
  }

  private func addQuote(_ run: MeetingsPresentation.LiveBlock.Run) {
    guard run.kind == .confirmed, let time = meetings.recordingPositionMs(meetingID: meetingID),
      let live = meetings.liveTranscript, live.meetingID == meetingID,
      MeetingsPresentation.liveBlocks(live.lines, labels: live.speakerLabels)
        .lazy.flatMap(\.runs).contains(run)
    else { return }
    let speaker = MeetingsPresentation.liveSpeakerHeader(
      run.speaker, names: live.speakerLabels.names)
    let text = run.text.split(whereSeparator: \.isNewline).joined(separator: " ")
    notesActions.append(
      MeetingNoteBlock(kind: .quote, text: text, sourceSpeaker: speaker, sourceMs: run.startMs),
      for: meetingID, atMs: time)
  }

  /// #3147 PR4A: where a new note block starts on the meeting timeline (plan §3.6). While this
  /// meeting records, its recorded position (the recorder's clock); after Stop, the play bar's
  /// current position once the recording has played or been moved; else unknown (no time).
  @MainActor fileprivate func notesClockMs() -> Int? {
    if case .recording(let id, _) = meetings.phase, id == meetingID {
      return meetings.recordingPositionMs(meetingID: meetingID)
    }
    guard let player, player.hasPosition else { return nil }
    return player.positionMs
  }

  @ViewBuilder
  fileprivate func summaryPane(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, visibleTurnIDs: Set<String>,
    proxy: ScrollViewProxy, canDeliver: Bool
  ) -> some View {
    let refreshItems = { summaryModelItems(record, canDeliver: canDeliver) }
    summaryPreviewInPane(refreshItems: refreshItems)
    if !editingSummary, let document = references.document(for: meetingID) {
      MeetingAfterSummarySections(
        meetingID: meetingID, document: document, references: references,
        visibleTurnIDs: visibleTurnIDs,
        noteBlockIDs: Set(snapshot.document.blocks.map(\.id)),
        sourceMs: { target in sourceMs(target, record: record, snapshot: snapshot) },
        onViewSource: { target in viewSource(target, proxy: proxy) })
    } else if !editingSummary, let text = meetings.documents.summary(meetingID) {
      readableSummary(text, refreshItems: refreshItems)
    } else {
      // Editing, writing, problems, save failure and edited-summary protection; also every
      // state before a summary exists. Edit summary and Done editing sit on the tab row.
      MeetingSummaryView(
        meetingID: meetingID, writePreview: beginSummaryPreview, refreshItems: refreshItems)
    }
  }

  /// #4611 D12: the meeting time a summary source sits at, for its link ("Your notes · 0:28").
  fileprivate func sourceMs(
    _ target: MeetingAfterPresentation.SourceTarget, record: MeetingRecord,
    snapshot: MeetingNotesSnapshot
  ) -> Int? {
    switch target {
    case .note(let id):
      return snapshot.document.blocks.first { $0.id == id }?.startedAtMs
    case .turn(let id):
      guard let row = committedRow(record),
        case .visible(let turns, _) = transcripts.meetingProjection(of: row)
      else { return nil }
      return turns.first { $0.id == id }?.startMs
    }
  }

  /// A summary with no validated structure (an edited, older or unqualified summary), read
  /// only, with no links. Edit summary opens the full summary controls.
  fileprivate func readableSummary(
    _ text: String, refreshItems: @escaping () -> [HistoryMenuItem]
  ) -> some View {
    let documents = meetings.documents
    return VStack(alignment: .leading, spacing: DesignSpacing.md) {
      MeetingSummaryStaleNotice(meetingID: meetingID, refreshItems: refreshItems)
      if documents.summarySaveFailed(meetingID) {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
          Text(
            "Your summary changes could not be saved.",
            comment:
              "History, a meeting: saving the user's edits to the summary failed; the edits stay in the app until a save works."
          )
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            Task { await documents.flushSummary(meetingID) }
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Try again", comment: "History, a meeting: saves the summary changes again."),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
        .font(.stHelper)
      }
      MeetingReadableSummary(blocks: Self.readableBlocks(text))
    }
  }

  /// One line of a summary drawn read-only: a heading (`#` to `######`), a bullet (`- `, `* `,
  /// `+ `), a paragraph line, or a gap between paragraphs (UAT: the read mode showed the raw
  /// Markdown markers).
  enum ReadableBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
    case gap
  }

  /// The summary's lines as headings, bullets and paragraphs, markers removed, in order. Runs of
  /// blank lines become one gap; leading and trailing gaps are dropped.
  static func readableBlocks(_ markdown: String) -> [ReadableBlock] {
    var blocks: [ReadableBlock] = []
    for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let block: ReadableBlock
      if line.isEmpty {
        block = .gap
      } else if let heading = headingText(line) {
        block = .heading(heading)
      } else if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
        block = .bullet(String(line.dropFirst(marker.count)))
      } else {
        block = .paragraph(line)
      }
      if block == .gap, blocks.last == .gap || blocks.isEmpty { continue }
      blocks.append(block)
    }
    if blocks.last == .gap { blocks.removeLast() }
    return blocks
  }

  /// The text of a Markdown heading line (one to six `#`, then a space), or nil.
  private static func headingText(_ line: String) -> String? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return rest.trimmingCharacters(in: .whitespaces)
  }

  /// The summary's Markdown with inline emphasis kept and its lines as written; plain text when
  /// it does not parse. No run carries its own font, so the 14 pt body size holds.
  /// Links are removed: only View source, after validation, may lead anywhere.
  static func readable(_ markdown: String) -> AttributedString {
    var text =
      (try? AttributedString(
        markdown: markdown,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(markdown)
    text.link = nil
    return text
  }

  /// View source: scroll to and highlight the source. Never starts playback.
  fileprivate func viewSource(
    _ target: MeetingAfterPresentation.SourceTarget, proxy: ScrollViewProxy
  ) {
    switch target {
    case .turn(let id):
      if follow == .following { follow = .suspended }
      highlightedTurnID = id
      withAnimation { proxy.scrollTo(TurnRowKey(turnID: id, occurrence: 0), anchor: .center) }
    case .note(let id):
      // Cloud review P2: in the stacked layout the notes and transcript share one scroll view,
      // so following playback would scroll the cited note out of view.
      suspendFollow()
      showNote(id)
    }
  }
}

// MARK: - Transcript pane

extension HistoryMeetingAfterView {
  /// Over the bottom of the transcript while the reader has scrolled away from what plays
  /// (#4611 D13).
  fileprivate var returnToPlaybackButton: some View {
    HistoryReturnToPlaybackButton {
      follow = .following
      highlightedTurnID = nil
    }
  }

  @ViewBuilder
  fileprivate func sessionTranscript(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?,
    width: CGFloat
  ) -> some View {
    if isRecordingThisMeeting, let live = meetings.liveTranscript, live.meetingID == meetingID {
      MeetingLiveWordsView(transcript: live, addQuote: addQuote)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.lg) {
          transcriptHeader(row: row, projection: projection)
          // No speaker roster while recording, or while the narrow layout shows the notes tab
          // (the hidden transcript stays mounted).
          transcriptPane(
            record, row: row, projection: projection,
            loadsRoster: !isRecordingThisMeeting
              && (!P.stacksPanes(width: width) || narrowPane == .transcript))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .meetingUserScroll { suspendFollow() }
      .overlay(alignment: .bottom) { returnToPlaybackOverlay(projection: projection) }
    }
  }

  /// The transcript pane (its words, state lines, echo toggle, permission note and the speaker
  /// roster it alone reads). `loadsRoster` is false where the transcript is not on screen.
  fileprivate func transcriptPane(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?,
    loadsRoster: Bool
  ) -> some View {
    MeetingAfterTranscriptPane(
      meetingID: meetingID, record: record, row: row, projection: projection,
      player: playablePlayer, highlightedTurnID: highlightedTurnID,
      activeTurnID: follow == .off ? nil : activeTurnID, mode: transcriptMode, timesOn: timesOn,
      didReadTranscript: didReadTranscript,
      canTranscribeAgain: meetings.canTranscribeAgain(meetingID) && !actionInFlight,
      loadsRoster: loadsRoster)
  }
}

// MARK: - Parts

/// The visible turns, one row each, keyed for View source and Follow playback. Each row is the
/// shared `TurnDocumentView` row (speaker rename popover, "play from here"), so rename writes,
/// failures and telemetry stay on `TranscriptCoordinator`. Compared on its data, player
/// identity and highlights, so a parent update with unchanged inputs skips turn preparation.
struct MeetingAfterTurnList: View, Equatable {
  let rowID: UUID
  let turns: [Turn]
  let rawText: String
  let speakerNames: [String: String]
  let player: MeetingPlaybackController?
  let renameSuggestions: SpeakerRenameSuggestions
  let highlightedTurnID: String?
  let activeTurnID: String?
  var language: String? = nil
  var mode: FileImportCoordinator.DocumentView = .cleaned
  /// The page's Timestamps switch; off hides each turn's start time.
  var timesOn = true
  @Environment(TranscriptCoordinator.self) private var transcripts
  @State private var diffCache: (FileImportCoordinator.TurnDiffInput, [String: WordDiff.Result])?

  nonisolated static func == (a: MeetingAfterTurnList, b: MeetingAfterTurnList) -> Bool {
    a.rowID == b.rowID && a.player === b.player && a.renameSuggestions == b.renameSuggestions
      && a.mode == b.mode && a.language == b.language && a.timesOn == b.timesOn
      && a.highlightedTurnID == b.highlightedTurnID && a.activeTurnID == b.activeTurnID
      && MeetingDocumentHash.sameBytes(a.rawText, b.rawText)
      && MeetingDocumentHash.sameBytes(a.speakerNames, b.speakerNames)
      && TranscriptTurnsDocument.Inputs.sameTurns(a.turns, b.turns)
  }

  var body: some View {
    let input =
      mode == .markedUp
      ? TranscriptTurnsDocument.diffInput(turns: turns, text: rawText, language: language) : nil
    let diffs = input.flatMap { input in
      diffCache.flatMap { cached in
        TranscriptTurnsDocument.DiffKey.sameInput(input, cached.0) ? cached.1 : nil
      }
    }
    let rendered =
      MeetingGapPresentation.localized(
        TranscriptDocumentPresenter.render(
          turns: turns, rawText: rawText, speakerNames: speakerNames,
          mode: mode, timesOn: timesOn, documentFinished: true, diffLookup: { diffs?[$0.id] }))
      ?? []
    LazyVStack(alignment: .leading, spacing: DesignSpacing.md) {
      // Speaker colors and "same speaker skips the name" are worked out over the whole
      // meeting (#4611), since each turn below is its own one-turn document.
      ForEach(TurnSpeakerStyle.rows(rendered), id: \.key) { row in
        let key = row.key
        let turn = row.turn
        TurnDocumentView(
          turns: [turn],
          onRename: { speakerId, name in
            await transcripts.renameSpeaker(
              id: rowID, speakerId: speakerId, name: name, isMeeting: true)
          },
          onPlayFrom: player.map { player in
            { startMs in
              player.seek(toMs: startMs)
              player.play()
            }
          },
          renameSuggestions: renameSuggestions,
          timeFont: .stHelper,
          speakerLook: row.look,
          fallback: { EmptyView() }
        )
        .padding(DesignSpacing.sm)
        .background(
          background(for: turn.turnID), in: RoundedRectangle(cornerRadius: DesignRadius.md)
        )
        .id(key)
      }
    }
    .task(id: TranscriptTurnsDocument.DiffKey(input: input, markedUp: mode == .markedUp)) {
      guard let input, diffs == nil else { return }
      let computed = await TranscriptTurnsDocument.computeDiffs(input)
      guard !Task.isCancelled else { return }
      diffCache = (input, computed)
    }
  }

  private func background(for turnID: String) -> Color {
    if turnID == highlightedTurnID { return Color.stAccent.opacity(0.18) }
    if turnID == activeTurnID { return Color.stAccent.opacity(0.08) }
    return .clear
  }
}

/// Reads the player's position (so a tick re-renders only this invisible view), reports the
/// turn playback is in, and scrolls to it while Follow playback is on. The transcript page uses
/// it too (#4611 T8).
struct MeetingFollowDriver: View {
  let player: MeetingPlaybackController
  let turns: [Turn]
  @Binding var activeTurnID: String?
  let following: Bool
  let scroll: (String) -> Void
  /// #4611 T8 (transcript page): also brings the playing turn into view when playback starts or
  /// resumes inside the same turn. The meeting page keeps its behavior (off).
  var scrollsWhenPlaybackStarts = false

  var body: some View {
    let active = MeetingAfterPresentation.activeTurnID(turns: turns, positionMs: player.positionMs)
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onChange(of: active, initial: true) { _, now in
        activeTurnID = now
        if following, player.state == .playing, let now {
          withAnimation { scroll(now) }
        }
      }
      .onChange(of: following) { _, now in
        if now, let active { withAnimation { scroll(active) } }
      }
      .onChange(of: player.state) { _, state in
        guard scrollsWhenPlaybackStarts, following, state == .playing, let active else { return }
        withAnimation { scroll(active) }
      }
  }
}

/// Your notes, from the app-owned draft (`MeetingNotesAccessing`): each block with its meeting
/// time (choosing it moves playback there without playing), task ticks, quotes with their
/// speaker, and whether the notes are saved on this Mac (with Try again after a failed save).
private struct MeetingAfterNotesPane: View {
  let meetingID: UUID
  let notes: any MeetingNotesAccessing
  let snapshot: MeetingNotesSnapshot
  let highlightedNoteID: UUID?
  /// A new marker or View source request, even for the same note: it leaves edit mode.
  let requestNonce: UUID?
  /// Plays the recording from a note's time (a click on the time, in read or edit mode).
  let onPlayFrom: (Int) -> Void
  /// False once the recording is gone or unreadable: note times are then plain text.
  let playbackAvailable: Bool
  /// #3147 PR4A: the playback position, so a block typed after Stop starts there (plan §3.6).
  let playbackMs: @MainActor () -> Int?
  let startsEditing: Bool
  /// #4611: owned by the page, whose tab row draws Edit notes and Done editing.
  @Binding var editing: Bool?
  let recording: Bool
  let markMoment: () -> Void
  let toggleActionItem: () -> Void
  let editorActions: MeetingNotesEditorActions
  // Read mode keeps note times as seek buttons and the marker highlight; Edit notes swaps in
  // the block editor, as Edit summary does for the summary.

  var body: some View {
    Group {
      if editing ?? startsEditing {
        editor
      } else {
        reader
      }
    }
    // A marker or View source that points at a note shows it in read mode, where it is
    // highlighted and its time seeks.
    .onChange(of: requestNonce) { _, nonce in
      if nonce != nil { editing = false }
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      if recording {
        ViewThatFits(in: .horizontal) {
          HStack { liveNoteControls }
          VStack(alignment: .leading) { liveNoteControls }
        }
      }
      MeetingNotesBlockEditor(
        meetingID: meetingID, notes: notes, currentMs: playbackMs, playFrom: playbackAvailable ? onPlayFrom : nil,
        actions: editorActions)
    }
  }

  @ViewBuilder
  private var liveNoteControls: some View {
    Button(action: markMoment) {
      EnviousButtonLabel("Mark moment", size: .medium, systemImage: "flag")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: snapshot.canEdit)
    .disabled(!snapshot.canEdit)
    .keyboardShortcut("m", modifiers: [.command, .shift])
    Button(action: toggleActionItem) {
      EnviousButtonLabel("Action item", size: .medium, systemImage: "checklist")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: snapshot.canEdit)
    .disabled(!snapshot.canEdit)
  }

  private var reader: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      saveLine
      let blocks = snapshot.document.blocks.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if blocks.isEmpty, snapshot.saveState != .loading {
        // #4611 D16: Write notes starts writing, as Write summary does for the summary.
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          Text(
            "No notes for this meeting.",
            comment: "History meeting: the notes pane of a meeting without notes."
          )
          .font(.stCardText)
          .foregroundStyle(.stTextSecondary)
          if snapshot.canEdit {
            Button {
              editing = true
            } label: {
              EnviousButtonLabel(
                LocalizedStringResource(
                  "Write notes", comment: "History meeting: starts writing notes for this meeting."),
                size: .medium)
            }
            .settingsButton(.outlined, size: .medium, isEnabled: true)
          }
        }
      }
      ForEach(blocks) { block in
        blockRow(block)
          .padding(DesignSpacing.xs)
          .background(
            block.id == highlightedNoteID ? Color.stAccent.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: DesignRadius.md)
          )
          .id(block.id)
      }
    }
  }

  @ViewBuilder private var saveLine: some View {
    switch snapshot.saveState {
    case .loading:
      HStack(spacing: DesignSpacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading your notes", comment: "History meeting: the notes are being read.")
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case .saving:
      Text("Saving…", comment: "History meeting: the notes are being saved.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    case .saved:
      Text("Saved on this Mac", comment: "History meeting: the notes are saved.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    case .failed:
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
        Text(
          "Your notes couldn't be saved. They stay here until a save works.",
          comment: "History meeting: saving the notes failed; the draft is kept."
        )
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
        Button {
          Task { _ = await notes.flush(meetingID) }
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Try again", comment: "History meeting: saves the notes again."), size: .medium)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
      }
      .font(.stHelper)
    }
  }

  private func blockRow(_ block: MeetingNoteBlock) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      if let ms = block.startedAtMs, !block.text.isEmpty {
        if playbackAvailable {
          Button {
            onPlayFrom(ms)
          } label: {
            Text(verbatim: MeetingsPresentation.clock(ms: ms))
              .font(.stHelper.monospacedDigit())
              .foregroundStyle(.stAccent)
          }
          .buttonStyle(.plain)
          .help(
            Text(
              "Play the recording from this note",
              comment: "History meeting: a note's time; plays the recording from there."))
          .accessibilityLabel(
            Text(
              "Play from \(MeetingsPresentation.clock(ms: ms))",
              comment:
                "History meeting: VoiceOver label of a note's time. %@ is the time, like 1:05."))
        } else {
          Text(verbatim: MeetingsPresentation.clock(ms: ms))
            .font(.stHelper.monospacedDigit())
            .foregroundStyle(.stTextSecondary)
        }
      }
      if block.kind == .task {
        Button {
          _ = notes.apply(
            .setDone(blockID: block.id, done: !block.done), to: meetingID,
            expectedRevision: snapshot.revision, atMs: nil)
        } label: {
          Image(systemName: block.done ? "checkmark.square.fill" : "square")
            .font(.stCardText)
            .foregroundStyle(block.done ? Color.stAccent : Color.stTextSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.canEdit)
        .accessibilityLabel(
          Text(
            block.done
              ? LocalizedStringResource(
                "Action item done",
                comment: "History meeting: VoiceOver label of a ticked action item's checkbox.")
              : LocalizedStringResource(
                "Action item not done",
                comment: "History meeting: VoiceOver label of an unticked action item's checkbox.")
          ))
      }
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(verbatim: block.text)
          .font(.stCardText)
          .italic(block.kind == .quote)
          .strikethrough(block.kind == .task && block.done)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if block.kind == .quote, let speaker = block.sourceSpeaker {
          HStack(spacing: DesignSpacing.xs) {
            Text(verbatim: speaker)
            if playbackAvailable, let sourceMs = block.sourceMs, sourceMs != block.startedAtMs {
              Button {
                onPlayFrom(sourceMs)
              } label: {
                EnviousButtonLabel(
                  verbatim: MeetingsPresentation.clock(ms: sourceMs), size: .medium)
              }
              .settingsButton(.quiet, size: .medium, isEnabled: true)
              .accessibilityLabel(
                Text(
                  "Play from \(MeetingsPresentation.clock(ms: sourceMs))",
                  comment:
                    "History meeting: VoiceOver label of a quote's source time. %@ is the time, like 1:05."
                ))
            }
          }
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }
}

/// A summary drawn read-only from its lines (`HistoryMeetingAfterView.readableBlocks`): headings
/// as the structured summary draws section titles, bullets with a bullet, paragraphs as body
/// text. Inline emphasis is kept; links are removed (`readable`).
/// Also draws both sides of the summary comparison sheet (#4611).
struct MeetingReadableSummary: View {
  let blocks: [HistoryMeetingAfterView.ReadableBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let title):
          Text(verbatim: title.uppercased())
            .font(.stSectionHeader)
            .tracking(0.6)
            .foregroundStyle(.stAccent)
            .padding(.top, DesignSpacing.sm)
            .accessibilityAddTraits(.isHeader)
        case .bullet(let line):
          HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
            Text(verbatim: "•").foregroundStyle(.stTextSecondary).accessibilityHidden(true)
            lineText(line)
          }
        case .paragraph(let line):
          lineText(line)
        case .gap:
          Color.clear.frame(height: DesignSpacing.xs)
        }
      }
    }
    .textSelection(.enabled)
  }

  private func lineText(_ line: String) -> some View {
    Text(HistoryMeetingAfterView.readable(line))
      .font(.stCardText)
      .foregroundStyle(.stTextBody)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The structured summary: sections and items. View source appears only for an item whose
/// sources the validator accepted now and that still lead to a shown turn or an existing note;
/// "from your notes" only when every accepted source is a note.
private struct MeetingAfterSummarySections: View {
  let meetingID: UUID
  let document: MeetingSummaryDocument
  let references: any MeetingSummaryReferencing
  let visibleTurnIDs: Set<String>
  let noteBlockIDs: Set<UUID>
  /// The meeting time of a source, for its link's words.
  let sourceMs: (MeetingAfterPresentation.SourceTarget) -> Int?
  let onViewSource: (MeetingAfterPresentation.SourceTarget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xl) {
      ForEach(document.sections) { section in
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          Text(verbatim: section.title.uppercased())
            .font(.stSectionHeader)
            .tracking(0.6)
            .foregroundStyle(.stAccent)
          ForEach(section.items) { item in
            itemRow(item)
          }
        }
      }
    }
  }

  private func itemRow(_ item: MeetingSummaryItem) -> some View {
    let sources = references.validatedSource(for: item.id, meetingID: meetingID)?.sources ?? []
    let target = MeetingAfterPresentation.sourceTarget(
      sources, visibleTurnIDs: visibleTurnIDs, noteBlockIDs: noteBlockIDs)
    return HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
      Text(verbatim: "•").foregroundStyle(.stTextSecondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(verbatim: item.text)
          .font(.stCardText)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        // #4611 D12: one small link naming the place ("Your notes · 0:28", "Transcript · 0:00");
        // it shows and highlights the source and never starts playback.
        if let target {
          MeetingSourceLink(place: Self.place(target, ms: sourceMs(target))) {
            onViewSource(target)
          }
        } else if MeetingAfterPresentation.isFromNotes(sources) {
          Text(
            "from your notes",
            comment: "History meeting summary: the item came from the user's notes."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }
}

extension MeetingAfterSummarySections {
  /// "Your notes · 0:28", "Transcript · 0:00", or the place alone when it has no time.
  static func place(_ target: MeetingAfterPresentation.SourceTarget, ms: Int?) -> String {
    let name =
      switch target {
      case .note:
        String(
          localized: "Your notes",
          comment: "History meeting summary: a source link's place, the notes.")
      case .turn:
        String(
          localized: "Transcript",
          comment: "History meeting summary: a source link's place, the transcript.")
      }
    guard let ms else { return name }
    return "\(name) · \(MeetingsPresentation.clock(ms: ms))"
  }
}

/// #4611 D12: a summary item's source, as one small secondary link with a chevron.
private struct MeetingSourceLink: View {
  let place: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignSpacing.xxs) {
        Text(verbatim: place)
        Image(systemName: "chevron.right")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .font(.stHelper)
      .foregroundStyle(hovering ? Color.stAccent : Color.stTextSecondary)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(
      Text(
        "Show where this came from",
        comment: "History meeting summary: hover hint on a summary item's source link.")
    )
    .accessibilityLabel(
      Text(
        "Show source: \(place)",
        comment:
          "History meeting summary, VoiceOver: a source link. %@ is the place, like Your notes · 0:28."
      ))
  }
}

extension View {
  /// #3147 PR4A: a deliberate user scroll (trackpad, wheel, scroller) suspends Follow playback.
  /// Programmatic scrolls do not count, and neither does a gesture that moves nothing: on a
  /// transcript shorter than its pane the phase still turns `.interacting` (founder #4611), so
  /// only a change of the content offset during the user's gesture counts.
  @ViewBuilder
  func meetingUserScroll(_ action: @escaping () -> Void) -> some View {
    if #available(macOS 15.0, *) {
      modifier(MeetingScrollPhaseObserver(action: action))
    } else {
      modifier(MeetingWheelScrollObserver(action: action))
    }
  }
}

/// macOS 15+: the user's gesture (`.interacting`, then `.decelerating` for its momentum) counts
/// as a scroll only once the content really moves by 1 pt in all, summed over the gesture's
/// updates (a slow drag moves less than that per update). The offset is clamped to the scrollable
/// range, so a rubber-band bounce (also on content that fits its pane) moves nothing; a change of
/// the content, pane or insets size starts the sum again rather than counting as movement.
@available(macOS 15.0, *)
private struct MeetingScrollPhaseObserver: ViewModifier {
  let action: () -> Void
  @State private var userDriven = false
  @State private var distance: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onScrollPhaseChange { _, phase in
        let next = phase == .interacting || phase == .decelerating
        if !next || !userDriven { distance = 0 }
        userDriven = next
      }
      .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
        guard old.contentSize == new.contentSize, old.containerSize == new.containerSize,
          old.contentInsets == new.contentInsets, userDriven
        else {
          distance = 0
          return
        }
        distance += abs(Self.clampedOffset(new) - Self.clampedOffset(old))
        if distance >= 1 {
          distance = 0
          action()
        }
      }
  }

  nonisolated private static func clampedOffset(_ geometry: ScrollGeometry) -> CGFloat {
    let top = geometry.contentInsets.top
    let range = max(
      0,
      geometry.contentSize.height + top + geometry.contentInsets.bottom
        - geometry.containerSize.height)
    return min(max(geometry.contentOffset.y + top, 0), range)
  }
}

/// Registers and removes one process-local watcher for scroll-wheel, trackpad-scroll and
/// left-drag events (#3147 PR4A). The live conformer is `LiveHistoryScrollMonitor` in
/// `EnviousWisprDesktopEffects`, the only module allowed to call
/// `NSEvent.addLocalMonitorForEvents` (`scripts/check-dependency-direction.sh`); tests pass one
/// that never touches the desktop.
@MainActor
package protocol HistoryScrollMonitoring: AnyObject {
  /// Calls `handler` for every such event in the process and passes the event on unchanged.
  /// Returns the framework's token, or nil when AppKit refused.
  func install(_ handler: @escaping @MainActor () -> Void) -> Any?
  func remove(_ token: Any)
}

extension EnvironmentValues {
  /// The meeting page's scroll watcher on macOS 14, injected with the app's homes. Nil (a
  /// preview, a test): Follow playback is not suspended by the user's scrolling there.
  @Entry var historyScrollMonitor: (any HistoryScrollMonitoring)? = nil
}

/// macOS 14: a scroll-wheel or trackpad scroll, or a drag (the scroller, or selecting text),
/// while the pointer is over this scroll view counts as the user scrolling. Programmatic scrolls
/// send neither event.
private struct MeetingWheelScrollObserver: ViewModifier {
  let action: () -> Void
  @Environment(\.historyScrollMonitor) private var scrollMonitor
  @State private var hovering = false
  @State private var installed: (monitor: any HistoryScrollMonitoring, token: Any)?

  func body(content: Content) -> some View {
    content
      .onHover { hovering = $0 }
      .onAppear {
        guard installed == nil, let scrollMonitor else { return }
        // A wheel or trackpad scroll, or a drag on the scroller or in the text, over this view.
        if let token = scrollMonitor.install({ if hovering { action() } }) {
          installed = (scrollMonitor, token)
        }
      }
      .onDisappear {
        if let installed { installed.monitor.remove(installed.token) }
        installed = nil
      }
  }
}

/// "Return to playback" over the bottom of a transcript while the reader has scrolled away from
/// what plays (#4611 D13 meeting page, T9 transcript page).
struct HistoryReturnToPlaybackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Return to playback",
          comment: "History meeting: scrolls the transcript back to what is playing."),
        size: .medium, systemImage: "arrow.down.to.line")
    }
    .settingsButton(.filled, size: .medium, isEnabled: true)
    .fixedSize()
  }
}
