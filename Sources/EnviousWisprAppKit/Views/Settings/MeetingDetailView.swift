import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// One meeting on the EnviousMeet page (#3972 §3.8): its name, status, kept audio and actions,
/// and its transcript through History's own paths (`TranscriptCoordinator.meetingProjection`,
/// `textForDelivery`, `renameSpeaker`), so the page and History can never show or deliver a
/// meeting differently. Every action re-reads the meeting by `meetingID` when it runs; a
/// confirmation belongs to this meeting only (the page rebuilds this view per meeting).
struct MeetingDetailView: View {
  let meetingID: UUID
  let onClose: () -> Void

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts

  @State private var titleDraft = ""
  @State private var confirming: Confirmation?
  @State private var actionInFlight = false
  @State private var audioSize: MeetingsPresentation.AudioSize = .measuring
  @State private var saveError: String?
  /// This meeting's player, made when its audio is available; stopped and dropped when the
  /// meeting closes, loses its audio or is deleted.
  @State private var player: MeetingPlaybackController?
  /// The source `player` was made from; a different source replaces it.
  @State private var playerSource: MeetingPlaybackSource?
  /// The scrubber's place while the user drags it; nil follows the player.
  @State private var scrubMs: Double?

  enum Confirmation: Equatable {
    case deleteAudio
    case deleteMeeting
  }

  var body: some View {
    if let record = meetings.record(id: meetingID) {
      BrandedSection(verbatimHeader: MeetingsPresentation.title(record)) {
        VStack(alignment: .leading, spacing: 14) {
          header(record)
          actions(record)
          if let confirming { confirmation(confirming, record: record) }
          if let player { playback(player) }
          transcript(record)
        }
        .padding(14)
      } footer: {
        EmptyView()
      }
      .task(id: AudioSizeKey(audioKept: record.audioKept, state: record.state)) {
        audioSize = .measuring
        audioSize = await meetings.audioSize(meetingID: meetingID)
      }
      .task(id: meetings.playbackSource(meetingID: meetingID)) {
        reconcilePlayer()
      }
      .onAppear { titleDraft = record.title ?? "" }
      .onDisappear { dropPlayer() }
      .alert(
        Text("The transcript could not be saved", comment: "EnviousMeet: Save failed."),
        isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button(String(localized: "OK", comment: "EnviousMeet: closes the Save error.")) {}
      } message: {
        Text(saveError ?? "")
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
    scrubMs = nil
  }

  /// What the audio size depends on, so it is measured again only when that changes.
  private struct AudioSizeKey: Hashable {
    let audioKept: Bool
    let state: MeetingState
  }

  // MARK: - Header

  private func header(_ record: MeetingRecord) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        TextField(
          String(
            localized: "Meeting name", comment: "EnviousMeet: the rename field's placeholder."),
          text: $titleDraft
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { rename() }
        .disabled(!record.isWritableByThisBuild)
        .accessibilityIdentifier("meetings.detail.title")
        Button {
          rename()
        } label: {
          Text("Rename", comment: "EnviousMeet: saves the meeting's new name.")
        }
        .disabled(titleDraft == (record.title ?? "") || !record.isWritableByThisBuild)
        Spacer(minLength: 0)
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Close", comment: "EnviousMeet: closes the meeting detail."))
      }
      let status = MeetingsPresentation.status(
        record, processingID: meetings.processing?.meetingID)
      Text(
        [
          MeetingsPresentation.statusLabel(status),
          MeetingsPresentation.duration(ms: record.recordedDurationMs),
          MeetingsPresentation.audioSizeLine(audioSize),
        ].joined(separator: " · ")
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      if let failure = MeetingsPresentation.failureLine(record) {
        Text(failure)
          .font(.stBody)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func rename() {
    let title = titleDraft
    Task { await meetings.rename(meetingID: meetingID, title: title) }
  }

  // MARK: - Actions

  private func actions(_ record: MeetingRecord) -> some View {
    let offered = MeetingsPresentation.actions(record, isActive: isActive(record))
    return HStack(spacing: 10) {
      SettingsActionButton(
        title: LocalizedStringResource(
          "Transcribe again",
          comment: "EnviousMeet: makes the meeting's transcript again from its kept audio."),
        isEnabled: offered.transcribeAgain && !actionInFlight, systemImage: "arrow.clockwise"
      ) {
        run { meetings in await meetings.retry(meetingID: meetingID) }
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
            run { meetings in await meetings.delete(meetingID: meetingID) }
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

  private func playback(_ player: MeetingPlaybackController) -> some View {
    let duration = Double(max(1, player.durationMs))
    let shown = scrubMs ?? Double(player.positionMs)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button {
          if player.state == .playing { player.pause() } else { player.play() }
        } label: {
          Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
            .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .disabled(player.state == .unavailable)
        .accessibilityLabel(
          player.state == .playing
            ? Text("Pause", comment: "EnviousMeet: pauses the meeting recording.")
            : Text("Play", comment: "EnviousMeet: plays the meeting recording.")
        )
        .accessibilityIdentifier("meetings.detail.play")
        Slider(
          value: Binding(get: { shown }, set: { scrubMs = $0 }), in: 0...duration,
          onEditingChanged: { editing in
            guard !editing, let target = scrubMs else { return }
            player.seek(toMs: Int(target))
            scrubMs = nil
          }
        )
        .disabled(player.state == .unavailable)
        .accessibilityLabel(Text("Position", comment: "EnviousMeet: the playback scrubber."))
        .accessibilityValue(Text(MeetingsPresentation.clock(ms: Int(shown))))
        Text(
          verbatim:
            "\(MeetingsPresentation.clock(ms: Int(shown))) / \(MeetingsPresentation.clock(ms: player.durationMs))"
        )
        .font(.stHelper.monospacedDigit())
        .foregroundStyle(.stTextSecondary)
        .accessibilityHidden(true)
      }
      if player.state == .unavailable {
        Text(
          "The recording can't be played. Its audio may have been deleted or damaged.",
          comment: "EnviousMeet detail: playback could not read the meeting's audio."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
  }

  private func isActive(_ record: MeetingRecord) -> Bool {
    if meetings.processing?.meetingID == record.id { return true }
    switch meetings.phase {
    case .recording(let id, _), .stopping(let id): return id == record.id
    case .starting, .idle: return false
    }
  }

  // MARK: - Transcript

  @ViewBuilder private func transcript(_ record: MeetingRecord) -> some View {
    if let row = transcripts.currentRow(id: record.transcriptID) {
      let projection = transcripts.meetingProjection(of: row)
      // Copy and Save deliver only visible turns; the text itself is built on press.
      let canDeliver: Bool = {
        if case .visible = projection { return true }
        return false
      }()
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          if !record.echoTurnIDs.isEmpty, record.state == .ready {
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
        }
        switch projection {
        case .visible(let turns, _):
          TurnDocumentView(
            turns: MeetingGapPresentation.localized(
              TranscriptDocumentPresenter.render(
                turns: turns, rawText: row.text, speakerNames: row.speakerNames ?? [:],
                mode: .cleaned, timesOn: true, documentFinished: true, diffLookup: { _ in nil })),
            onRename: { speakerId, name in
              transcripts.renameSpeaker(
                id: row.id, speakerId: speakerId, name: name, isMeeting: true)
            },
            onPlayFrom: player.map { player in
              { startMs in
                player.seek(toMs: startMs)
                player.play()
              }
            },
            fallback: { EmptyView() })
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

  /// The text is read AFTER the panel closes, so a meeting deleted meanwhile saves nothing.
  private func save(_ row: Transcript, record: MeetingRecord) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = MeetingsPresentation.title(record)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let live = transcripts.currentRow(id: row.id),
      let text = transcripts.textForDelivery(live)
    else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      saveError = error.localizedDescription
    }
  }
}
