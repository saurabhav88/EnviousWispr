import CoreTransferable
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// Where a transcript's full view is shown.
enum TranscriptViewContext {
  /// Inside History's Transcripts tab; the diary draws the Back control above it.
  case history
  /// Its own window; no Open in new window button.
  case window
}

/// One imported transcript in full (#3147 PR3 §3.5, approved mock Transcripts.dc.html): the file
/// name and its provenance, Copy, Share, Save as…, Open in new window, More (Paste, Transcribe
/// again with, Locate original, Delete transcript), the Cleaned / Marked up / Original view with
/// Times, the turns (or the plain fallback), and the 88 pt docked player that plays the ORIGINAL
/// file.
///
/// **What it keeps from the legacy detail (`TranscriptDetailView`)**:
/// - The view mode and Times are screen-local, start at Cleaned with Times on, and reset when
///   the view shows another row.
/// - Turns render through `TranscriptTurnsDocument`; nil and empty turns both fall back to the
///   plain document (polished or processed output plus Original, or the raw words), and
///   processing without AI polish is labelled Processed.
/// - Rename popovers and Marked up diffs are keyed by the row AND its import attempt, so a
///   Transcribe again with replacement starts clean. Rename writes, failures and telemetry stay
///   on `TranscriptCoordinator` through the shared document.
/// - Copy, Share and Save hand over `HistoryTranscriptExport.text` read at delivery: Copy at the
///   press, Share when the receiving app asks, Save after its panel closes. Paste hands over
///   `HistoryTranscriptExport.pasteText` into the app the user came from.
/// - Delete goes through `deleteHistoryItem`, which stops this file's players first and never
///   touches the original file.
///
/// **The original file**: looked up off the body when the view appears and whenever the source
/// owner bumps the row's revision. A lookup that a deletion overtook is dropped (the arbiter's
/// deletion count and transcript epoch), so no player is built for a removed row. One player per
/// opened original, known to the shared now-playing owner; stopped when the view goes.
struct HistoryTranscriptView: View {
  let rowID: UUID
  let context: TranscriptViewContext
  let sources: any ImportedSourceAccessing
  let retranscription: any ImportedTranscriptRetranscribing
  let openInNewWindow: (UUID) -> Void

  init(
    rowID: UUID,
    context: TranscriptViewContext,
    sources: any ImportedSourceAccessing,
    retranscription: any ImportedTranscriptRetranscribing,
    openInNewWindow: @escaping (UUID) -> Void
  ) {
    self.rowID = rowID
    self.context = context
    self.sources = sources
    self.retranscription = retranscription
    self.openInNewWindow = openInNewWindow
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(AppWindowCoordinator.self) private var appWindow
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication

  // Document
  @State private var documentView: FileImportCoordinator.DocumentView = .cleaned
  @State private var timesOn = true

  // Original file
  @State private var sourceState: ImportedSourceState?
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: ResolvedImportedSource?
  /// The speed the user chose, kept while no player exists (the original went away and came
  /// back, or was located again).
  @State private var retainedRate: Float = 1

  // Actions
  @State private var copiedAt: Date?
  @State private var saveError: String?
  @State private var notice: Notice?
  @State private var confirmingDelete = false
  @State private var pendingRetranscription: ImportedASRChoice?
  @State private var locateRequested = false

  private typealias P = HistoryTranscriptPresentation

  /// One line under the header: what the last action did.
  private struct Notice: Equatable {
    let text: String
    let isError: Bool
  }

  private struct SourceKey: Equatable {
    let rowID: UUID
    let revision: Int
    let reference: ImportedSourceReference?
    let attempt: UUID?
  }

  var body: some View {
    Group {
      if let row = transcripts.currentRow(id: rowID) {
        content(row)
          .task(
            id: SourceKey(
              rowID: rowID, revision: sources.revision(for: rowID),
              reference: ImportedSourceReference(row), attempt: row.importAttemptID)
          ) {
            await refreshSource()
          }
      } else {
        removedPlaceholder
          .onAppear { dropPlayer() }
      }
    }
    .background(Color.stPageBg)
    .onChange(of: rowID) {
      documentView = .cleaned
      timesOn = true
      notice = nil
    }
    .onDisappear { dropPlayer() }
  }

  // MARK: - Layout

  private func content(_ row: Transcript) -> some View {
    VStack(spacing: 0) {
      header(row)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.top, context == .window ? SettingsLayout.contentTop : DesignSpacing.xs)
        .padding(.bottom, DesignSpacing.xl)
      Divider().overlay(Color.stDivider)
      ScrollView {
        document(row)
          .frame(maxWidth: 780, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, SettingsLayout.contentH)
          .padding(.vertical, DesignSpacing.xxl)
      }
      dock
    }
    .confirmationDialog(
      Text(
        "Delete this transcript?",
        comment: "History transcript: confirmation title before deleting one transcript."),
      isPresented: $confirmingDelete
    ) {
      Button(role: .destructive) {
        delete()
      } label: {
        Text("Delete", comment: "History transcript: confirms deleting one transcript.")
      }
    } message: {
      Text(
        "Its text is removed from this Mac. Your original file is never deleted. This can't be undone.",
        comment: "History transcript: confirmation message before deleting one transcript.")
    }
    .confirmationDialog(
      Text(
        "Transcribe again with \(pendingRetranscription?.title ?? "")?",
        comment:
          "History transcript: confirmation title before Transcribe again with. %@ is a speech model name."
      ),
      isPresented: Binding(
        get: { pendingRetranscription != nil },
        set: { if !$0 { pendingRetranscription = nil } }),
      presenting: pendingRetranscription
    ) { choice in
      Button {
        startRetranscription(choice)
      } label: {
        Text(
          "Transcribe again",
          comment: "History transcript: confirms Transcribe again with.")
      }
    } message: { _ in
      Text(
        "The new text replaces this transcript, including speaker names and cleanup. Your original file isn't changed.",
        comment: "History transcript: confirmation message before Transcribe again with.")
    }
    .alert(
      Text(
        "Couldn't save the file", comment: "History: the save panel's file could not be written."),
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(String(localized: "OK", comment: "Dismisses an alert.")) { saveError = nil }
    } message: {
      Text(verbatim: saveError ?? "")
    }
    .historyTranscriptLocate(
      rowID: rowID, sources: sources, isPresented: $locateRequested,
      onResult: { text, isError in notice = Notice(text: text, isError: isError) })
  }

  private var removedPlaceholder: some View {
    VStack(spacing: DesignSpacing.md) {
      Image(systemName: "doc.text")
        .font(.stRowTitle)
        .foregroundStyle(.stTextSecondary)
        .accessibilityHidden(true)
      Text(
        "This transcript is no longer in History.",
        comment: "History transcript: the transcript shown here was deleted."
      )
      .font(.stBody)
      .foregroundStyle(.stTextSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Header

  private func header(_ row: Transcript) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      HStack(alignment: .center, spacing: DesignSpacing.lg) {
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
          Text(verbatim: P.title(for: row))
            .font(.stRowTitle)
            .foregroundStyle(.stTextPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          provenance(row)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        actions(row)
      }
      if P.hasRenderableTurns(row) { viewControls }
      retranscriptionStatus
      if let notice {
        Text(verbatim: notice.text)
          .font(.stHelper)
          .foregroundStyle(notice.isError ? Color.stError : Color.stTextSecondary)
      }
    }
  }

  /// Created date and engine always; the polish model and AI Polished only from real polish
  /// provenance (legacy header rule).
  private func provenance(_ row: Transcript) -> some View {
    let facts = P.provenance(for: row)
    return WrappingHStack(spacing: DesignSpacing.sm) {
      Text(facts.createdAt, format: .dateTime.month().day().year().hour().minute())
      HStack(spacing: DesignSpacing.xs) {
        Image(systemName: "waveform").accessibilityHidden(true)
        Text(verbatim: facts.backend)
      }
      if let model = facts.polishModel {
        HStack(spacing: DesignSpacing.xs) {
          Image(systemName: "sparkles").accessibilityHidden(true)
          Text(verbatim: model)
        }
      }
      if facts.aiPolished {
        Text("AI Polished", comment: "History detail chip: AI polish rewrote this text.")
          .historyChip(tint: .stAccent, fill: Color.stAccent.opacity(0.16))
      }
      if let speakers = facts.speakers {
        HStack(spacing: DesignSpacing.xs) {
          Image(systemName: "person.2").accessibilityHidden(true)
          Text(verbatim: speakers)
        }
      }
      if let length = facts.length {
        Text(verbatim: length)
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
  }

  private func actions(_ row: Transcript) -> some View {
    // Save and Share are enabled from the displayed row without building the export; pressing
    // them still reads the export text from the live row.
    let availability = TranscriptDocumentPresenter.exportAvailability(
      turns: row.turns, fallback: transcripts.textForDelivery(row))
    let labels = TranscriptDocumentPresenter.exportButtonLabels(mode: documentView)
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: labels.copy, copiedAt: copiedAt, now: Date(),
      holdSeconds: TranscribeFileExport.copiedHoldSeconds)
    return HStack(spacing: DesignSpacing.md) {
      Button {
        // Read at the press from the live row, never this view's snapshot.
        guard let text = exportText else { return }
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
      .settingsButton(.quiet, size: .medium, isEnabled: availability != .none)

      // `DeliverableText`, never a String item: the sheet can stay open while the row changes
      // or goes, so the text is read when the receiving app asks for it.
      ShareLink(
        item: DeliverableText(resolve: { exportText }),
        preview: SharePreview(P.title(for: row))
      ) {
        EnviousButtonLabel(
          verbatim: labels.share, size: .medium, systemImage: "square.and.arrow.up")
      }
      .settingsButton(.quiet, size: .medium, isEnabled: availability == .content)

      Button {
        saveDocument(defaultName: P.title(for: row))
      } label: {
        EnviousButtonLabel(
          verbatim: labels.save, size: .medium, systemImage: "square.and.arrow.down")
      }
      .settingsButton(.quiet, size: .medium, isEnabled: availability != .none)

      if context == .history {
        Button {
          openInNewWindow(rowID)
        } label: {
          Image(systemName: "macwindow.badge.plus")
            .accessibilityHidden(true)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
        .help(Text(Self.newWindowLabel))
        .accessibilityLabel(Text(Self.newWindowLabel))
      }

      moreMenu(row)
    }
    .fixedSize()
  }

  private func moreMenu(_ row: Transcript) -> some View {
    let busy = P.isBusy(retranscription.state(for: rowID))
    let choices = retranscription.choices(for: rowID)
    return Menu {
      Button {
        pasteTapped(row)
      } label: {
        Label {
          Text(verbatim: EscapeRecoveryRowPresentation.pasteLabel)
        } icon: {
          Image(systemName: "arrow.right.doc.on.clipboard")
        }
      }
      // Legacy parity: unavailable without Accessibility or while the row may not be pasted.
      .disabled(!permissions.accessibilityGranted || !pasteAllowed(row))
      Divider()
      Menu {
        if choices.isEmpty {
          Text(
            "No speech models are ready",
            comment:
              "History transcript, Transcribe again with menu: no installed speech model can be used."
          )
        }
        ForEach(choices) { choice in
          Button {
            pendingRetranscription = choice
          } label: {
            Text(verbatim: choice.isCurrent ? Self.currentChoiceTitle(choice.title) : choice.title)
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
      .disabled(busy || !canRetranscribe || choices.isEmpty)
      if offersLocate {
        Button {
          locateRequested = true
        } label: {
          Label {
            Text(
              "Locate original…",
              comment: "History transcript: choose where the original audio or video file is now.")
          } icon: {
            Image(systemName: "magnifyingglass")
          }
        }
      }
      Divider()
      Button(role: .destructive) {
        confirmingDelete = true
      } label: {
        Label {
          Text(
            "Delete transcript",
            comment: "VoiceOver label of the History delete button for a transcript.")
        } icon: {
          Image(systemName: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(
      Text("More actions", comment: "History transcript: opens the More menu."))
  }

  private var viewControls: some View {
    HStack(spacing: DesignSpacing.lg) {
      BrandedSegmentedPicker(
        options: [
          (Self.modeLabel(.cleaned), nil, FileImportCoordinator.DocumentView.cleaned),
          (Self.modeLabel(.markedUp), nil, .markedUp),
          (Self.modeLabel(.original), nil, .original),
        ],
        selection: $documentView
      )
      .fixedSize()
      .accessibilityLabel(
        Text(
          "Which words to show",
          comment: "History transcript: the Cleaned, Marked up and Original choice."))
      Toggle(isOn: $timesOn) {
        Text("Times", comment: "History transcript: shows each turn's start time.")
          .font(.stRowLabel)
      }
      .toggleStyle(BrandedToggleStyle())
      .fixedSize()
      Text(verbatim: P.viewHint(mode: documentView, playable: activePlayer != nil))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private var retranscriptionStatus: some View {
    let state = retranscription.state(for: rowID)
    if let line = P.retranscriptionLine(state) {
      HStack(spacing: DesignSpacing.md) {
        if case .running = state {
          ProgressView().controlSize(.small)
        }
        Text(verbatim: line)
          .font(.stHelper)
          .foregroundStyle(P.isFailure(state) ? Color.stError : Color.stTextSecondary)
        if case .running = state {
          Button {
            retranscription.cancel(rowID: rowID)
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Cancel", comment: "History transcript: stops Transcribe again with."),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
    }
  }

  // MARK: - Document

  @ViewBuilder
  private func document(_ row: Transcript) -> some View {
    if let turns = row.turns, !turns.isEmpty {
      TranscriptTurnsDocument(
        inputs: TranscriptTurnsDocument.Inputs(
          rowID: row.id, text: row.text, turns: turns, speakerNames: row.speakerNames ?? [:],
          language: row.language, isMeeting: row.isMeeting, mode: documentView, timesOn: timesOn,
          documentFinished: documentFinished,
          renameSuggestions: SpeakerRenameSuggestions(row: row, roster: nil),
          playerIdentity: activePlayer.map(ObjectIdentifier.init)),
        onPlayFrom: { [player = activePlayer] ms in
          guard let player, player.state != .unavailable else { return }
          player.seek(toMs: ms)
          player.play()
        }
      )
      .equatable()
      // Rename popovers and Marked up diffs belong to one document: this row at this import
      // attempt. Turn IDs are document-local, so another row, or this row's text after
      // Transcribe again with, must start with none of them.
      .id(P.DocumentKey(row))
    } else {
      plainDocument(P.plainDocument(for: row))
    }
  }

  @ViewBuilder
  private func plainDocument(_ document: P.PlainDocument) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xxl) {
      switch document {
      case .polished(let output, let original):
        section(
          String(
            localized: "Polished", comment: "History detail section title: the AI-polished text."),
          icon: "sparkles", text: output, primary: true)
        section(Self.originalTitle, icon: "doc.text", text: original, primary: false)
      case .processed(let output, let original):
        section(
          String(
            localized: "Processed", comment: "History detail section title: the cleaned-up text."),
          icon: "doc.text", text: output, primary: true)
        section(Self.originalTitle, icon: "doc.text", text: original, primary: false)
      case .raw(let text):
        section(P.transcriptWord, icon: "doc.text", text: text, primary: true)
      }
    }
  }

  private func section(_ title: String, icon: String, text: String, primary: Bool) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      Label {
        Text(verbatim: title.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
      } icon: {
        Image(systemName: icon).accessibilityHidden(true)
      }
      .foregroundStyle(.stAccent)
      Text(verbatim: text)
        .font(.stBody)
        .lineSpacing(3)
        .foregroundStyle(primary ? Color.stTextPrimary : Color.stTextBody)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Finished unless the file import is still cleaning THIS row (#2851): a turn the cleanup has
  /// not reached yet is not "unpolished".
  private var documentFinished: Bool {
    !(transcripts.isImportInProgress?(rowID) ?? false)
  }

  // MARK: - Dock

  @ViewBuilder
  private var dock: some View {
    if let player = activePlayer {
      HistoryTranscriptPlayerBar(content: .player(player))
        .id(ObjectIdentifier(player))
    } else if case .unavailable(let reason) = sourceLine {
      HistoryTranscriptPlayerBar(
        content: .unavailable(reason, onLocate: { locateRequested = true }))
    }
  }

  private var sourceLine: P.SourceLine {
    P.sourceLine(state: sourceState, playable: activePlayer != nil)
  }

  /// The player this row can actually use: built for this row's original and still able to
  /// play. A player whose read failed, or one left from another row, offers no controls.
  private var activePlayer: MeetingPlaybackController? {
    guard let player, playerSource?.rowID == rowID, player.state != .unavailable else {
      return nil
    }
    return player
  }

  private var offersLocate: Bool { P.offersLocate(sourceLine) }

  /// Transcribe again with needs the original file.
  private var canRetranscribe: Bool { sourceLine == .plays }

  // MARK: - Original file lifecycle

  /// Reads the original's state, then opens it for playback. Both answers are dropped when a
  /// deletion or Delete All overtook them, so a removed row never gets a player.
  private func refreshSource() async {
    // Another row's player never serves this one, even while the new lookup runs.
    if let source = playerSource, source.rowID != rowID {
      dropPlayer()
      sourceState = nil
    }
    let arbiter = meetings.playbackArbiter
    let id = PlaybackSourceID.transcript(rowID)
    let fence = { (arbiter?.deletionCount(for: id), arbiter?.transcriptEpoch) }
    let before = fence()
    let state = await sources.state(for: rowID)
    guard !Task.isCancelled, before == fence() else { return }
    sourceState = state
    switch state {
    case .available, .unverifiable:
      break
    case .missing, .changed, .unreadable, .unsupportedIdentity, .removed:
      dropPlayer()
      return
    }
    let opened: ImportedPlaybackSource?
    do {
      opened = try await sources.playbackSource(for: rowID)
    } catch {
      opened = nil
    }
    guard !Task.isCancelled, before == fence(), transcripts.currentRow(id: rowID) != nil
    else { return }
    guard let opened else {
      dropPlayer()
      return
    }
    guard
      P.needsNewPlayer(current: player, currentSource: playerSource, resolved: opened.source)
    else { return }
    let rate = player?.playbackRate ?? retainedRate
    dropPlayer()
    let next = MeetingPlaybackController(
      media: .transcript(opened.audio), durationMs: opened.durationMs,
      output: MeetingPlaybackEngineOutput(), sourceID: id, arbiter: arbiter)
    next.setPlaybackRate(rate)
    player = next
    playerSource = opened.source
  }

  private func dropPlayer() {
    if let player { retainedRate = player.playbackRate }
    player?.stop()
    player = nil
    playerSource = nil
  }

  // MARK: - Delivery

  /// Copy, Share and Save: the live row's export in the current view mode and Times; nil for a
  /// row that is gone, so nothing is delivered for a transcript the user was told is gone.
  private var exportText: String? {
    HistoryTranscriptExport.text(
      rowID: rowID, coordinator: transcripts, mode: documentView, timesOn: timesOn)
  }

  private func pasteAllowed(_ row: Transcript) -> Bool {
    EscapeRecoveryRowPresentation.allowsPaste(
      for: row, now: Date(), dictationInFlight: liveRecordingState.pipelineState.isActive)
  }

  private func pasteTapped(_ row: Transcript) {
    guard permissions.accessibilityGranted else {
      navigation.request(.appSettings(.permissions))
      return
    }
    // #3875, #4101: History's clipboard transaction, into the app the user came from, with the
    // plain delivery text read at the press (never the mode-sensitive export).
    historyPaste.paste(
      destination: previousApplication.lastOtherApplication,
      allowed: { [transcripts, liveRecordingState, rowID] in
        guard let live = transcripts.currentRow(id: rowID) else { return false }
        return EscapeRecoveryRowPresentation.allowsPaste(
          for: live, now: Date(), dictationInFlight: liveRecordingState.pipelineState.isActive)
      },
      text: { [transcripts, rowID] in
        HistoryTranscriptExport.pasteText(rowID: rowID, coordinator: transcripts)
      },
      showHistory: {
        navigation.request(.history)
        appWindow.showWindow()
      },
      showNotice: { notice = Notice(text: $0, isError: true) },
      dispatched: { [transcripts, rowID] in
        if let live = transcripts.currentRow(id: rowID) {
          transcripts.reportRestoredFromHistory(live)
        }
      })
  }

  /// The text is read AFTER the panel closes: the row can change or be deleted while it is open.
  private func saveDocument(defaultName: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = defaultName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let text = exportText else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      // #3908: Foundation's localized sentence, never the NSError debug dump.
      saveError = error.localizedDescription
    }
  }

  // MARK: - Commands

  private func delete() {
    confirmingDelete = false
    notice = nil
    Task {
      let outcome = await transcripts.deleteHistoryItem(
        id: .transcript(rowID), kind: .textAndRecordings)
      if HistoryDictationPresentation.deletionFailed(outcome) {
        notice = Notice(
          text: String(
            localized: "Couldn't delete the transcript. Try again.",
            comment: "History transcript: deleting the transcript failed; it is still here."),
          isError: true)
      }
    }
  }

  private func startRetranscription(_ choice: ImportedASRChoice) {
    pendingRetranscription = nil
    notice = nil
    Task {
      _ = await retranscription.startConfirmed(rowID: rowID, selection: choice.selection)
    }
  }

  // MARK: - Words

  private static let newWindowLabel = LocalizedStringResource(
    "Open in new window", comment: "History transcript: opens this transcript in its own window.")

  private static var originalTitle: String {
    String(
      localized: "Original",
      comment: "History detail section title: the words as first transcribed.")
  }

  static func currentChoiceTitle(_ title: String) -> String {
    String(
      localized: "\(title) (current)",
      comment:
        "History transcript, Transcribe again with menu: the model this transcript was made with. %@ is the model name."
    )
  }

  static func modeLabel(_ mode: FileImportCoordinator.DocumentView) -> String {
    switch mode {
    case .cleaned:
      String(localized: "Cleaned", comment: "History transcript: the cleaned-up words view.")
    case .markedUp:
      String(
        localized: "Marked up",
        comment: "History transcript: the view showing what cleanup changed.")
    case .original:
      String(
        localized: "Original",
        comment: "History transcript: the words as the speech engine wrote them.")
    }
  }
}

// MARK: - Locate original

extension View {
  /// Locate original for one imported transcript (#3147 PR3 §3.5): a legacy row (no stored
  /// identity) is asked first, because the app cannot check the chosen file; then the open panel;
  /// then the source owner relinks. A known row whose owner still asks for confirmation is asked
  /// after the panel. `onResult` gets one sentence and whether it is a failure.
  func historyTranscriptLocate(
    rowID: UUID, sources: any ImportedSourceAccessing, isPresented: Binding<Bool>,
    onResult: @escaping (String, Bool) -> Void
  ) -> some View {
    modifier(
      HistoryTranscriptLocate(
        rowID: rowID, sources: sources, isPresented: isPresented, onResult: onResult))
  }
}

private struct HistoryTranscriptLocate: ViewModifier {
  let rowID: UUID
  let sources: any ImportedSourceAccessing
  @Binding var isPresented: Bool
  let onResult: (String, Bool) -> Void

  @Environment(TranscriptCoordinator.self) private var transcripts
  /// Asking before the panel (a legacy row), or after it with the chosen file.
  @State private var confirming: Confirmation?

  private enum Confirmation: Equatable {
    case beforePanel
    case chosen(URL)
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: isPresented) { _, requested in
        guard requested else { return }
        isPresented = false
        begin()
      }
      .confirmationDialog(
        Text(
          "Use a file for this older transcript?",
          comment:
            "History transcript, Locate original: confirmation title for a transcript saved without file details."
        ),
        isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
        presenting: confirming
      ) { confirmation in
        Button {
          confirmed(confirmation)
        } label: {
          switch confirmation {
          case .beforePanel:
            Text(
              "Choose file…",
              comment:
                "History transcript, Locate original: opens the file chooser after the confirmation."
            )
          case .chosen:
            Text(
              "Use this file",
              comment:
                "History transcript, Locate original: links the chosen file after the confirmation."
            )
          }
        }
      } message: { _ in
        Text(
          "This transcript was saved before EnviousWispr kept file details, so it can't check that the file you choose is the original. Choose only the file you transcribed.",
          comment:
            "History transcript, Locate original: why a legacy transcript needs confirmation.")
      }
  }

  private func begin() {
    guard let row = transcripts.currentRow(id: rowID) else {
      onResult(P.relocationLine(.removed) ?? "", true)
      return
    }
    if P.locateNeedsConfirmation(row) {
      confirming = .beforePanel
    } else if let url = choose() {
      relocate(url, userConfirmed: false)
    }
  }

  private func confirmed(_ confirmation: Confirmation) {
    confirming = nil
    switch confirmation {
    case .beforePanel:
      if let url = choose() { relocate(url, userConfirmed: true) }
    case .chosen(let url):
      relocate(url, userConfirmed: true)
    }
  }

  private func choose() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio, .movie]
    panel.message = String(
      localized: "Choose the original audio or video file for this transcript.",
      comment: "History transcript, Locate original: the file chooser's message.")
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private func relocate(_ url: URL, userConfirmed: Bool) {
    Task {
      do {
        let outcome = try await sources.relocate(
          rowID: rowID, to: url, userConfirmed: userConfirmed)
        if outcome == .confirmationRequired {
          // Ask once; a confirmed request that still needs it is not asked again.
          if userConfirmed {
            onResult(P.relocationFailedLine, true)
          } else {
            confirming = .chosen(url)
          }
          return
        }
        if let line = P.relocationLine(outcome) { onResult(line, outcome != .linked) }
      } catch {
        onResult(P.relocationFailedLine, true)
      }
    }
  }

  private typealias P = HistoryTranscriptPresentation
}
