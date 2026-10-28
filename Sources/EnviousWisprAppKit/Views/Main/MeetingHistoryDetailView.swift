import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// One meeting in History (#3972 R36, R45, founder F17): its name, status, kept audio and
/// actions, then three tabs. Transcript shows what the meeting is doing now (recording, the
/// after-recording work, a failure) and, once ready, the transcript through History's own paths
/// (`TranscriptCoordinator.meetingProjection`, `textForDelivery`, `renameSpeaker`). Notes is the
/// user's own text (`MeetingDocumentsOwner`). Summary is written after the meeting. Every action
/// re-reads the meeting by `meetingID` when it runs; a confirmation belongs to this meeting only
/// (History rebuilds this view per meeting).
struct MeetingHistoryDetailView: View {
  let meeting: HistoryMeetingItem
  /// #4101: why a History Paste did not happen; the History page holds the notice, so this view
  /// being rebuilt for another meeting does not lose it.
  let showPasteNotice: @MainActor (String) -> Void
  private var meetingID: UUID { meeting.meetingID }

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication

  @State private var confirming: Confirmation?
  @State private var actionInFlight = false
  /// The orphan row's Delete was refused: its folder is still on this Mac.
  @State private var orphanRefused = false
  @State private var audioSize: MeetingsPresentation.AudioSize = .measuring
  @State private var saveError: String?
  /// This meeting's player, made when its audio is available; stopped and dropped when the
  /// meeting closes, loses its audio or is deleted.
  @State private var player: MeetingPlaybackController?
  /// The source `player` was made from; a different source replaces it.
  @State private var playerSource: MeetingPlaybackSource?

  enum Confirmation: Equatable {
    case deleteAudio
    case deleteMeeting
  }

  enum Tab: Hashable {
    case transcript
    case notes
    case summary
  }

  @State private var tab: Tab = .transcript
  /// #4013 r3 F3: this meeting's saved participant list, for the rename suggestions; read once
  /// per meeting and audio state (`RosterKey`).
  @State private var roster: CallSpeakerRoster?

  var body: some View {
    if let record = meetings.record(id: meetingID) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(MeetingsPresentation.title(record))
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.stTextPrimary)
          // #4001 step 2b-A: the name draft and the playback position are read by these two
          // views only, so typing a name or a playback tick does not rebuild the transcript.
          MeetingDetailHeader(meetingID: meetingID, record: record, audioSize: audioSize)
          actions(record)
          if let confirming { confirmation(confirming, record: record) }
          if let player {
            MeetingPlaybackControls(player: player).id(ObjectIdentifier(player))
          }
          tabPicker
          switch tab {
          case .transcript: transcriptTab(record)
          case .notes: MeetingNotesEditor(meetingID: meetingID)
          case .summary: MeetingSummaryView(meetingID: meetingID)
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color.stPageBg)
      .task(id: AudioSizeKey(audioKept: record.audioKept, state: record.state)) {
        audioSize = .measuring
        audioSize = await meetings.audioSize(meetingID: meetingID)
      }
      .task(id: meetings.playbackSource(meetingID: meetingID)) {
        reconcilePlayer()
      }
      .task(
        id: RosterKey(
          meetingID: meetingID, audioKept: record.audioKept,
          deletionRequested: record.deletionRequested, state: record.state)
      ) {
        // Cleared first, so Delete audio or a deletion never leaves the old list offered; a
        // read cancelled by a newer key never lands.
        roster = nil
        let read = await meetings.callSpeakerRoster(meetingID: meetingID)
        guard !Task.isCancelled else { return }
        roster = read
      }
      .onAppear {
        // A meeting that recorded nothing has only notes to show.
        if record.state == .notesOnly { tab = .notes }
      }
      .onDisappear { dropPlayer() }
      .alert(
        Text("The transcript could not be saved", comment: "EnviousMeet: Save failed."),
        isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button(String(localized: "OK", comment: "EnviousMeet: closes the Save error.")) {}
      } message: {
        Text(saveError ?? "")
      }
    } else if let row = meeting.row {
      // A meeting row whose meeting EnviousMeet does not hold: its transcript only.
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(
            "Meeting", comment: "History: the title of a meeting whose details are not available."
          )
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.stTextPrimary)
          orphanDelete
          transcript(row: row, record: nil)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color.stPageBg)
    }
  }

  /// A row whose meeting record is gone can still be deleted on its own: EnviousMeet removes it
  /// only when the meeting's folder is confirmed absent, and says so when it is not.
  private var orphanDelete: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Spacer(minLength: 0)
        SettingsActionButton(
          title: LocalizedStringResource(
            "Delete meeting",
            comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
          isEnabled: !actionInFlight, emphasis: .destructive
        ) {
          actionInFlight = true
          Task {
            orphanRefused = !(await meetings.deleteOrphan(meetingID: meetingID))
            actionInFlight = false
          }
        }
        .accessibilityIdentifier("meetings.detail.deleteOrphan")
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
  }

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
      dropPlayer()
      if let source {
        player = MeetingPlaybackController(source: source, output: MeetingPlaybackEngineOutput())
        playerSource = source
      }
    }
  }

  private func dropPlayer() {
    player?.stop()
    player = nil
    playerSource = nil
  }

  /// What the audio size depends on, so it is measured again only when that changes.
  private struct AudioSizeKey: Hashable {
    let audioKept: Bool
    let state: MeetingState
  }

  private struct RosterKey: Hashable {
    let meetingID: UUID
    let audioKept: Bool
    let deletionRequested: Bool
    let state: MeetingState
  }

  // MARK: - Actions

  private func actions(_ record: MeetingRecord) -> some View {
    let offered = MeetingsPresentation.actions(
      record, isActive: isActive(record),
      canTranscribeAgain: canOfferTranscribeAgain(record.id))
    return HStack(spacing: 10) {
      SettingsActionButton(
        title: LocalizedStringResource(
          "Transcribe again",
          comment: "EnviousMeet: makes the meeting's transcript again from its kept audio."),
        isEnabled: offered.transcribeAgain, systemImage: "arrow.clockwise"
      ) {
        // #3973 C2: Parakeet is the only meeting engine until C3 adds the engine menu.
        run { meetings in await meetings.transcribeAgain(meetingID: meetingID, engine: .parakeet) }
      }
      .accessibilityIdentifier("meetings.detail.retry")
      SettingsActionButton(
        title: LocalizedStringResource(
          "Delete audio",
          comment: "EnviousMeet: removes the meeting's recording and keeps its transcript."),
        isEnabled: offered.deleteAudio && !actionInFlight, emphasis: .quiet
      ) {
        confirming = .deleteAudio
      }
      .accessibilityIdentifier("meetings.detail.deleteAudio")
      Spacer(minLength: 0)
      SettingsActionButton(
        title: LocalizedStringResource(
          "Delete meeting",
          comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
        isEnabled: offered.delete && !actionInFlight, emphasis: .destructive
      ) {
        confirming = .deleteMeeting
      }
      .accessibilityIdentifier("meetings.detail.delete")
    }
  }

  private func confirmation(_ kind: Confirmation, record: MeetingRecord) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        kind == .deleteAudio
          ? String(
            localized:
              "Delete this meeting's audio? The transcript stays, but you cannot transcribe it again.",
            comment: "EnviousMeet: confirmation before Delete audio.")
          : String(
            localized: "Delete this meeting, its audio and its transcript? This cannot be undone.",
            comment: "EnviousMeet: confirmation before Delete meeting.")
      )
      .font(.stBody)
      .foregroundStyle(.stTextPrimary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        SettingsActionButton(
          title: LocalizedStringResource(
            "Delete", comment: "EnviousMeet: confirms a deletion."),
          isEnabled: !actionInFlight, emphasis: .destructive
        ) {
          confirming = nil
          switch kind {
          case .deleteAudio:
            dropPlayer()
            run { meetings in await meetings.deleteAudio(meetingID: meetingID) }
          case .deleteMeeting:
            dropPlayer()
            // History's one deletion path: the selection moves to the item beside this one,
            // then EnviousMeet deletes the meeting (Codex C8 r1).
            let item = HistoryListItem.meeting(
              HistoryMeetingItem(
                meetingID: meetingID, record: meetings.record(id: meetingID),
                row: meeting.row))
            Task { await transcripts.delete(item) }
          }
        }
        .accessibilityIdentifier("meetings.detail.confirmDelete")
        SettingsActionButton(
          title: LocalizedStringResource(
            "Cancel", comment: "EnviousMeet: keeps the meeting as it is."),
          isEnabled: true, emphasis: .quiet, shortcut: .cancelAction
        ) {
          confirming = nil
        }
      }
    }
    .padding(12)
    .background(Color.stError.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  /// Runs one meeting action for THIS meeting, never another: the action closes over
  /// `meetingID`, which this view never changes. The coordinator re-checks the meeting's state.
  private func run(_ action: @escaping @MainActor (MeetingCoordinator) async -> Void) {
    guard !actionInFlight, meetings.record(id: meetingID) != nil else { return }
    actionInFlight = true
    let coordinator = meetings
    Task {
      await action(coordinator)
      actionInFlight = false
    }
  }

  // MARK: - Playback

  private func isActive(_ record: MeetingRecord) -> Bool {
    if meetings.processing?.meetingID == record.id { return true }
    switch meetings.phase {
    case .recording(let id, _), .stopping(let id): return id == record.id
    case .starting, .idle: return false
    }
  }

  // MARK: - Tabs

  private var tabPicker: some View {
    Picker(
      String(localized: "Show", comment: "History, a meeting: which part of it is shown."),
      selection: $tab
    ) {
      Text("Transcript", comment: "History, a meeting: the tab with the meeting's transcript.")
        .tag(Tab.transcript)
      Text("Notes", comment: "History, a meeting: the tab with the user's own notes.")
        .tag(Tab.notes)
      Text("Summary", comment: "History, a meeting: the tab with the meeting's summary.")
        .tag(Tab.summary)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  /// What the meeting is doing now, then its transcript once one exists (R36). The state comes
  /// from the meeting record, never from whether a History row exists: a retry keeps the old
  /// row, and a new row lands before the meeting is ready.
  @ViewBuilder private func transcriptTab(_ record: MeetingRecord) -> some View {
    switch meetings.phase {
    case .recording(let id, let startedAt) where id == meetingID:
      MeetingLivePanel(startedAt: startedAt)
      if let live = meetings.liveTranscript, live.meetingID == meetingID {
        MeetingLiveWordsView(
          transcript: live, callSoundRecorded: record.trackStatus[.callSound] == .captured)
      }
      Text(
        "The transcript, with who said what, is written when you stop the recording.",
        comment: "History, a recording meeting: what the Transcript tab will show."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case .stopping(let id) where id == meetingID:
      busyLine(
        String(
          localized: "Saving the recording",
          comment: "EnviousMeet: the meeting recording is being closed and saved."))
      supersededLiveWords(record)
    default:
      if let processing = meetings.processing, processing.meetingID == meetingID {
        MeetingProcessingPanel(processing: processing)
      } else if record.state == .queued, meetings.queueWaitsForSpace {
        busyLine(
          String(
            localized: "Waiting for free disk space. Free up space, then choose Transcribe again.",
            comment: "History, a meeting: the transcript waits because the Mac is almost full."))
      } else if record.state == .queued {
        busyLine(
          String(
            localized: "Waiting to be transcribed",
            comment: "History, a meeting: it waits for another meeting's transcript first."))
      }
      // #3973 C2: a committed transcript stays shown while Transcribe again runs, waits or
      // fails; it is replaced only once the new one is committed and published.
      let committed = record.committedTranscriptGeneration != nil
      if committed, let row = transcripts.currentRow(id: record.transcriptID) {
        transcript(row: row, record: record)
      } else if committed, !transcripts.historyReadFinished {
        busyLine(
          String(
            localized: "Loading the transcript",
            comment: "History, a ready meeting: waiting for History's first read attempt to finish."
          ))
      } else if committed {
        // #4001 H12: committed, History has been read, and the row is still not there (its file
        // is missing or could not be read). Say so instead of showing nothing.
        missingTranscript(canTranscribeAgain: canOfferTranscribeAgain(record.id))
      } else if record.state != .notesOnly {
        // #3973: processing, queued or failed: the live words stay until a transcript is ready.
        supersededLiveWords(record)
      }
      if record.state == .notesOnly {
        Text(
          "Nothing was recorded for this meeting. Your notes are in Notes.",
          comment: "History, a meeting that recorded nothing: where its notes are."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      }
    }
  }

  /// This meeting's live words after Stop, greyed, until its transcript replaces them (the
  /// owner clears them then, and at once on Delete).
  @ViewBuilder private func supersededLiveWords(_ record: MeetingRecord) -> some View {
    if let live = meetings.liveTranscript, live.meetingID == meetingID {
      MeetingLiveWordsView(
        transcript: live, callSoundRecorded: record.trackStatus[.callSound] == .captured,
        superseded: true)
    }
  }

  /// Whether Transcribe again can be pressed now. The button and the missing-transcript hint
  /// share it, so the hint never names a disabled button.
  private func canOfferTranscribeAgain(_ meetingID: UUID) -> Bool {
    meetings.canTranscribeAgain(meetingID) && !actionInFlight
  }

  private func missingTranscript(canTranscribeAgain: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(
        "This meeting's transcript could not be opened.",
        comment: "History, a ready meeting whose saved transcript is missing or unreadable."
      )
      .font(.stBody)
      .foregroundStyle(.stTextPrimary)
      if canTranscribeAgain {
        Text(
          "Choose Transcribe again to make it from the recording.",
          comment: "History, a ready meeting whose transcript could not be opened: the way back."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func busyLine(_ text: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Transcript

  @ViewBuilder private func transcript(row: Transcript, record: MeetingRecord?) -> some View {
    Group {
      let projection = transcripts.meetingProjection(of: row)
      // Copy and Save deliver only visible turns; the text itself is built on press.
      let canDeliver: Bool = {
        if case .visible = projection { return true }
        return false
      }()
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          // #3973 C2: the shown row's own generation decides, so a retained transcript keeps
          // its control while Transcribe again runs.
          if record != nil, transcripts.meetingHasProbableEcho(row) {
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
            }
            .controlSize(.small)
            .toggleStyle(.switch)
            .accessibilityIdentifier("meetings.detail.showEcho")
          }
          Spacer(minLength: 0)
          Button {
            guard let text = transcripts.textForDelivery(row) else { return }
            PasteService.copyToClipboard(text, kind: .kept)
          } label: {
            Label(
              String(localized: "Copy", comment: "EnviousMeet: copies the visible transcript."),
              systemImage: "doc.on.doc")
          }
          .disabled(!canDeliver)
          Button {
            save(row, record: record)
          } label: {
            Label(
              String(
                localized: "Save", comment: "EnviousMeet: saves the visible transcript as text."),
              systemImage: "square.and.arrow.down")
          }
          .disabled(!canDeliver)
          // The text is read when the system asks for it, so a sheet left open never hands over
          // lines that were deleted or hidden meanwhile.
          ShareLink(
            item: DeliverableText(resolve: { transcripts.textForDelivery(row) }),
            preview: SharePreview(
              record.map(MeetingsPresentation.title)
                ?? String(localized: "Meeting", comment: "History: a meeting's default file name."))
          ) {
            Label(
              String(localized: "Share", comment: "EnviousMeet: shares the visible transcript."),
              systemImage: "square.and.arrow.up")
          }
          .disabled(!canDeliver)
          Button {
            if permissions.accessibilityGranted {
              // #4101: into the app the user came from, read at the press.
              historyPaste.paste(
                destination: previousApplication.lastOtherApplication,
                allowed: { true },
                text: { transcripts.textForDelivery(row) },
                showHistory: { showHistory() },
                showNotice: { showPasteNotice($0) })
            } else {
              navigationCoordinator.request(.appSettings(.permissions))
            }
          } label: {
            Label(
              EscapeRecoveryRowPresentation.pasteLabel,
              systemImage: "arrow.right.doc.on.clipboard")
          }
          .disabled(!permissions.accessibilityGranted || !canDeliver)
        }
        switch projection {
        case .visible(let turns, _):
          MeetingTurnsDocument(
            rowID: row.id, turns: turns, rawText: row.text,
            speakerNames: row.speakerNames ?? [:], player: player,
            renameSuggestions: SpeakerRenameSuggestions(row: row, roster: record == nil ? nil : roster)
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

  private func showHistory() {
    navigationCoordinator.request(.history)
    appWindowCoordinator.showWindow()
  }

  /// The text is read AFTER the panel closes, so a meeting deleted meanwhile saves nothing.
  private func save(_ row: Transcript, record: MeetingRecord?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue =
      record.map(MeetingsPresentation.title)
      ?? String(localized: "Meeting", comment: "History: a meeting's default file name.")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      switch await MeetingExport.document(
        meetingID: meetingID, rowID: row.id, documents: meetings.documents,
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
}

/// A ready meeting's visible turns (#4075 G6). Compared on its document data and player
/// identity so parent updates with unchanged inputs can skip turn preparation.
struct MeetingTurnsDocument: View, Equatable {
  let rowID: UUID
  let turns: [Turn]
  let rawText: String
  let speakerNames: [String: String]
  let player: MeetingPlaybackController?
  let renameSuggestions: SpeakerRenameSuggestions
  @Environment(TranscriptCoordinator.self) private var transcripts

  nonisolated static func == (a: MeetingTurnsDocument, b: MeetingTurnsDocument) -> Bool {
    a.rowID == b.rowID && a.player === b.player && a.renameSuggestions == b.renameSuggestions
      && MeetingDocumentHash.sameBytes(a.rawText, b.rawText)
      && MeetingDocumentHash.sameBytes(a.speakerNames, b.speakerNames)
      && TranscriptTurnsDocument.Inputs.sameTurns(a.turns, b.turns)
  }

  var body: some View {
    TurnDocumentView(
      turns: MeetingGapPresentation.localized(
        TranscriptDocumentPresenter.render(
          turns: turns, rawText: rawText, speakerNames: speakerNames,
          mode: .cleaned, timesOn: true, documentFinished: true, diffLookup: { _ in nil })),
      onRename: { speakerId, name in
        await transcripts.renameSpeaker(id: rowID, speakerId: speakerId, name: name, isMeeting: true)
      },
      onPlayFrom: player.map { player in
        { startMs in
          player.seek(toMs: startMs)
          player.play()
        }
      },
      renameSuggestions: renameSuggestions,
      fallback: { EmptyView() })
  }
}
