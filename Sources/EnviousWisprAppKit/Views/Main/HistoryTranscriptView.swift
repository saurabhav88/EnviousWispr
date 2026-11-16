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
  /// #4101: why a Paste did not happen, shown by the surface that outlives this view (the History
  /// page, or the transcript window's root), so replacing this view while Paste waits does not
  /// lose it.
  let showPasteNotice: @MainActor (String) -> Void
  /// Brings that same surface back to the front when Paste needs the user (main History, or the
  /// transcript window Paste was pressed in).
  let restorePasteSurface: @MainActor () -> Void
  let back: (() -> Void)?

  init(
    rowID: UUID,
    context: TranscriptViewContext,
    sources: any ImportedSourceAccessing,
    retranscription: any ImportedTranscriptRetranscribing,
    openInNewWindow: @escaping (UUID) -> Void,
    showPasteNotice: @escaping @MainActor (String) -> Void,
    restorePasteSurface: @escaping @MainActor () -> Void,
    back: (() -> Void)? = nil
  ) {
    self.rowID = rowID
    self.context = context
    self.sources = sources
    self.retranscription = retranscription
    self.openInNewWindow = openInNewWindow
    self.showPasteNotice = showPasteNotice
    self.restorePasteSurface = restorePasteSurface
    self.back = back
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication
  @Environment(HistoryRepolishRunner.self) private var historyRepolish
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @Environment(AppWindowCoordinator.self) private var appWindow
  @Environment(\.historyHighlightQuery) private var searchQuery

  // Document
  @State private var documentView: FileImportCoordinator.DocumentView = .cleaned
  @State private var flatComparison: HistoryDictationPresentation.Prepared?
  @State private var polishPreview = HistoryPolishPreview()
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
  @State private var moreAnchor = HistoryMenuAnchorHolder()

  private typealias P = HistoryTranscriptPresentation

  /// One line under the header: what the last action did.
  private struct Notice: Equatable {
    let text: String
    let isError: Bool
  }

  private struct CatalogDetailKey: Equatable {
    let id: UUID
    let revision: UInt64?
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
    .task(id: CatalogDetailKey(id: rowID, revision: transcripts.catalogSession?.revision)) {
      _ = await transcripts.loadCatalogDetail(rowID)
    }
    .task(id: rowID) { await transcripts.holdCatalogDetail(rowID) }
    .onChange(of: rowID) {
      documentView = .cleaned
      timesOn = true
      notice = nil
    }
    .onDisappear {
      polishPreview.cancel()
      dropPlayer()
    }
  }

  // MARK: - Layout

  private func content(_ row: Transcript) -> some View {
    VStack(spacing: 0) {
      header(row)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.top, SettingsLayout.contentTop)
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
    .onChange(of: row.importAttemptID) { _, _ in
      documentView = .cleaned
      flatComparison = nil
    }
  }

  private var removedPlaceholder: some View {
    VStack(spacing: DesignSpacing.md) {
      if let back { HistoryDestinationBar(tab: .transcripts, close: back) }
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
      // Side by side when the title keeps a readable width; otherwise the actions move to their
      // own row (long German labels at the 750 pt window floor squeezed the date into one
      // letter per line, #3147 PR3 UAT).
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: DesignSpacing.lg) {
          if let back { HistoryDestinationBar(tab: .transcripts, close: back) }
          titleBlock(row)
            .frame(minWidth: Self.titleMinWidth, maxWidth: .infinity, alignment: .leading)
          actions(row)
        }
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          HStack(spacing: DesignSpacing.lg) {
            if let back { HistoryDestinationBar(tab: .transcripts, close: back) }
            titleBlock(row)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          actions(row)
        }
      }
      if P.hasRenderableTurns(row) || HistoryDictationPresentation.Texts(row).differ {
        viewControls(row)
      }
      retranscriptionStatus
      HistoryPolishPreviewContent(preview: polishPreview)
      if let notice {
        Text(verbatim: notice.text)
          .font(.stHelper)
          .foregroundStyle(notice.isError ? Color.stError : Color.stTextSecondary)
      }
    }
  }

  /// The narrowest the file name and its facts may get beside the actions.
  private static let titleMinWidth: CGFloat = 260

  private func titleBlock(_ row: Transcript) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
      Text(verbatim: P.title(for: row))
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
      provenance(row)
    }
  }

  /// One quiet line in the Dictations footer's style (#4611): the date, the speech engine, the
  /// polish model (only from real polish provenance), speakers, the length, and Original
  /// unavailable with its reason on hover while the original can't play.
  private func provenance(_ row: Transcript) -> some View {
    let facts = P.provenance(for: row)
    return WrappingHStack(spacing: DesignSpacing.sm) {
      Text(facts.createdAt, format: .dateTime.month().day().year().hour().minute())
      HistoryFooterDot()
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "waveform").accessibilityHidden(true)
        Text(verbatim: facts.backend)
      }
      if facts.aiPolished {
        HistoryFooterDot()
        HStack(spacing: DesignSpacing.xxs) {
          Image(systemName: "sparkles").accessibilityHidden(true)
          Text(verbatim: facts.polishModel ?? "AI")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          Text(
            "AI Polished with \(facts.polishModel ?? "AI")",
            comment: "History transcript header, VoiceOver: AI polish rewrote this text. %@ is the model name."))
      }
      if let speakers = facts.speakers {
        HistoryFooterDot()
        HStack(spacing: DesignSpacing.xxs) {
          Image(systemName: "person.2").accessibilityHidden(true)
          Text(verbatim: speakers)
        }
      }
      if let clock = P.footerClock(seconds: row.duration) {
        HistoryFooterDot()
        Text(verbatim: clock).monospacedDigit()
      }
      if case .unavailable(let reason) = sourceLine {
        HistoryFooterDot()
        HistoryUnplayableMark(label: P.unplayableLabel, reason: P.unavailableLine(reason))
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
  }

  /// Copy and More, the Dictations card's pattern (#4611): Share, Save as, Open in new window,
  /// Paste, Polish again with, Transcribe again with, Locate original and Delete live in More.
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
        Image(systemName: copy.systemImage)
          .frame(width: 16, height: 16)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: availability != .none)
      .help(Text(verbatim: copy.title))
      .accessibilityLabel(Text(verbatim: copy.title))

      Button {
        guard let anchor = moreAnchor.view else { return }
        historyMenu.toggle(
          items: moreItems(row, availability: availability, labels: labels), from: anchor)
      } label: {
        Image(systemName: "ellipsis")
          .fontWeight(.bold)
          .frame(width: 16, height: 16)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .background(HistoryMenuAnchor(holder: moreAnchor))
      .help(Text("More actions", comment: "History transcript: opens the More menu."))
      .accessibilityLabel(
        Text("More actions", comment: "History transcript: opens the More menu."))
    }
    .fixedSize()
  }

  /// The More menu's items, built when it opens, from the view's live state.
  private func moreItems(
    _ row: Transcript, availability: TranscriptDocumentPresenter.ExportAvailability,
    labels: (copy: String, save: String, share: String)
  ) -> [HistoryMenuItem] {
    let busy = P.isBusy(retranscription.state(for: rowID))
    let speechChoices = retranscription.choices(for: rowID)
    var items: [HistoryMenuItem] = [
      .init(
        id: "share", title: labels.share, systemImage: "square.and.arrow.up",
        isEnabled: availability == .content,
        kind: .action {
          guard let anchor = moreAnchor.view else { return }
          // `DeliverableText`, never a String item: the picker can stay open while the row
          // changes or goes, so the text is read when the receiving app asks for it, in the
          // view and Times the user had when they pressed Share.
          let provider = NSItemProvider()
          let history = transcripts
          let id = rowID
          let mode = documentView
          let times = timesOn
          provider.register(
            DeliverableText(resolve: {
              HistoryTranscriptExport.text(rowID: id, coordinator: history, mode: mode, timesOn: times)
            }))
          NSSharingServicePicker(items: [provider]).show(
            relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }),
      .init(
        id: "save", title: labels.save, systemImage: "square.and.arrow.down",
        isEnabled: availability != .none,
        kind: .action { saveDocument(defaultName: P.title(for: row)) }),
    ]
    if context == .history {
      items.append(
        .init(
          id: "new-window", title: String(localized: Self.newWindowLabel),
          systemImage: "macwindow.badge.plus", kind: .action { openInNewWindow(rowID) }))
    }
    items.append(.divider("d1"))
    // Legacy parity: unavailable while the row may not be pasted; without Accessibility it opens
    // the permission page, as the Dictations card does.
    items.append(
      .init(
        id: "paste", title: EscapeRecoveryRowPresentation.pasteLabel,
        systemImage: "arrow.right.doc.on.clipboard",
        isEnabled: !permissions.accessibilityGranted || pasteAllowed(row),
        kind: .action { pasteTapped(row) }))
    let polish = HistoryPolishMenu.menuItems(
      surface: .transcript, choices: historyRepolish.choices(.transcript),
      currentProvider: row.llmProvider, currentModel: row.llmModel,
      currentSize: row.historyPolishEGOneSize,
      isEnabled: !busy && documentFinished && polishPreview.canStart,
      select: { choice in
        polishPreview.start(rowID: rowID, choice: choice, runner: historyRepolish, history: transcripts)
      },
      setUp: {
        navigation.request(.transcribeFile)
        appWindow.showWindow()
      })
    items.append(
      .init(
        id: "polish",
        title: String(
          localized: "Polish again with",
          comment: "History: opens the list of AI models to polish this text again."),
        systemImage: "sparkles", kind: .submenu(polish)))
    var speech: [HistoryMenuItem] = speechChoices.map { choice in
      .init(
        id: "asr-\(choice.id)",
        title: choice.isCurrent ? Self.currentChoiceTitle(choice.title) : choice.title,
        isEnabled: !busy && canRetranscribe,
        kind: .action { pendingRetranscription = choice })
    }
    if speechChoices.isEmpty {
      // #4578 (plan §3.10 item 8): with no speech engine downloaded, say how to get one back.
      speech.append(
        .init(
          id: "asr-none",
          title: String(
            localized: "No speech models are ready",
            comment:
              "History transcript, Transcribe again with menu: no installed speech model can be used."),
          isEnabled: false, kind: .action {}))
      speech.append(
        .init(
          id: "asr-setup",
          title: String(
            localized: "Download a speech engine in Settings to transcribe again.",
            comment: "History, Transcribe again with menu: tooltip while no speech engine is downloaded."),
          kind: .action {
            navigation.request(.transcribeFile)
            appWindow.showWindow()
          }))
    }
    items.append(
      .init(
        id: "transcribe-again",
        title: String(
          localized: "Transcribe again with",
          comment:
            "History transcript, More menu: transcribes the original file again with a chosen speech model."),
        systemImage: "arrow.clockwise", isEnabled: !busy && (canRetranscribe || speechChoices.isEmpty),
        kind: .submenu(speech)))
    if offersLocate {
      items.append(
        .init(
          id: "locate", title: Self.locateLabel, systemImage: "magnifyingglass",
          kind: .action { locateRequested = true }))
    }
    items.append(.divider("d2"))
    items.append(
      .init(
        id: "delete",
        title: String(
          localized: "Delete transcript",
          comment: "VoiceOver label of the History delete button for a transcript."),
        systemImage: "trash", isDestructive: true, kind: .action { confirmingDelete = true }))
    return items
  }

  private func viewControls(_ row: Transcript) -> some View {
    let hasTimes = row.turns?.contains { $0.startMs != nil } == true
    let polished = row.polishedText != nil
    return WrappingHStack(spacing: DesignSpacing.lg) {
      BrandedSegmentedPicker(
        options: [
          (Self.modeLabel(.cleaned, polished: polished), nil, FileImportCoordinator.DocumentView.cleaned),
          (Self.modeLabel(.markedUp), nil, .markedUp),
          (Self.modeLabel(.original), nil, .original),
        ],
        selection: $documentView,
        hint: { P.viewHint(mode: $0, playable: hasTimes && activePlayer != nil) }
      )
      .fixedSize()
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        Text(
          "Which words to show",
          comment: "History transcript: the Polished, Marked up and Original choice."))
      if hasTimes {
        Toggle(isOn: $timesOn) {
          Text("Times", comment: "History transcript: shows each turn's start time.")
            .font(.stRowLabel)
        }
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
      }
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
      // #4611: the reading size of a dictation card's text.
      .font(.stCardText)
      // Rename popovers and Marked up diffs belong to one document: this row at this import
      // attempt. Turn IDs are document-local, so another row, or this row's text after
      // Transcribe again with, must start with none of them.
      .id(P.DocumentKey(row))
    } else {
      flatDocument(HistoryDictationPresentation.Texts(row))
    }
  }

  @ViewBuilder
  private func flatDocument(_ texts: HistoryDictationPresentation.Texts) -> some View {
    Group {
      if documentView == .markedUp && texts.differ {
        if let flatComparison, HistoryDictationPresentation.accepts(flatComparison, current: texts) {
          let visible = HistoryParagraphText.attributed(flatComparison.markedUp, linksChanges: false)
          let highlighted = searchQuery.isEmpty ? visible : HistoryParagraphText.highlighting(
            visible, in: flatComparison.markedUp.map(\.text).joined(), query: searchQuery, markedUp: true)
          Text(highlighted)
            .textSelection(.enabled)
            .accessibilityRepresentation {
              Text(HistoryParagraphText.accessibilityText(flatComparison.markedUp))
            }
        } else {
          ProgressView("Comparing words")
        }
      } else {
        HistoryParagraphText.searchText(
          documentView == .original ? texts.original : texts.polished, query: searchQuery)
          .textSelection(.enabled)
      }
    }
    .font(.stCardText)
    .lineSpacing(3)
    .foregroundStyle(.stTextPrimary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: documentView == .markedUp && texts.differ ? texts : nil) {
      guard documentView == .markedUp, texts.differ else { return }
      if let cached = HistoryDiffCache.shared.result(for: texts) {
        flatComparison = cached
        return
      }
      let result = await HistoryDictationPresentation.prepareInBackground(texts)
      guard !Task.isCancelled else { return }
      HistoryDiffCache.shared.store(result)
      flatComparison = result
    }
  }

  /// Finished unless the file import is still cleaning THIS row (#2851): a turn the cleanup has
  /// not reached yet is not "unpolished".
  private var documentFinished: Bool {
    !(transcripts.isImportInProgress?(rowID) ?? false)
  }

  // MARK: - Dock

  /// The player while the original plays (#4611): with no playable original there is no bar;
  /// the header's Original unavailable mark says why, and Locate original is in More.
  @ViewBuilder
  private var dock: some View {
    if let player = activePlayer {
      HistoryTranscriptPlayerBar(player: player)
        .id(ObjectIdentifier(player))
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
      // Permissions lives in the main window, which may be closed behind a transcript window.
      navigation.request(.appSettings(.permissions))
      appWindow.showWindow()
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
      showHistory: { restorePasteSurface() },
      showNotice: { showPasteNotice($0) },
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

  static let newWindowLabel = LocalizedStringResource(
    "Open in new window", comment: "History transcript: opens this transcript in its own window.")

  static var locateLabel: String {
    String(
      localized: "Locate original…",
      comment: "History transcript: choose where the original audio or video file is now.")
  }

  static func currentChoiceTitle(_ title: String) -> String {
    String(
      localized: "\(title) (current)",
      comment:
        "History transcript, Transcribe again with menu: the model this transcript was made with. %@ is the model name."
    )
  }

  static func modeLabel(_ mode: FileImportCoordinator.DocumentView, polished: Bool = true) -> String {
    switch mode {
    case .cleaned:
      polished
        ? String(localized: "Polished", comment: "History transcript: the polished words view.")
        : String(localized: "Cleaned", comment: "History transcript: the cleaned-up words view.")
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
