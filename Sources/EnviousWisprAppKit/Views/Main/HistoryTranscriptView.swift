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
/// **What it keeps from the legacy detail view (removed in #4611)**:
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
  /// Previous and next transcript in the Transcripts list (#4611); none in the own window.
  let neighbors: HistoryNeighbors

  init(
    rowID: UUID,
    context: TranscriptViewContext,
    sources: any ImportedSourceAccessing,
    retranscription: any ImportedTranscriptRetranscribing,
    openInNewWindow: @escaping (UUID) -> Void,
    showPasteNotice: @escaping @MainActor (String) -> Void,
    restorePasteSurface: @escaping @MainActor () -> Void,
    back: (() -> Void)? = nil,
    neighbors: HistoryNeighbors = .none
  ) {
    self.rowID = rowID
    self.context = context
    self.sources = sources
    self.retranscription = retranscription
    self.openInNewWindow = openInNewWindow
    self.showPasteNotice = showPasteNotice
    self.restorePasteSurface = restorePasteSurface
    self.back = back
    self.neighbors = neighbors
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
  /// #4611 T8/T9: Follow playback, as on the meeting page; resets with each row.
  @State private var follow: MeetingAfterPresentation.Follow = .following
  @State private var activeTurnID: String?

  // Original file
  @State private var sourceState: ImportedSourceState?
  @State private var player: MeetingPlaybackController?
  @State private var playerSource: ResolvedImportedSource?
  /// The speed the user chose, kept while no player exists (the original went away and came
  /// back, or was located again).
  @State private var retainedRate: Float = 1

  // Actions
  @State private var saveError: String?
  @State private var notice: Notice?
  @State private var confirmingDelete = false
  @State private var pendingRetranscription: ImportedASRChoice?
  @State private var locateRequested = false
  @State private var moreAnchor = HistoryMenuAnchorHolder()
  /// Rename in More opens the title's field (#4611).
  /// The row whose read has finished. Until then a missing row is still loading, not deleted:
  /// stepping fast with the arrows flashed "no longer in History" (founder, #4611).
  @State private var finishedReadID: UUID?

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
      } else if finishedReadID == rowID {
        removedPlaceholder
          .onAppear { dropPlayer() }
      } else {
        Color.clear
      }
    }
    .background(Color.stPageBg)
    .task(id: CatalogDetailKey(id: rowID, revision: transcripts.catalogSession?.revision)) {
      _ = await transcripts.loadCatalogDetail(rowID)
      guard !Task.isCancelled else { return }
      finishedReadID = rowID
    }
    .task(id: rowID) { await transcripts.holdCatalogDetail(rowID) }
    .onChange(of: rowID) {
      documentView = .cleaned
      timesOn = true
      follow = .following
      activeTurnID = nil
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
        .padding(.bottom, DesignSpacing.lg)
      transcriptPane(row)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.bottom, DesignSpacing.xl)
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

  /// The shared page header (founder, #4611), laid out as the meeting page's (T2): the way back
  /// alone on the left, previous / next and More at the right, the title, then the facts with
  /// the engine and polish model as chips. The view picker, Copy and the settings moved into the
  /// transcript pane (T3, T8).
  private func header(_ row: Transcript) -> some View {
    HistoryDocumentHeader(
      tab: .transcripts, back: back, facts: facts(row),
      neighbors: neighbors,
      showsViewRow: false,
      timestamps: nil,
      trailingNavigation: true,
      speakersAccessory: speakersButton(row),
      engineChip: true,
      polishChip: true
    ) {
      TranscriptInlineTitle(
        rowID: rowID, fallbackTitle: P.title(for: row), font: .stDayTitle)
    } actions: {
      actions(row)
    } picker: {
      EmptyView()
    } switches: {
      EmptyView()
    } below: {
      retranscriptionStatus
      HistoryPolishPreviewContent(preview: polishPreview)
      if let notice {
        Text(verbatim: notice.text)
          .font(.stHelper)
          .foregroundStyle(notice.isError ? Color.stError : Color.stTextSecondary)
      }
    }
  }

  /// The facts row: date, length, speakers ("1 speaker" included, T4), the speech engine and the
  /// polish model (only from real polish provenance). Why the original can't play moved into
  /// the player card (T7).
  private func facts(_ row: Transcript) -> HistoryDocumentFacts {
    let provenance = P.provenance(for: row)
    return HistoryDocumentFacts(
      createdAt: provenance.createdAt,
      length: P.footerClock(seconds: row.duration),
      speakers: P.speakerCount(row.speakerAnalysis, names: row.speakerNames?.count),
      engine: provenance.backend,
      polishModel: provenance.aiPolished ? (provenance.polishModel ?? "AI") : nil)
  }

  /// Two or more speakers: the meeting page's "3 speakers" button (colored dots, a small arrow)
  /// that opens each speaker's share of the speaking time, measured from the turns' times as on
  /// a meeting (founder, #4611). One speaker, or turns without times, keep the plain fact.
  private func speakersButton(_ row: Transcript) -> AnyView? {
    let turns = row.turns ?? []
    guard let count = P.speakerNumber(row.speakerAnalysis, names: row.speakerNames?.count), count >= 2,
      let label = P.speakerCount(row.speakerAnalysis, names: row.speakerNames?.count)
    else { return nil }
    let participants = MeetingAfterPresentation.participants(
      turns: turns, speakerNames: row.speakerNames ?? [:])
    guard !participants.isEmpty else { return nil }
    return AnyView(
      MeetingSpeakersButton(
        label: label, participants: participants,
        colorIndices: MeetingAfterPresentation.speakerColorIndices(turns: turns)))
  }

  /// More, the Dictations card's pattern (#4611): Rename, Share, Save as, Open in new window,
  /// Paste, Polish again with, Transcribe again with, Locate original and Delete live in More.
  /// Copy moved beside the words it copies (T2, T3).
  private func actions(_ row: Transcript) -> some View {
    // Save and Share are enabled from the displayed row without building the export; pressing
    // them still reads the export text from the live row.
    let availability = TranscriptDocumentPresenter.exportAvailability(
      turns: row.turns, fallback: transcripts.textForDelivery(row))
    let labels = TranscriptDocumentPresenter.exportButtonLabels(mode: documentView)
    return HStack(spacing: DesignSpacing.md) {
      HistoryDocumentMoreButton(anchor: moreAnchor) {
        guard let anchor = moreAnchor.view else { return }
        historyMenu.toggle(
          items: moreItems(row, availability: availability, labels: labels), from: anchor)
      }
    }
  }

  /// The More menu's items, built when it opens, from the view's live state.
  private func moreItems(
    _ row: Transcript, availability: TranscriptDocumentPresenter.ExportAvailability,
    labels: (copy: String, save: String, share: String)
  ) -> [HistoryMenuItem] {
    let busy = P.isBusy(retranscription.state(for: rowID))
    let speechChoices = retranscription.choices(for: rowID)
    // No Rename: the title's pencil renames (founder #4611, 2026-11-17).
    // Paste first, as on the Dictations card and the meeting page. Legacy parity: unavailable
    // while the row may not be pasted; without Accessibility it opens the permission page.
    var items: [HistoryMenuItem] = [
      .init(
        id: "paste", title: EscapeRecoveryRowPresentation.pasteLabel,
        systemImage: "arrow.right.doc.on.clipboard",
        isEnabled: !permissions.accessibilityGranted || pasteAllowed(row),
        kind: .action { pasteTapped(row) }),
      .init(
        id: "share", title: labels.share, systemImage: "square.and.arrow.up",
        isEnabled: availability == .content,
        kind: .action {
          // The text is read when the receiving app asks for it, in the view and Times the
          // user had when they pressed Share.
          let history = transcripts
          let id = rowID
          let mode = documentView
          let times = timesOn
          HistoryDelivery.share(from: moreAnchor.view) {
            HistoryTranscriptExport.text(rowID: id, coordinator: history, mode: mode, timesOn: times)
          }
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

  private func viewPicker(_ row: Transcript) -> some View {
    let hasTimes = row.turns?.contains { $0.startMs != nil } == true
    let polished = row.polishedText != nil
    return BrandedSegmentedPicker(
      options: [
        (Self.modeLabel(.cleaned, polished: polished), nil, FileImportCoordinator.DocumentView.cleaned),
        (Self.modeLabel(.markedUp), nil, .markedUp),
        (Self.modeLabel(.original), nil, .original),
      ],
      selection: $documentView,
      hint: { P.viewHint(mode: $0, playable: hasTimes && activePlayer != nil, timesOn: timesOn) }
    )
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text(
        "Which words to show",
        comment: "History transcript: the Polished, Marked up and Original choice."))
  }

  // MARK: - Transcript pane (#4611 T1, T3, T8, T9)

  /// The transcript in the meeting page's pane card: one header row (the view picker, Copy and
  /// the settings button), then the words scrolling under it, for one speaker or several, with
  /// or without the original. Follow playback scrolls to the turn that plays; a deliberate scroll
  /// pauses it, and Return to playback floats over the bottom until the reader comes back.
  private func transcriptPane(_ row: Transcript) -> some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        paneHeader(row)
          .padding(.horizontal, DesignSpacing.lg)
          .padding(.vertical, DesignSpacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
        ScrollView {
          document(row)
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, DesignSpacing.xl)
            .padding(.vertical, DesignSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Only a scroll while playing pauses following; reading before Play does not (T9).
        .meetingUserScroll {
          if follow == .following, activePlayer?.state == .playing { follow = .suspended }
        }
      }
      .background(
        Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(alignment: .bottom) {
        if canFollow(row), follow == .suspended, activePlayer?.state == .playing {
          HistoryReturnToPlaybackButton { follow = .following }
            .shadow(color: .black.opacity(0.28), radius: 9, y: 6)
            .padding(.bottom, DesignSpacing.xl)
        }
      }
      .background {
        if let player = activePlayer, let turns = row.turns, !turns.isEmpty {
          MeetingFollowDriver(
            player: player, turns: turns, activeTurnID: $activeTurnID,
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

  /// The view picker (only when there is something to choose), then Copy and the settings button.
  private func paneHeader(_ row: Transcript) -> some View {
    let hasTimes = Self.hasTimes(row)
    let follows = canFollow(row)
    let availability = TranscriptDocumentPresenter.exportAvailability(
      turns: row.turns, fallback: transcripts.textForDelivery(row))
    return HStack(alignment: .center, spacing: DesignSpacing.md) {
      if P.hasRenderableTurns(row) || HistoryDictationPresentation.Texts(row).differ {
        viewPicker(row)
      }
      Spacer(minLength: 0)
      HStack(spacing: DesignSpacing.xs) {
        paneCopyButton(row, isEnabled: availability != .none)
        MeetingTranscriptSettingsButton(
          follow: follows
            ? Binding(get: { follow != .off }, set: { follow = $0 ? .following : .off }) : nil,
          timestamps: hasTimes ? $timesOn : nil,
          followUnavailable: follows
            ? nil
            : activePlayer == nil
              ? Text(
                "Needs audio",
                comment: "History transcript settings: Follow playback needs the original to play.")
              : Text(
                "Needs timestamps",
                comment: "History transcript settings: Follow playback needs saved turn times."),
          timestampsUnavailable: hasTimes
            ? nil
            : Text(
              "No times saved",
              comment: "History transcript settings: this transcript was saved without turn times."))
      }
      .fixedSize()
    }
    .frame(minHeight: 34)
  }

  /// #4611 T3: Copy beside the words, copying what this view copies (Marked up copies the cleaned
  /// text, as before); its spoken name says which. "Copied" holds for two seconds at its size.
  private func paneCopyButton(_ row: Transcript, isEnabled: Bool) -> some View {
    // Read at the press from the live row, never this view's snapshot.
    HistoryPaneCopyButton(
      spoken: Self.copySpokenName(mode: documentView, polished: row.polishedText != nil),
      isEnabled: isEnabled
    ) { exportText }
  }

  static func copySpokenName(mode: FileImportCoordinator.DocumentView, polished: Bool) -> String {
    switch mode {
    case .cleaned:
      polished
        ? String(localized: "Copy polished text", comment: "History transcript: Copy in Polished.")
        : String(localized: "Copy cleaned text", comment: "History transcript: Copy in Cleaned.")
    case .markedUp:
      String(
        localized: "Copy cleaned text",
        comment: "History transcript: Copy in Marked up, which copies the cleaned text.")
    case .original:
      String(localized: "Copy original text", comment: "History transcript: Copy in Original.")
    }
  }

  static func hasTimes(_ row: Transcript) -> Bool {
    row.turns?.contains { $0.startMs != nil } == true
  }

  /// Follow playback needs the original playing and turns with times.
  private func canFollow(_ row: Transcript) -> Bool {
    activePlayer != nil && Self.hasTimes(row)
  }

  /// The tinted turn: only while Follow playback is on and playback has started.
  private var shownActiveTurnID: String? {
    guard follow != .off, let player = activePlayer, player.state != .idle else { return nil }
    return activeTurnID
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
          playerIdentity: activePlayer.map(ObjectIdentifier.init),
          activeTurnID: shownActiveTurnID),
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
        Group {
          // List lines draw as dots in Polished only; Original keeps the words as heard.
          if documentView == .original {
            HistoryParagraphText.searchText(texts.original, query: searchQuery)
          } else {
            HistoryListText(text: texts.polished, query: searchQuery)
          }
        }
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

  /// #4611 T6/T7: the meeting page's player card (D10), with no note markers, while the original
  /// plays; without it the same place says "Audio unavailable" and why (Locate original stays in
  /// More). While the original is still being checked, nothing shows, as before.
  @ViewBuilder
  private var dock: some View {
    if let player = activePlayer {
      MeetingAfterPlayerBar(content: .player(player))
        .id(ObjectIdentifier(player))
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.bottom, DesignSpacing.xl)
    } else if case .unavailable(let reason) = sourceLine {
      MeetingAfterPlayerBar(
        content: .audioUnavailable(reason: P.unavailableLine(reason))
      )
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.bottom, DesignSpacing.xl)
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
    HistoryDelivery.save(defaultName: defaultName, text: { exportText }) { saveError = $0 }
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
