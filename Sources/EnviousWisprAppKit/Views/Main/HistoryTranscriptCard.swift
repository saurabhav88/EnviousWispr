import AppKit
import EnviousWisprCore
import EnviousWisprStorage
import SwiftUI

/// One imported transcript in the Transcripts tab (#3147 PR3 §3.5; compact layout #4611): the
/// file name, a two-line preview, one footer line in the Dictations card's style (length,
/// Recovered, Interrupted, the speech engine, the polish model, speakers, and Original
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
  @State private var sourceState: ImportedSourceState?
  @State private var copiedAt: Date?
  @State private var moreAnchor = HistoryMenuAnchorHolder()
  /// Rename in More opens the title's field (#4611).
  @State private var renameRequested = false
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
        rowID: rowID, fallbackTitle: title, beginRequest: $renameRequested, searchQuery: query,
        isEditing: $titleEditing, clickAwayStamp: $clickAwayStamp)
      HistoryParagraphText.searchText(preview, query: query)
        .font(.stCardText)
        .foregroundStyle(.stTextBody)
        .lineLimit(2)
      footer(seconds: seconds, chips: chips, row: row)
      buttonRow(title: title)
    }
    .historyDiaryCard()
    .contentShape(Rectangle())
    .onTapGesture(perform: openOrFinishRename)
  }

  // MARK: - Footer

  /// The card never opens a player, so it says nothing about playback for a proven original;
  /// an unusable one shows the quiet Original unavailable mark, its reason on hover.
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
    case .speakers(let names):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "person.2").accessibilityHidden(true)
        Text(verbatim: names)
      }
      .truncationMode(.middle)
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

  /// Open, Copy and More, in the Dictations card's place and order (#4611).
  /// Clicking away from the rename field saves it (#4611, founder): `HistoryInlineTitle` saves
  /// on that click, and the card stays on the list instead of opening the transcript.
  private func openOrFinishRename() {
    guard !titleEditing else { return }
    // The same release that saved the name: compared by timestamp, so the save finishing
    // before this action runs (or a name left unchanged) cannot let the click open the card.
    if let stamp = clickAwayStamp, NSApp.currentEvent?.timestamp == stamp { return }
    onOpen()
  }

  private func buttonRow(title: String) -> some View {
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: TranscriptDocumentPresenter.exportButtonLabels(mode: .cleaned).copy, copiedAt: copiedAt,
      now: Date(), holdSeconds: TranscribeFileExport.copiedHoldSeconds)
    return HStack(spacing: DesignSpacing.md) {
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

      Button {
        // Read at the press from the live row, never this card's snapshot.
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
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .help(Text(verbatim: copy.title))
      .accessibilityLabel(Text(verbatim: copy.title))

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

  /// The card's More menu, built when it opens: Open in new window, and Locate original while
  /// the original can't play.
  private func moreItems() -> [HistoryMenuItem] {
    var items: [HistoryMenuItem] = [
      .init(
        id: "rename", title: HistoryTranscriptView.renameLabel, systemImage: "pencil",
        isEnabled: transcripts.currentRow(id: rowID)?.isImported == true,
        kind: .action { renameRequested = true }),
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
    return items
  }

  /// The live row's cleaned text with its turn times, read when asked; nil for a row that no
  /// longer exists.
  private var exportText: String? {
    HistoryTranscriptExport.text(rowID: rowID, coordinator: transcripts, mode: .cleaned, timesOn: true)
  }
}
