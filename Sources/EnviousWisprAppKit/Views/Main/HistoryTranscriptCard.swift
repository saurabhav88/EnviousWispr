import EnviousWisprCore
import EnviousWisprStorage
import SwiftUI

/// One imported transcript in the Transcripts tab (#3147 PR3 §3.5; compact layout #4611): the
/// file name, a two-line preview, one footer line in the Dictations card's style (length,
/// Recovered, Interrupted, the speech engine, the polish model, how many speakers, and Audio
/// unavailable when the file can't play), then Open, Copy and More. Locate original and Open in
/// new window live in More.
///
/// Open, Copy and More each keep their keyboard and VoiceOver actions. The card also opens on a
/// pointer click over the title, preview, footer or surrounding space.
///
/// **The original file is looked up off the body**: once when the card appears and whenever the
/// source owner bumps the row's revision. Nothing is said about it until the answer arrives, so
/// the card never flashes a claim it has not checked. The card never opens a player.
struct HistoryTranscriptCard: View {
  let rowID: UUID
  let sources: any ImportedSourceAccessing
  let onOpen: () -> Void
  let onLocate: () -> Void
  let query: String
  let summary: HistoryCatalog.Summary?

  init(
    rowID: UUID,
    sources: any ImportedSourceAccessing,
    query: String = "",
    summary: HistoryCatalog.Summary? = nil,
    onOpen: @escaping () -> Void,
    onLocate: @escaping () -> Void
  ) {
    self.rowID = rowID
    self.sources = sources
    self.query = query
    self.summary = summary
    self.onOpen = onOpen
    self.onLocate = onLocate
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @Environment(\.openWindow) private var openWindow
  /// Transcribe again's owner. Optional so a card hosted without it (a test) draws no chip.
  @Environment(TranscriptRetranscription.self) private var retranscription: TranscriptRetranscription?
  @State private var sourceState: ImportedSourceState?
  @State private var moreAnchor = HistoryMenuAnchorHolder()
  @State private var confirmingDelete = false
  @State private var deleting = false
  @State private var deleteFailed = false
  /// The title's rename field is open: a click on the card saves the name instead of opening.
  @State private var titleEditing = false
  /// The click that saved the title by clicking away; that click must not also open the card.
  @State private var clickAwayStamp: TimeInterval?

  private typealias P = HistoryTranscriptPresentation

  private struct SourceKey: Equatable {
    let rowID: UUID
    let revision: Int
    let reference: ImportedSourceReference?
    let sourceRevision: UInt64?
  }

  var body: some View {
    let row = transcripts.currentRow(id: rowID)
    Group {
      if let summary {
        // The loaded row's title first, so Open says the name the title shows after a rename.
        card(
          title: row.map(P.title(for:)) ?? summary.title ?? P.transcriptWord,
          seconds: summary.duration ?? 0,
          preview: summary.preview, chips: P.chips(for: summary), row: nil)
      } else if let row {
        card(
          title: P.title(for: row), seconds: row.duration, preview: row.historyText,
          chips: P.chips(for: row), row: row)
      }
    }
    .task(
      id: SourceKey(
        rowID: rowID, revision: sources.revision(for: rowID),
        reference: row.map(ImportedSourceReference.init), sourceRevision: transcripts.catalogSession?.revision)
    ) {
      if summary != nil { _ = await transcripts.loadCatalogDetail(rowID) }
      let state = await sources.state(for: rowID)
      guard !Task.isCancelled else { return }
      sourceState = state
    }
    .task(id: summary == nil ? nil : rowID) {
      if summary != nil { await transcripts.holdCatalogDetail(rowID) }
    }
  }

  private func card(
    title: String, seconds: TimeInterval, preview: String, chips: [P.Chip], row: Transcript?
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      // Its own buttons, so a click on the title renames instead of opening the card (#4611).
      TranscriptInlineTitle(
        rowID: rowID, fallbackTitle: title, searchQuery: query,
        isEditing: $titleEditing, clickAwayStamp: $clickAwayStamp)
      HistoryParagraphText.searchText(preview, query: query)
        .font(.stCardText)
        .foregroundStyle(.stTextBody)
        .lineLimit(2)
      footer(seconds: seconds, chips: chips, row: row)
      if deleteFailed {
        Text(
          "Couldn't delete the transcript. Try again.",
          comment: "History transcript: deleting the transcript failed; it is still here.")
          .font(.stHelper)
          .foregroundStyle(.stError)
      }
      buttonRow(title: title)
    }
    .historyDiaryCard(opensOnClick: true)
    .contentShape(Rectangle())
    .onTapGesture(perform: openOrFinishRename)
    // The same question and words as the transcript page's Delete transcript.
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
  }

  // MARK: - Footer

  /// The card never opens a player, so it says nothing about playback for a proven original;
  /// an unusable one shows the quiet Audio unavailable mark, its reason on hover.
  private var sourceLine: P.SourceLine {
    P.sourceLine(state: sourceState, playable: isAvailable)
  }

  private var isAvailable: Bool {
    if case .available = sourceState { return true }
    return false
  }

  /// One quiet line, the Dictations footer's style (#4611).
  private func footer(seconds: TimeInterval, chips: [P.Chip], row: Transcript?) -> some View {
    HStack(spacing: DesignSpacing.sm) {
      // While Transcribe again runs, the busy chip meeting cards show (#4611).
      if let state = retranscription?.state(for: rowID), P.isBusy(state),
        let line = P.retranscriptionLine(state)
      {
        HStack(spacing: DesignSpacing.xxs) {
          ProgressView().controlSize(.mini).accessibilityHidden(true)
          Text(verbatim: line)
        }
        .historyChip(tint: .stAccent, fill: Color.stAccent.opacity(0.14))
      }
      if let clock = P.footerClock(seconds: seconds) {
        Text(verbatim: clock).monospacedDigit()
        HistoryFooterDot()
      }
      // #2087: held countdown or Kept, from the shared Escape Recovery badge view.
      if let row { EscapeRecoveryBadge(transcript: row) }
      ForEach(Array(chips.enumerated()), id: \.element) { index, chip in
        if index > 0, Self.isInline(chip), Self.isInline(chips[index - 1]) { HistoryFooterDot() }
        chipView(chip)
      }
      if case .unavailable(let reason) = sourceLine {
        HistoryFooterDot()
        HistoryUnplayableMark(label: P.unplayableLabel, reason: P.unavailableLine(reason))
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
    .lineLimit(1)
  }

  /// Plain facts are joined by a dot; Recovered and Interrupted are chips and need none.
  private static func isInline(_ chip: P.Chip) -> Bool {
    switch chip {
    case .recovered, .interrupted: false
    case .speakers, .polish, .backend: true
    }
  }

  @ViewBuilder
  private func chipView(_ chip: P.Chip) -> some View {
    switch chip {
    case .speakers(let count):
      HistorySpeakersFact(text: count)
    case .recovered:
      // #1063 PR2: rebuilt from a recovered recording. Icon and text, never colour alone.
      HStack(spacing: 2) {
        Image(systemName: "arrow.clockwise.circle").accessibilityHidden(true)
        Text("Recovered")
      }
      .historyChip(tint: .stSuccess, fill: Color.stSuccess.opacity(0.15))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recovered recording")
    case .interrupted:
      // #1408: shown only for a verified device removal, never another cause.
      HStack(spacing: 2) {
        Image(systemName: "mic.slash.circle").accessibilityHidden(true)
        Text("Interrupted")
      }
      .historyChip(tint: .stWarning, fill: Color.stWarning.opacity(0.15))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Interrupted recording")
    case .polish(let model):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "sparkles").accessibilityHidden(true)
        Text(verbatim: model ?? "AI")
      }
    case .backend(let name):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "waveform").accessibilityHidden(true)
        Text(verbatim: name)
      }
    }
  }

  // MARK: - Buttons

  /// Clicking away from the rename field saves it and keeps the card on the list (#4611).
  private func openOrFinishRename() {
    guard HistoryInlineTitle.cardMayOpen(titleEditing: titleEditing, clickAwayStamp: clickAwayStamp)
    else { return }
    onOpen()
  }

  /// Open, Copy and More, in the Dictations card's place and order (#4611).
  private func buttonRow(title: String) -> some View {
    HStack(spacing: DesignSpacing.md) {
      Button(action: openOrFinishRename) {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Open", comment: "History transcript card: opens the full transcript."),
          size: .medium, trailingSystemImage: "chevron.right")
      }
      .settingsButton(.outlined, size: .medium, isEnabled: true)
      .accessibilityLabel(
        Text(
          "Open \(title)",
          comment: "History transcript card: VoiceOver label of Open. %@ is the file name."))

      // Read at the press from the live row, never this card's snapshot.
      HistoryIconCopyButton(
        label: TranscriptDocumentPresenter.exportButtonLabels(mode: .cleaned).copy
      ) { exportText }

      Button {
        guard let anchor = moreAnchor.view else { return }
        historyMenu.toggle(items: moreItems(), from: anchor)
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

  /// The card's More menu, built when it opens: Open in new window, Locate original while the
  /// original can't play, then Delete transcript (founder #4611, 2026-11-17). No Rename: the
  /// title's pencil renames. No "delete recording": a transcript keeps no copy of its audio;
  /// it plays the user's own file, which History never deletes.
  private func moreItems() -> [HistoryMenuItem] {
    var items: [HistoryMenuItem] = [
      .init(
        id: "new-window", title: String(localized: HistoryTranscriptView.newWindowLabel),
        systemImage: "macwindow.badge.plus",
        kind: .action { [openWindow, rowID] in
          openWindow(id: TranscriptWindowIdentity.sceneID, value: rowID)
        })
    ]
    if P.offersLocate(sourceLine) {
      items.append(
        .init(
          id: "locate", title: HistoryTranscriptView.locateLabel, systemImage: "magnifyingglass",
          kind: .action(onLocate)))
    }
    items.append(.divider("d1"))
    items.append(
      .init(
        id: "delete",
        title: String(
          localized: "Delete transcript",
          comment: "VoiceOver label of the History delete button for a transcript."),
        systemImage: "trash", isEnabled: !deleting, isDestructive: true,
        kind: .action { confirmingDelete = true }))
    return items
  }

  /// Deletes the transcript's text and its History row; the user's original file stays.
  private func delete() {
    confirmingDelete = false
    guard !deleting else { return }
    deleting = true
    deleteFailed = false
    Task {
      let outcome = await transcripts.deleteHistoryItem(
        id: .transcript(rowID), kind: .textAndRecordings)
      deleting = false
      deleteFailed = HistoryDictationPresentation.deletionFailed(outcome)
    }
  }

  /// The live row's cleaned text with its turn times, read when asked; nil for a row that no
  /// longer exists.
  private var exportText: String? {
    HistoryTranscriptExport.text(rowID: rowID, coordinator: transcripts, mode: .cleaned, timesOn: true)
  }
}
