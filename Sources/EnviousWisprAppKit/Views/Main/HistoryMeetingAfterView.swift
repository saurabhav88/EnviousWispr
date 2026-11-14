import AppKit
import EnviousWisprCore
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

  init(
    meetingID: UUID,
    notes: any MeetingNotesAccessing,
    references: any MeetingSummaryReferencing,
    showPasteNotice: @escaping @MainActor (String) -> Void,
    restorePasteSurface: @escaping @MainActor () -> Void
  ) {
    self.meetingID = meetingID
    self.notes = notes
    self.references = references
    self.showPasteNotice = showPasteNotice
    self.restorePasteSurface = restorePasteSurface
  }

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication
  @Environment(HistoryRepolishRunner.self) private var historyRepolish

  // Panes
  @State private var leftPane: P.LeftPane = .notes
  @State private var transcriptPolish = HistoryPolishPreview()
  @State private var summaryPolishNotice = false
  @State private var keepingSummary = false
  @State private var editingSummary = false
  @State private var follow: P.Follow = .following
  @State private var activeTurnID: String?
  @State private var highlightedTurnID: String?
  @State private var highlightedNoteID: UUID?
  /// A request to bring a note into view. A fresh request each time, so choosing the same note
  /// again scrolls back to it.
  @State private var noteRequest: NoteRequest?
  @State private var renameRequested = false
  @State private var openedDuringRecording: UUID?
  @State private var narrowPane: MeetingSessionPane = .notes
  @State private var notesActions = MeetingNotesEditorActions()

  // Player
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: MeetingPlaybackSource?
  @State private var retainedRate: Float = 1

  // Actions
  @State private var confirming: Confirmation?
  @State private var actionInFlight = false
  @State private var orphanRefused = false
  @State private var audioSize: MeetingsPresentation.AudioSize = .measuring
  @State private var saveError: String?
  @State private var copiedAt: Date?
  @State private var notice: Notice?
  @State private var rosterRead: KeyedRosterRead<RosterKey>?
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

  private struct RosterKey: Hashable {
    let meetingID: UUID
    let audioKept: Bool
    let deletionRequested: Bool
    let state: MeetingState
  }

  private struct AudioSizeKey: Hashable {
    let meetingID: UUID
    let audioKept: Bool
    let state: MeetingState
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
          .task(
            id: AudioSizeKey(meetingID: meetingID, audioKept: record.audioKept, state: record.state)
          ) {
            audioSize = .measuring
            let size = await meetings.audioSize(meetingID: meetingID)
            guard !Task.isCancelled else { return }
            audioSize = size
          }
          .task(id: meetings.playbackSource(meetingID: meetingID)) { reconcilePlayer() }
          .task(id: rosterKey(record)) {
            // Stored with the request it answers; shown only while that is still the request.
            let key = rosterKey(record)
            let read = await meetings.callSpeakerEvidence(meetingID: meetingID)
            guard !Task.isCancelled else { return }
            rosterRead = KeyedRosterRead(key: key, evidence: read)
          }
      } else if meetings.record(id: meetingID) == nil, let row = orphanRow {
        orphan(row)
          .onAppear { dropPlayer() }
      } else {
        removedPlaceholder
          .onAppear { dropPlayer() }
      }
    }
    .background(Color.stPageBg)
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
      follow = .following
      activeTurnID = nil
      highlightedTurnID = nil
      highlightedNoteID = nil
      noteRequest = nil
      confirming = nil
      orphanRefused = false
      copiedAt = nil
      notice = nil
      rosterRead = nil
      audioSize = .measuring
    }
    .confirmationDialog(
      Text(confirmationTitle), isPresented: confirmingBinding, presenting: confirming
    ) { kind in
      Button(role: .destructive) {
        perform(kind)
      } label: {
        Text("Delete", comment: "EnviousMeet: confirms a deletion.")
      }
    } message: { kind in
      Text(verbatim: confirmationMessage(kind))
    }
    .alert(
      Text("The transcript could not be saved", comment: "EnviousMeet: Save failed."),
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(String(localized: "OK", comment: "EnviousMeet: closes the Save error.")) {}
    } message: {
      Text(verbatim: saveError ?? "")
    }
  }

  /// The row that still names this meeting when EnviousMeet no longer holds it.
  private var orphanRow: Transcript? {
    transcripts.rowIDs(ofMeeting: meetingID).compactMap(transcripts.currentRow(id:)).last
  }

  /// The committed transcript's row. A ready meeting's row stays shown while Transcribe again
  /// runs, waits or fails (#3973 C2).
  private func committedRow(_ record: MeetingRecord) -> Transcript? {
    guard record.committedTranscriptGeneration != nil else { return nil }
    return transcripts.currentRow(id: record.transcriptID)
  }

  private var removedPlaceholder: some View {
    VStack(spacing: DesignSpacing.md) {
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
            Text("Try again", comment: "History meeting: runs the failed deletion again.")
          }
          .buttonStyle(.link)
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
        .padding(.top, DesignSpacing.xs)
        .padding(.bottom, DesignSpacing.lg)
      Divider().overlay(Color.stDivider)
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
                }
              )
              .id(ObjectIdentifier(player))
            }
          }
        }
      }
      if !isRecordingThisMeeting {
        dock(record, snapshot: snapshot, row: row, visibleTurns: visibleTurns)
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
    let left = leftColumn(
      record, snapshot: snapshot, visibleTurnIDs: Set(visibleTurns.map(\.id)), proxy: proxy)
    let right = transcriptColumn(record, row: row, projection: projection)
    if isRecordingThisMeeting || openedDuringRecording == meetingID {
      MeetingSessionPanes(
        width: width, recording: isRecordingThisMeeting, selection: $narrowPane
      ) {
        left
      } transcript: {
        sessionTranscript(record, row: row, projection: projection)
      }
    } else if P.stacksPanes(width: width) {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignSpacing.xxl) {
          left
          Divider().overlay(Color.stDivider)
          right
        }
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.vertical, DesignSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .meetingUserScroll { suspendFollow() }
    } else {
      HStack(spacing: 0) {
        ScrollView {
          left
            .padding(.horizontal, DesignSpacing.xl)
            .padding(.vertical, DesignSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: max(320, width * 0.42))
        Divider().overlay(Color.stDivider)
        ScrollView {
          right
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, DesignSpacing.xl)
            .padding(.vertical, DesignSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .meetingUserScroll { suspendFollow() }
      }
    }
  }

  // MARK: - Header

  private func header(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: DesignSpacing.lg) {
          titleBlock(record)
            .frame(minWidth: Self.titleMinWidth, maxWidth: .infinity, alignment: .leading)
          actions(record, row: row, projection: projection)
        }
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          titleBlock(record)
            .frame(maxWidth: .infinity, alignment: .leading)
          actions(record, row: row, projection: projection)
        }
      }
      statusStrip(record)
      HistoryPolishPreviewContent(preview: transcriptPolish)
      summaryPolishPreview
      noticeView
    }
  }

  private static let titleMinWidth: CGFloat = 260

  private func titleBlock(_ record: MeetingRecord) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
      MeetingInlineTitle(meetingID: meetingID, beginRequest: $renameRequested)
      let status = MeetingsPresentation.status(record, processingID: meetings.processing?.meetingID)
      Text(
        verbatim: [
          record.createdAt.formatted(date: .abbreviated, time: .shortened),
          status == .ready ? nil : MeetingsPresentation.statusLabel(status),
          // #3973 C3: the engine that wrote the transcript shown (the committed one).
          record.transcriptEngineUsed?.backendType.displayName,
          record.recordedDurationMs > 0
            ? MeetingsPresentation.duration(ms: record.recordedDurationMs) : nil,
          record.state == .notesOnly ? nil : MeetingsPresentation.audioSizeLine(audioSize),
        ].compactMap { $0 }.joined(separator: " · ")
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      // #4286: who the calendar event invited.
      if let invited = MeetingsPresentation.invitedLine(meetings.documents.context(meetingID)) {
        Text(verbatim: invited)
          .font(.stHelper)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
      }
      if record.transcriptEngineFallbackReason != nil {
        Text(MeetingsCopy.usedParakeetFallback)
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
    }
  }

  /// What is still being made: the transcript pass (with its progress), the queue, the summary.
  @ViewBuilder private func statusStrip(_ record: MeetingRecord) -> some View {
    if case .recording(let id, let startedAt) = meetings.phase, id == meetingID {
      MeetingLivePanel(
        meetingID: meetingID, startedAt: startedAt, callApp: record.callApp,
        microphoneAvailable: record.trackStatus[.microphone] == .captured)
    } else if case .stopping(let id) = meetings.phase, id == meetingID {
      if let line = P.stripLine(.finishingTranscript) { busyLine(line) }
    } else if let processing = meetings.processing, processing.meetingID == meetingID {
      MeetingProcessingPanel(processing: processing)
    } else {
      let state = P.strip(
        record: record, processing: false, queueWaitsForSpace: meetings.queueWaitsForSpace,
        writingSummary: meetings.summaries?.isWriting(meetingID) ?? false,
        hasSummary: meetings.documents.summary(meetingID) != nil)
      let writingProvider = meetings.summaries?.writingProvider(for: meetingID)
      let statusLine: String? = if state == .writingSummary, let writingProvider {
        String(
          localized: "Writing the summary with \(writingProvider.displayName)…",
          comment: "History meeting: summary progress with the selected engine name.")
      } else {
        P.stripLine(state)
      }
      if let line = statusLine {
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
    return HStack(spacing: DesignSpacing.md) {
      deliveryButtons(title: MeetingsPresentation.title(record), canDeliver: canDeliver)
      moreMenu(record, canDeliver: canDeliver)
    }
    .fixedSize()
  }

  /// Copy, Share and Save as…, each reading the CURRENT row when it acts.
  @ViewBuilder
  private func deliveryButtons(title: String, canDeliver: Bool) -> some View {
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: String(localized: "Copy", comment: "EnviousMeet: copies the visible transcript."),
      copiedAt: copiedAt, now: Date(), holdSeconds: TranscribeFileExport.copiedHoldSeconds)
      Button {
        // Read at the press from the live row, never this view's snapshot.
        guard let text = deliveryText() else { return }
        TranscribeFileExport.copy(text)
        let pressed = Date()
        copiedAt = pressed
        Task {
          try? await Task.sleep(for: .seconds(TranscribeFileExport.copiedHoldSeconds))
          if copiedAt == pressed { copiedAt = nil }
        }
      } label: {
        EnviousButtonLabel(verbatim: copy.title, size: .medium, systemImage: copy.systemImage)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: canDeliver)

      // The text is read when the receiving app asks for it, so a sheet left open never hands
      // over lines that were deleted or hidden meanwhile.
      ShareLink(
        item: DeliverableText(resolve: { deliveryText() }),
        preview: SharePreview(title)
      ) {
        EnviousButtonLabel(
          LocalizedStringResource("Share", comment: "EnviousMeet: shares the visible transcript."),
          size: .medium, systemImage: "square.and.arrow.up")
      }
      .settingsButton(.quiet, size: .medium, isEnabled: canDeliver)

      Button {
        save(defaultName: title)
      } label: {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Save as…", comment: "History meeting: saves the transcript and notes as a text file."),
          size: .medium, systemImage: "square.and.arrow.down")
      }
      .settingsButton(.quiet, size: .medium, isEnabled: canDeliver)
  }

  private func moreMenu(_ record: MeetingRecord, canDeliver: Bool) -> some View {
    let offered = MeetingsPresentation.actions(
      record, isActive: isActive(record),
      canTranscribeAgain: meetings.canTranscribeAgain(meetingID) && !actionInFlight)
    let engines = meetings.transcribeAgainEngines
    let row = committedRow(record)
    let savedSummary = meetings.documents.manifest(meetingID)?.summary?.inputs
    let available = row != nil && canDeliver && !isActive(record) && !actionInFlight
    return Menu {
      Button {
        renameRequested = true
      } label: {
        Label {
          Text("Rename", comment: "EnviousMeet: saves the meeting's new name.")
        } icon: {
          Image(systemName: "pencil")
        }
      }
      .disabled(!(record.isWritableByThisBuild && !record.deletionRequested))
      Button {
        pasteTapped()
      } label: {
        Label {
          Text(verbatim: EscapeRecoveryRowPresentation.pasteLabel)
        } icon: {
          Image(systemName: "arrow.right.doc.on.clipboard")
        }
      }
      .disabled(!permissions.accessibilityGranted || !canDeliver)
      Divider()
      HistoryPolishMenu(
        title: "Polish transcript with", surface: .transcript, currentProvider: row?.llmProvider,
        currentModel: row?.llmModel, currentSize: row?.historyPolishEGOneSize,
        isEnabled: available && transcriptPolish.canStart
      ) { choice in
        guard let row else { return }
        transcriptPolish.start(rowID: row.id, choice: choice, runner: historyRepolish, history: transcripts)
      }
      HistoryPolishMenu(
        title: "Write summary again with", surface: .summary,
        currentProvider: savedSummary?.providerID, currentModel: savedSummary?.modelOverride?.model,
        currentSize: savedSummary?.modelOverride?.egOneSize,
        isEnabled: available && !keepingSummary && meetings.summaries?.isWriting(meetingID) != true
      ) { choice in
        beginSummaryPreview(choice)
      }
      Divider()
      Menu {
        if engines.isEmpty {
          Text(
            "No speech models are ready",
            comment:
              "History transcript, Transcribe again with menu: no installed speech model can be used."
          )
        }
        ForEach(engines, id: \.self) { engine in
          Button {
            transcribeAgain(engine)
          } label: {
            let title = MeetingTranscriptEngineRowTitles.title(of: engine)
            Text(
              verbatim: engine == record.transcriptEngineUsed
                ? HistoryTranscriptView.currentChoiceTitle(title) : title)
          }
        }
      } label: {
        Label {
          Text(
            "Transcribe again with",
            comment:
              "History transcript, More menu: transcribes the original file again with a chosen speech model."
          )
        } icon: {
          Image(systemName: "arrow.clockwise")
        }
      }
      .disabled(!offered.transcribeAgain || engines.isEmpty)
      Divider()
      Button(role: .destructive) {
        confirming = .deleteAudio
      } label: {
        Label {
          Text(
            "Delete recording, keep text",
            comment:
              "History meeting, More menu: deletes the meeting's audio; notes, transcript and summary stay."
          )
        } icon: {
          Image(systemName: "waveform.slash")
        }
      }
      .disabled(!offered.deleteAudio || actionInFlight)
      Button(role: .destructive) {
        confirming = .deleteMeeting
      } label: {
        Label {
          Text(
            "Delete meeting",
            comment: "EnviousMeet: removes the meeting, its audio and its transcript.")
        } icon: {
          Image(systemName: "trash")
        }
      }
      .disabled(!offered.delete || actionInFlight)
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(Text("More actions", comment: "History transcript: opens the More menu."))
  }

  private func beginSummaryPreview(_ choice: HistoryPolishChoice) {
    summaryPolishNotice = false
    meetings.summaries?.startPreview(meetingID, with: choice)
  }

  @ViewBuilder private var summaryPolishPreview: some View {
    if let summaries = meetings.summaries {
      if keepingSummary {
        HistoryPolishProgress(title: "Saving…")
      } else if let preview = summaries.previews[meetingID] {
        switch preview {
        case .generating:
          HistoryPolishProgress(title: "Writing a new summary…") {
            summaries.discardPreview(meetingID)
          }
        case .comparing(let candidate):
          HistoryPolishComparison(
            current: candidate.current ?? String(localized: "No summary yet"),
            new: candidate.text, model: candidate.choice.title,
            keep: {
              keepingSummary = true
              Task {
                summaryPolishNotice = !(await summaries.keepPreview(meetingID, candidateID: candidate.id))
                keepingSummary = false
              }
            },
            discard: { summaries.discardPreview(meetingID) })
            .id(candidate.id)
        case .failed:
          Text("Couldn't write a new summary. Choose a model to try again.").font(.stHelper)
        }
      } else if summaryPolishNotice {
        Text("The saved summary changed. Choose a model to try again.").font(.stHelper)
      }
    }
  }

  private var confirmingBinding: Binding<Bool> {
    Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
  }

  private var confirmationTitle: String {
    switch confirming {
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

  private func confirmationMessage(_ kind: Confirmation) -> String {
    switch kind {
    case .deleteAudio:
      return String(
        localized:
          "Delete this meeting's audio? The transcript stays, but you cannot transcribe it again.",
        comment: "EnviousMeet: confirmation before Delete audio.")
    case .deleteMeeting:
      return String(
        localized: "Delete this meeting, its audio and its transcript? This cannot be undone.",
        comment: "EnviousMeet: confirmation before Delete meeting.")
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
  private func deliveryText() -> String? {
    deliveryRow().flatMap(transcripts.textForDelivery)
  }

  /// The row whose words are delivered now: the committed row of a meeting EnviousMeet holds
  /// (nothing while it is being deleted), else the row of a meeting whose folder is gone.
  private func deliveryRow() -> Transcript? {
    if let record = meetings.record(id: meetingID) {
      return record.deletionRequested ? nil : committedRow(record)
    }
    return orphanRow
  }

  private func perform(_ kind: Confirmation) {
    confirming = nil
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
      text: { deliveryText() },
      showHistory: { restorePasteSurface() },
      showNotice: { showPasteNotice($0) })
  }

  /// The document is read AFTER the panel closes, so a meeting deleted meanwhile saves nothing.
  private func save(defaultName: String) {
    guard let row = deliveryRow() else { return }
    let rowID = row.id
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = defaultName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      switch await MeetingExport.document(
        meetingID: meetingID, rowID: rowID, documents: meetings.documents,
        transcripts: transcripts)
      {
      case .document(let document):
        do {
          try document.write(to: url, atomically: true, encoding: .utf8)
        } catch {
          saveError = error.localizedDescription
        }
      case .notesUnreadable:
        saveError = String(
          localized: "Your notes could not be read, so nothing was saved. Try again.",
          comment:
            "History, a meeting: Save stopped because the meeting's notes file could not be read.")
      case .nothingToDeliver:
        break
      }
    }
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

  private func rosterKey(_ record: MeetingRecord) -> RosterKey {
    RosterKey(
      meetingID: meetingID, audioKept: record.audioKept,
      deletionRequested: record.deletionRequested, state: record.state)
  }

  // MARK: - Dock

  private func dock(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, row: Transcript?, visibleTurns: [Turn]
  ) -> some View {
    let participants = P.participants(
      turns: visibleTurns, speakerNames: row?.speakerNames ?? [:])
    let content: MeetingAfterPlayerBar.Content =
      player.map { .player($0) } ?? .unavailable(P.dockAbsence(record))
    return MeetingAfterPlayerBar(
      content: content,
      markers: P.noteMarkers(snapshot.document, durationMs: player?.durationMs ?? 0),
      participants: participants,
      onSelectNote: { marker in showNote(marker.id) })
  }

  // MARK: - Follow playback

  private func showNote(_ id: UUID) {
    leftPane = .notes
    narrowPane = .notes
    highlightedNoteID = id
    noteRequest = NoteRequest(id: id)
  }

  private func suspendFollow() {
    if follow == .following { follow = .suspended }
  }
}

// MARK: - Left pane

extension HistoryMeetingAfterView {
  @ViewBuilder
  fileprivate func leftColumn(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, visibleTurnIDs: Set<String>,
    proxy: ScrollViewProxy
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      if !isRecordingThisMeeting {
      BrandedSegmentedPicker(
        options: [
          (
            String(localized: "Your notes", comment: "History meeting: the user's own notes pane."),
            nil, P.LeftPane.notes
          ),
          (
            String(localized: "AI summary", comment: "History meeting: the meeting summary pane."),
            nil, P.LeftPane.summary
          ),
        ],
        selection: $leftPane
      )
      .fixedSize()
      .accessibilityLabel(
        Text(
          "Notes or summary",
          comment: "History meeting: chooses between the user's notes and the AI summary."))
      }
      switch leftPane {
      case .notes:
        MeetingAfterNotesPane(
          meetingID: meetingID, notes: notes, snapshot: snapshot,
          highlightedNoteID: highlightedNoteID,
          requestNonce: noteRequest?.nonce,
          onSeek: { ms in player?.seek(toMs: ms) },
          playbackMs: { notesClockMs() },
          startsEditing: isRecordingThisMeeting || openedDuringRecording == meetingID,
          recording: isRecordingThisMeeting,
          markMoment: markMoment,
          toggleActionItem: toggleLiveActionItem,
          editorActions: notesActions)
      case .summary:
        summaryPane(
          record, snapshot: snapshot, visibleTurnIDs: visibleTurnIDs, proxy: proxy)
      }
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
    let speaker = MeetingsPresentation.liveSpeakerHeader(run.speaker, names: live.speakerLabels.names)
    let text = run.text.split(whereSeparator: \.isNewline).joined(separator: " ")
    notesActions.append(
      MeetingNoteBlock(kind: .quote, text: text, sourceSpeaker: speaker, sourceMs: run.startMs),
      for: meetingID, atMs: time)
  }

  /// #3147 PR4A: where a new note block starts on the meeting timeline (plan §3.6). While this
  /// meeting records, its recorded position (the recorder's clock); after Stop, the playback
  /// position; else unknown.
  @MainActor fileprivate func notesClockMs() -> Int? {
    if case .recording(let id, _) = meetings.phase, id == meetingID {
      return meetings.recordingPositionMs(meetingID: meetingID)
    }
    return player?.positionMs
  }

  @ViewBuilder
  fileprivate func summaryPane(
    _ record: MeetingRecord, snapshot: MeetingNotesSnapshot, visibleTurnIDs: Set<String>,
    proxy: ScrollViewProxy
  ) -> some View {
    if !editingSummary, let document = references.document(for: meetingID) {
      VStack(alignment: .leading, spacing: DesignSpacing.lg) {
        HStack {
          Spacer(minLength: 0)
          Button {
            editingSummary = true
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Edit summary", comment: "History meeting: makes the summary editable."),
              size: .medium, systemImage: "pencil")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
        MeetingAfterSummarySections(
          meetingID: meetingID, document: document, references: references,
          visibleTurnIDs: visibleTurnIDs,
          noteBlockIDs: Set(snapshot.document.blocks.map(\.id)),
          onViewSource: { target in viewSource(target, proxy: proxy) })
      }
    } else if !editingSummary, let text = meetings.documents.summary(meetingID) {
      readableSummary(text)
    } else {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        if editingSummary {
          HStack {
            Spacer(minLength: 0)
            Button {
              editingSummary = false
            } label: {
              EnviousButtonLabel(
                LocalizedStringResource(
                  "Done editing", comment: "History meeting: ends editing the summary or the notes."),
                size: .medium, systemImage: "checkmark")
            }
            .settingsButton(.quiet, size: .medium, isEnabled: true)
          }
        }
        // Editing, Write again, writing, problems, save failure and edited-summary protection;
        // also every state before a summary exists.
        MeetingSummaryView(meetingID: meetingID, writePreview: beginSummaryPreview)
      }
    }
  }

  /// A summary with no validated structure (an edited, older or unqualified summary), read
  /// only, with no links. Edit summary opens the full summary controls.
  fileprivate func readableSummary(_ text: String) -> some View {
    let documents = meetings.documents
    return VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack {
        Spacer(minLength: 0)
        Button {
          editingSummary = true
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Edit summary", comment: "History meeting: makes the summary editable."),
            size: .medium, systemImage: "pencil")
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
      }
      if meetings.summaries?.isOutOfDate(meetingID) == true {
        Text(
          "The meeting changed after this summary was written. It may be out of date.",
          comment:
            "History, a meeting: the summary was written from an older transcript, names or notes."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
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
            Text("Try again", comment: "History, a meeting: saves the summary changes again.")
          }
          .buttonStyle(.link)
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
  fileprivate func viewSource(_ target: MeetingAfterPresentation.SourceTarget, proxy: ScrollViewProxy) {
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
  @ViewBuilder
  fileprivate func sessionTranscript(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    if isRecordingThisMeeting, let live = meetings.liveTranscript, live.meetingID == meetingID {
      MeetingLiveWordsView(transcript: live, addQuote: addQuote)
    } else {
      ScrollView {
        transcriptColumn(record, row: row, projection: projection)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .meetingUserScroll { suspendFollow() }
    }
  }

  @ViewBuilder
  fileprivate func transcriptColumn(
    _ record: MeetingRecord, row: Transcript?, projection: MeetingHistoryPresentation.Projection?
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      transcriptState(record, row: row)
      if let row, let projection {
        transcriptToolbar(row)
        if rosterRead?.permissionMissing(for: rosterKey(record)) == true {
          speakerNamesPermissionNote
        }
        switch projection {
        case .visible(let turns, _):
          MeetingAfterTurnList(
            rowID: row.id, turns: turns, rawText: row.text,
            speakerNames: row.speakerNames ?? [:], player: player,
            renameSuggestions: SpeakerRenameSuggestions(
              row: row, roster: rosterRead?.roster(for: rosterKey(record))),
            highlightedTurnID: highlightedTurnID,
            activeTurnID: follow == .off ? nil : activeTurnID
          )
          .equatable()
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
  fileprivate func transcriptState(_ record: MeetingRecord, row: Transcript?) -> some View {
    switch meetings.phase {
    case .recording(let id, _) where id == meetingID:
      busyLine(String(localized: "Live transcript"))
    case .stopping(let id) where id == meetingID:
      supersededLiveWords()
    default:
      let committed = record.committedTranscriptGeneration != nil
      if committed, row != nil {
        EmptyView()
      } else if committed, !transcripts.historyReadFinished {
        busyLine(
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
          if meetings.canTranscribeAgain(meetingID) && !actionInFlight {
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
  fileprivate func supersededLiveWords() -> some View {
    if let live = meetings.liveTranscript, live.meetingID == meetingID {
      MeetingLiveWordsView(transcript: live, superseded: true)
    }
  }

  fileprivate func busyLine(_ text: String) -> some View {
    HStack(spacing: DesignSpacing.sm) {
      ProgressView().controlSize(.small)
      Text(verbatim: text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  fileprivate func transcriptToolbar(_ row: Transcript) -> some View {
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
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
      }
      if player != nil {
        Toggle(
          isOn: Binding(
            get: { follow != .off },
            set: { follow = $0 ? .following : .off })
        ) {
          Text(
            "Follow playback",
            comment: "History meeting: the transcript scrolls along with the playing recording."
          )
          .font(.stRowLabel)
        }
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        if follow == .suspended {
          Button {
            follow = .following
            highlightedTurnID = nil
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Return to playback",
                comment: "History meeting: scrolls the transcript back to what is playing."),
              size: .medium, systemImage: "arrow.down.to.line")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
    }
  }

  /// #4013: this meeting recorded without Accessibility, so it has no speaker names to offer.
  fileprivate var speakerNamesPermissionNote: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      Text(MeetingHistoryPresentation.speakerNamesPermissionMessage)
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(MeetingHistoryPresentation.speakerNamesPermissionButton) {
        navigation.request(.meetings(.permissions))
        appWindowCoordinator.showWindow()
      }
    }
  }
}

// MARK: - Orphan

extension HistoryMeetingAfterView {
  /// A meeting row whose meeting EnviousMeet does not hold: its transcript, and Delete, which
  /// EnviousMeet carries out only when the meeting's folder is confirmed absent.
  fileprivate func orphan(_ row: Transcript) -> some View {
    let projection = transcripts.meetingProjection(of: row)
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        HStack(alignment: .center, spacing: DesignSpacing.lg) {
          Text(verbatim: P.fallbackTitle)
            .font(.stRowTitle)
            .foregroundStyle(.stTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
          let canDeliver: Bool = {
            if case .visible = projection { return true }
            return false
          }()
          deliveryButtons(title: P.fallbackTitle, canDeliver: canDeliver)
          Button {
            pasteTapped()
          } label: {
            EnviousButtonLabel(
              verbatim: EscapeRecoveryRowPresentation.pasteLabel, size: .medium,
              systemImage: "arrow.right.doc.on.clipboard")
          }
          .settingsButton(
            .quiet, size: .medium, isEnabled: permissions.accessibilityGranted && canDeliver)
          Button(role: .destructive) {
            actionInFlight = true
            let shown = presentation
            Task {
              let deleted = await meetings.deleteOrphan(meetingID: meetingID)
              guard shown == presentation else { return }
              orphanRefused = !deleted
              actionInFlight = false
            }
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Delete meeting",
                comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
              size: .medium)
          }
          .settingsButton(size: .medium, isEnabled: !actionInFlight)
        }
        if orphanRefused {
          Text(
            "This meeting's files are still on this Mac but can't be read, so it can't be deleted here.",
            comment:
              "History: Delete was refused for a meeting whose folder exists but cannot be read."
          )
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.top, DesignSpacing.xs)
      .padding(.bottom, DesignSpacing.lg)
      Divider().overlay(Color.stDivider)
      ScrollView {
        Group {
          switch projection {
          case .visible(let turns, _):
            MeetingAfterTurnList(
              rowID: row.id, turns: turns, rawText: row.text,
              speakerNames: row.speakerNames ?? [:], player: nil,
              renameSuggestions: SpeakerRenameSuggestions(row: row, roster: nil),
              highlightedTurnID: nil, activeTurnID: nil
            )
            .equatable()
          case .everythingHidden:
            Text(MeetingHistoryPresentation.everythingHiddenMessage)
          case .unavailable:
            Text(MeetingHistoryPresentation.unavailableMessage)
          }
        }
        .font(.stBody)
        .foregroundStyle(.stTextBody)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.vertical, DesignSpacing.xl)
      }
      MeetingAfterPlayerBar(
        content: .unavailable(.unavailable), markers: [], participants: [], onSelectNote: { _ in })
    }
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
  @Environment(TranscriptCoordinator.self) private var transcripts

  nonisolated static func == (a: MeetingAfterTurnList, b: MeetingAfterTurnList) -> Bool {
    a.rowID == b.rowID && a.player === b.player && a.renameSuggestions == b.renameSuggestions
      && a.highlightedTurnID == b.highlightedTurnID && a.activeTurnID == b.activeTurnID
      && MeetingDocumentHash.sameBytes(a.rawText, b.rawText)
      && MeetingDocumentHash.sameBytes(a.speakerNames, b.speakerNames)
      && TranscriptTurnsDocument.Inputs.sameTurns(a.turns, b.turns)
  }

  var body: some View {
    let rendered = MeetingGapPresentation.localized(
      TranscriptDocumentPresenter.render(
        turns: turns, rawText: rawText, speakerNames: speakerNames,
        mode: .cleaned, timesOn: true, documentFinished: true, diffLookup: { _ in nil })) ?? []
    LazyVStack(alignment: .leading, spacing: DesignSpacing.md) {
      ForEach(TurnRowKey.keyed(rendered), id: \.key) { key, turn in
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
          fallback: { EmptyView() }
        )
        .padding(DesignSpacing.sm)
        .background(
          background(for: turn.turnID), in: RoundedRectangle(cornerRadius: DesignRadius.md)
        )
        .id(key)
      }
    }
  }

  private func background(for turnID: String) -> Color {
    if turnID == highlightedTurnID { return Color.stAccent.opacity(0.18) }
    if turnID == activeTurnID { return Color.stAccent.opacity(0.08) }
    return .clear
  }
}

/// Reads the player's position (so a tick re-renders only this invisible view), reports the
/// turn playback is in, and scrolls to it while Follow playback is on.
private struct MeetingFollowDriver: View {
  let player: MeetingPlaybackController
  let turns: [Turn]
  @Binding var activeTurnID: String?
  let following: Bool
  let scroll: (String) -> Void

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
  let onSeek: (Int) -> Void
  /// #3147 PR4A: the playback position, so a block typed after Stop starts there (plan §3.6).
  let playbackMs: @MainActor () -> Int?
  let startsEditing: Bool
  let recording: Bool
  let markMoment: () -> Void
  let toggleActionItem: () -> Void
  let editorActions: MeetingNotesEditorActions
  /// Read mode keeps note times as seek buttons and the marker highlight; Edit notes swaps in
  /// the block editor, as Edit summary does for the summary.
  @State private var editing: Bool?

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
      } else {
        HStack {
          Spacer(minLength: 0)
          Button {
            editing = false
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Done editing", comment: "History meeting: ends editing the summary or the notes."),
              size: .medium, systemImage: "checkmark")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
      MeetingNotesBlockEditor(
        meetingID: meetingID, notes: notes, currentMs: playbackMs, actions: editorActions)
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
      HStack(alignment: .firstTextBaseline) {
        saveLine
        Spacer(minLength: 0)
        if snapshot.canEdit {
          Button {
            editing = true
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Edit notes", comment: "History meeting: makes the notes editable."),
              size: .medium, systemImage: "pencil")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
      let blocks = snapshot.document.blocks.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if blocks.isEmpty, snapshot.saveState != .loading {
        Text(
          "No notes for this meeting.",
          comment: "History meeting: the notes pane of a meeting without notes."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
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
          Text("Try again", comment: "History meeting: saves the notes again.")
        }
        .buttonStyle(.link)
      }
      .font(.stHelper)
    }
  }

  private func blockRow(_ block: MeetingNoteBlock) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      if let ms = block.startedAtMs {
        Button {
          onSeek(ms)
        } label: {
          Text(verbatim: MeetingsPresentation.clock(ms: ms))
            .font(.stHelper.monospacedDigit())
            .foregroundStyle(.stAccent)
        }
        .buttonStyle(.plain)
        .help(
          Text(
            "Move the recording to this note",
            comment: "History meeting: a note's time; moves playback there without playing."))
      }
      if block.kind == .task {
        Button {
          _ = notes.apply(
            .setDone(blockID: block.id, done: !block.done), to: meetingID,
            expectedRevision: snapshot.revision, atMs: nil)
        } label: {
          Image(systemName: block.done ? "checkmark.square.fill" : "square")
            .font(.stBody)
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
          .font(.stBody)
          .italic(block.kind == .quote)
          .strikethrough(block.kind == .task && block.done)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if block.kind == .quote, let speaker = block.sourceSpeaker {
          HStack(spacing: DesignSpacing.xs) {
            Text(verbatim: speaker)
            if let sourceMs = block.sourceMs, sourceMs != block.startedAtMs {
              Button {
                onSeek(sourceMs)
              } label: {
                Text(verbatim: MeetingsPresentation.clock(ms: sourceMs))
              }
              .buttonStyle(.link)
              .accessibilityLabel(Text("Move the recording to this note"))
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
private struct MeetingReadableSummary: View {
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
      .font(.stBody)
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
          .font(.stBody)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: DesignSpacing.md) {
          if MeetingAfterPresentation.isFromNotes(sources) {
            Text(
              "from your notes",
              comment: "History meeting summary: the item came from the user's notes."
            )
            .historyChip(tint: .stTextSecondary, fill: Color.stTextSecondary.opacity(0.14))
          }
          if let target {
            Button {
              onViewSource(target)
            } label: {
              Text(
                "View source", comment: "History meeting summary: shows where this item came from.")
            }
            .buttonStyle(.link)
            .font(.stHelper)
          }
        }
      }
    }
  }
}

extension View {
  /// #3147 PR4A: a deliberate user scroll (trackpad, wheel, scroller) suspends Follow playback.
  /// Programmatic scrolls do not count. Before macOS 15 the scroll phase is not observable, so
  /// Follow playback is turned off with its toggle instead.
  @ViewBuilder
  func meetingUserScroll(_ action: @escaping () -> Void) -> some View {
    if #available(macOS 15.0, *) {
      onScrollPhaseChange { _, phase in
        if phase == .interacting { action() }
      }
    } else {
      modifier(MeetingWheelScrollObserver(action: action))
    }
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
