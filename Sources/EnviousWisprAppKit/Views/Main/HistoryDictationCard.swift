import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// One dictation in History's diary (#3147 §3.4, approved mock Main.dc.html): the recording's
/// player (or one line saying why there is none), the text in the row's preferred version, Show
/// edits with the Polished / Marked up / Original
/// comparison and the change inspector, a provenance line, and the actions.
///
/// **Delivery reads the live row at the press.** Copy, Paste, Share and Save hand over
/// `TranscriptCoordinator.textForDelivery` of the row as it is when the system asks
/// (`historyText`: the saved preference), never this card's snapshot and never the
/// temporary comparison view. Paste reads at the press, Share when the receiving app asks
/// (`DeliverableText`), Save after its panel closes.
///
/// **The recording lifecycle** (moved from PR1's `DictationRecordingSection`): the state is
/// read off the main actor when the card appears and whenever the row's recording changes
/// (`DictationRecordingChanges`), never in `body`; a read a deletion overtook is dropped, so no
/// player is built for deleted audio; one player per file, stopped when the card goes. The
/// shared `PlaybackArbiter` keeps one dictation playing across cards and windows.
///
/// **The comparison is prepared off the main actor** and cached by content
/// (`HistoryDiffCache`); a result is shown only for the texts it was computed from.
///
/// **Show edits work happens only on request (#4586).** With Show edits closed the card reads no
/// timing file and aligns nothing; a press loads the comparison and the recording's passage
/// times together and opens once both are ready for the current texts and recording revision.
struct HistoryDictationCard: View {
  /// What the card draws (#4609): complete on first display, so the card never resizes when a
  /// file read finishes. Actions read the live row at the press.
  let display: HistoryDictationDisplay
  let query: String
  /// #4101: why a History Paste did not happen; the History page holds the notice.
  let showPasteNotice: (String) -> Void

  init(display: HistoryDictationDisplay, query: String, showPasteNotice: @escaping (String) -> Void)
  {
    self.display = display
    self.query = query
    self.showPasteNotice = showPasteNotice
  }

  private var rowID: UUID { display.id }

  /// What can hold keyboard focus in the card; any focus reveals the card's controls.
  enum Focus: Hashable {
    case control(String)
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(AppWindowCoordinator.self) private var appWindow
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication
  @Environment(SettingsManager.self) private var settings
  @Environment(HistoryRepolishRunner.self) private var historyRepolish
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // Recording
  @State private var status: DictationRecordingStatus?
  @State private var polishPreview = HistoryPolishPreview()
  @State private var player: MeetingPlaybackController?
  @State private var playerURL: URL?
  /// Passage times loaded for one row, recording revision and text; loaded only behind Show
  /// edits (#4586).
  @State private var timed: TimedLoad?
  @State private var actionFailed = false
  /// Which action failed, in words (set before each action starts).
  @State private var actionFailureMessage = ""

  // Text
  @State private var prepared: HistoryDictationPresentation.Prepared?
  @State private var editsOn = false
  /// Show edits was pressed and the comparison is still being prepared (#4609): Marked up opens
  /// only once it is ready, so the text never shows plain and then grows.
  @State private var editsRequested = false
  @State private var comparisonView: HistoryDictationPresentation.TextView =
    HistoryDictationPresentation.editsView
  @State private var openChange: Int?
  @State private var textExpanded = false
  /// The deletion fence `status` was read under; a player is built only while it still holds
  /// (Codex r1 on #4611: a lazy first Play must not outrun a deletion that started after the read).
  @State private var recordingFence: RecordingFence?
  @State private var moreAnchor = HistoryMenuAnchorHolder()

  // Chrome
  @FocusState private var focus: Focus?
  @State private var copiedAt: Date?
  @State private var saveError: String?
  @State private var confirming: HistoryDeleteKind?
  /// The last preference change made here, offered for Undo until another action replaces it.
  @State private var preferenceNotice: HistoryPreferenceChange?

  private struct RecordingFence: Equatable {
    let deletions: Int?
    let epoch: Int?
  }

  private struct RecordingKey: Hashable {
    let rowID: UUID
    let revision: Int
  }

  /// What passage times are loaded for: the row, its recording revision (a new recording, a
  /// deletion or a Keep change moves it) and the original text the times are carried onto.
  private struct TimingKey: Hashable {
    let rowID: UUID
    let revision: Int
    let original: String
  }

  private struct TimedLoad {
    let key: TimingKey
    let spans: [HistoryDictationPresentation.TimedSpan]
  }

  /// The Show edits load's identity: a change to either restarts it.
  private struct EditsLoadKey: Hashable {
    let texts: HistoryDictationPresentation.Texts
    let timing: TimingKey
  }

  /// How a load's timing step ended.
  private enum TimingOutcome: Sendable {
    /// Times for this key were already loaded.
    case kept
    /// Loaded; empty when the recording has no timing file or it could not be read.
    case loaded([HistoryDictationPresentation.TimedSpan])
    case cancelled
  }

  var body: some View {
    card(display)
  }

  // MARK: - Card

  private func card(_ row: HistoryDictationDisplay) -> some View {
    let texts = HistoryDictationPresentation.Texts(row)
    let current = prepared.flatMap {
      HistoryDictationPresentation.accepts($0, current: texts) ? $0 : nil
    }
    return VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      HistoryPolishPreviewContent(preview: polishPreview)
      if editsOn, texts.differ { viewSwitch }
      if editsOn && texts.differ {
        HistoryEditsText(
          texts: texts, view: comparisonView, prepared: current, query: query,
          onOpenChange: { openChange = $0 }
        )
        .equatable()
      } else {
        // #4611: at most four lines until Show more, so a card is light to build and most
        // cards share a height.
        HistoryClampedText(
          text: HistoryDictationPresentation.plainText(
            texts,
            view: HistoryDictationPresentation.defaultView(for: row.effectivePreferredVersion)),
          query: query, expanded: textExpanded, onToggle: { textExpanded.toggle() }
        )
        .equatable()
      }
      if let current, editsOn, let index = openChange,
        let detail = HistoryDictationPresentation.detail(of: index, in: current, timeline: timeline)
      {
        HistoryChangeInspector(
          detail: detail, onHear: { play(from: $0) },
          onCopyOriginal: { PasteService.copyToClipboard($0, kind: .kept) },
          onDone: { openChange = nil })
      }
      playbackLine(row)
      buttonRow(row, hasChanges: texts.differ)
      if let change = preferenceNotice {
        preferenceNoticeRow(change)
      }
      if actionFailed {
        Text(verbatim: actionFailureMessage)
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
    .historyDiaryCard(border: cardBorder)
    // #4609 (Codex code review r1): new texts (a kept polish, a restore) close the comparison
    // rather than showing plain text and then growing into the new markup.
    .onChange(of: texts) { _, _ in
      editsRequested = false
      editsOn = false
      openChange = nil
    }
    .task(id: RecordingKey(rowID: rowID, revision: recordingRevision)) { await refreshRecording() }
    // #4586: nil while Show edits is neither requested nor open, so a closed card reads no
    // timing and prepares no comparison.
    .task(
      id: (editsRequested || editsOn) && texts.differ
        ? EditsLoadKey(texts: texts, timing: currentTimingKey) : nil
    ) {
      await loadEdits(texts: texts, timing: currentTimingKey)
    }
    .onDisappear {
      polishPreview.cancel()
      dropPlayer()
    }
    .confirmationDialog(
      Text(Self.confirmTitle(confirming ?? .textAndRecordings)),
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      presenting: confirming
    ) { kind in
      Button(role: .destructive) {
        delete(kind)
      } label: {
        Text(Self.confirmButton(kind))
      }
    } message: { kind in
      Text(Self.confirmMessage(kind))
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
  }

  /// #4611: Show edits opens and closes in one motion. The card grows or shrinks with this
  /// animation while History's list slides the cards below over the same time and curve.
  private var editsMotion: Animation? {
    HistoryRowMotion.request()
    return reduceMotion ? nil : DesignMotion.brisk
  }

  private var cardBorder: Color {
    player?.state == .playing ? Color.stAccent.opacity(0.35) : Color.stDivider
  }

  private var recordingRevision: Int {
    transcripts.recordings?.changes.revision(for: rowID) ?? 0
  }

  /// #4611: a dictation without a recording draws no player space; its footer says so. Known
  /// from the recordings listing before this card's own status read, so the card never changes
  /// height when that read arrives.
  private var lacksRecording: Bool {
    if case .absent = status { return true }
    return status == nil && transcripts.recordings?.changes.hasRecording(rowID) == false
  }

  private var absenceReason: RecordedAbsence? {
    if case .absent(let reason) = status { return reason }
    return nil
  }

  private var currentTimingKey: TimingKey {
    TimingKey(rowID: rowID, revision: recordingRevision, original: display.text)
  }

  /// The passage times the open comparison uses. An open card keeps the times it has for this
  /// row and text while a recording change reloads them (a Keep change reloads the same times,
  /// so Hear does not blink); the reload replaces them. The change inspector keeps Hear's space
  /// either way.
  private var timeline: [HistoryDictationPresentation.TimedSpan] {
    guard let timed, timed.key.rowID == rowID, timed.key.original == display.text else {
      return []
    }
    return timed.spans
  }

  /// Show edits may open: the comparison answers the current texts and the passage times are
  /// loaded for the current row, recording revision and text. Both ways of opening read this.
  private var editsReady: Bool {
    let texts = HistoryDictationPresentation.Texts(display)
    guard texts.differ, let prepared, HistoryDictationPresentation.accepts(prepared, current: texts)
    else { return false }
    return timed?.key == currentTimingKey
  }

  // MARK: - Text

  private var viewSwitch: some View {
    HStack(spacing: DesignSpacing.lg) {
      BrandedSegmentedPicker(
        options: [
          (Self.viewLabel(.polished), nil, HistoryDictationPresentation.TextView.polished),
          (Self.viewLabel(.markedUp), nil, .markedUp),
          (Self.viewLabel(.original), nil, .original),
        ],
        selection: Binding(
          get: { comparisonView },
          set: {
            comparisonView = $0
            openChange = nil
          }),
        hint: { String(localized: Self.viewHint($0)) }
      )
      .fixedSize()
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        Text(
          "Which words to show",
          comment: "History dictation card: the Polished, Marked up and Original choice."))
    }
  }

  /// #4586: the Show edits load. The comparison (cached by content, else prepared off the main
  /// actor) and the passage times (read on the recording archive's actor, aligned off the main
  /// actor) load together; this body only publishes. Nothing is published unless the card still
  /// wants edits for the same texts and recording revision, and a cancelled load publishes
  /// nothing.
  private func loadEdits(
    texts: HistoryDictationPresentation.Texts, timing key: TimingKey
  ) async {
    guard !Task.isCancelled, editsRequested || editsOn else { return }
    guard texts.differ else {
      editsRequested = false
      return
    }
    let cached = HistoryDiffCache.shared.result(for: texts)
    let timingSource: DictationRecordings?? =
      timed?.key == key ? .none : .some(transcripts.recordings)
    async let comparison = Self.comparison(texts, cached: cached)
    async let timing = Self.loadTiming(timingSource, key: key)
    let (computed, outcome) = await (comparison, timing)
    guard !Task.isCancelled, let result = computed else { return }
    if cached == nil { HistoryDiffCache.shared.store(result) }
    // The row may have changed while this ran (a restore): show only an answer for the texts the
    // card draws now (#4609: the display data, never a hydrated payload).
    guard editsRequested || editsOn,
      HistoryDictationPresentation.accepts(
        result, current: HistoryDictationPresentation.Texts(display)),
      currentTimingKey == key
    else { return }
    switch outcome {
    case .cancelled: return
    case .kept: break
    case .loaded(let spans): timed = TimedLoad(key: key, spans: spans)
    }
    prepared = result
    guard editsRequested, editsReady else { return }
    editsRequested = false
    withAnimation(editsMotion) { editsOn = true }
  }

  private nonisolated static func comparison(
    _ texts: HistoryDictationPresentation.Texts, cached: HistoryDictationPresentation.Prepared?
  ) async -> HistoryDictationPresentation.Prepared? {
    if let cached { return cached }
    // A cancelled load starts no alignment (Swift cancellation is only a flag).
    guard !Task.isCancelled else { return nil }
    return await HistoryDictationPresentation.prepareInBackground(texts)
  }

  /// Passage times for `key`. `recordings` is `.none` when they are already loaded, and
  /// `.some(nil)` with no recordings store (untimed). A missing or unreadable timing file
  /// leaves the card untimed; it never blocks Show edits or playback.
  private nonisolated static func loadTiming(
    _ recordings: DictationRecordings??, key: TimingKey
  ) async -> TimingOutcome {
    guard let recordings else { return .kept }
    guard let recordings else { return .loaded([]) }
    guard !Task.isCancelled else { return .cancelled }
    let timing = try? await recordings.timing(for: key.rowID)
    guard !Task.isCancelled else { return .cancelled }
    let spans = await HistoryDictationPresentation.timelineInBackground(
      timing, original: key.original)
    guard !Task.isCancelled else { return .cancelled }
    return .loaded(spans)
  }

  // MARK: - Footer

  private func provenance(_ row: HistoryDictationDisplay) -> some View {
    HStack(spacing: DesignSpacing.sm) {
      // #1408 / #1063 PR2: kept from the old History row (cloud review of PR #4555). A dictation
      // whose microphone was removed mid-recording may be cut short; one rebuilt from a recovered
      // recording says so. Icon and text, never colour alone.
      // #2087: a held Escape Recovery dictation's countdown ("Deleted in 20h"), or Kept after
      // the user kept it.
      if case .available(_, let durationMs, _) = status {
        Text(verbatim: MeetingsPresentation.clock(ms: durationMs)).monospacedDigit()
        Text(verbatim: "·").accessibilityHidden(true)
      }
      EscapeRecoveryBadge(display: row)
      ForEach(HistoryDictationPresentation.statusFlags(for: row), id: \.self) { flag in
        switch flag {
        case .interrupted:
          HStack(spacing: 2) {
            Image(systemName: "mic.slash.circle")
            Text("Interrupted")
          }
          .historyChip(tint: .stWarning, fill: Color.stWarning.opacity(0.15))
          .accessibilityLabel("Interrupted recording")
        case .recovered:
          HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise.circle")
            Text("Recovered")
          }
          .historyChip(tint: .stSuccess, fill: Color.stSuccess.opacity(0.15))
          .accessibilityLabel("Recovered recording")
        }
      }
      // A row with no recorded engine name shows no engine part, never a bare icon.
      let hasEngine = !row.backendName.isEmpty
      if hasEngine {
        Image(systemName: "waveform").accessibilityHidden(true)
        Text(verbatim: row.backendName)
      }
      if row.polishedText != nil, let model = row.llmModel {
        if hasEngine { Text(verbatim: "·").accessibilityHidden(true) }
        Image(systemName: "sparkles").accessibilityHidden(true)
        Text(verbatim: model)
      }
      if let line = expiryLine(row) {
        Text(verbatim: "·").accessibilityHidden(true)
        Text(line)
      }
      // #2087: a held dictation never has a recording; its countdown already says what it is.
      if lacksRecording, !isHeld(row) {
        HistoryFooterDot()
        HistoryUnplayableMark(
          label: LocalizedStringResource(
            "No recording",
            comment: "History dictation card footer: this dictation has no saved recording."),
          reason: String(localized: Self.absenceLine(absenceReason)))
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
    .lineLimit(1)
  }

  private func expiryLine(_ row: HistoryDictationDisplay) -> LocalizedStringResource? {
    guard case .available(_, _, let pinned) = status else { return nil }
    if pinned {
      return LocalizedStringResource(
        "Recording kept",
        comment: "History dictation card footer: this recording is never removed automatically.")
    }
    guard
      let date = HistoryDictationPresentation.recordingExpiry(
        savedAt: row.createdAt, keepDays: settings.dictationRecordingRetention.days, pinned: pinned)
    else { return nil }
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    return LocalizedStringResource(
      "Recording until \(day)",
      comment:
        "History dictation card footer: the recording is removed automatically after this date. %@ is a short date like Nov 18."
    )
  }

  // MARK: - Playback line and buttons (#4611)

  /// One line under the text: Play, then the recording's length and where the text came from.
  /// While the recording plays (or is paused part way) the same line shows its clock and
  /// waveform instead, so the card never changes height.
  private func playbackLine(_ row: HistoryDictationDisplay) -> some View {
    HStack(spacing: DesignSpacing.md) {
      if case .available = status {
        HistoryInlinePlayback(player: player, toggle: togglePlay) {
          provenance(row)
        }
      } else {
        provenance(row)
        if case .unreadable = status {
          Text(Self.unreadableLine)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .lineLimit(1)
        }
      }
    }
    .frame(minHeight: HistoryInlinePlaybackMetrics.buttonSize)
  }

  static let unreadableLine = LocalizedStringResource(
    "The recording can't be read right now.",
    comment: "History: the recording's file or details could not be read just now.")

  private func togglePlay() {
    guard let player = ensurePlayer() else { return }
    if player.state == .playing { player.pause() } else { player.play() }
  }

  /// Show edits, Copy and More, always in this place (#4611): fewer buttons, so a card is light
  /// to build, and the row never wraps when the window narrows.
  private func buttonRow(_ row: HistoryDictationDisplay, hasChanges: Bool) -> some View {
    HStack(spacing: DesignSpacing.md) {
      // #2087: a held Escape Recovery dictation is deleted in 24 hours unless kept, so Keep is
      // the card's first button while the offer stands.
      if isHeld(row) {
        Button {
          keepHeld(row)
        } label: {
          EnviousButtonLabel(
            verbatim: EscapeRecoveryRowPresentation.keepLabel, size: .medium,
            systemImage: "tray.and.arrow.down")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: keepAllowed(row))
        .disabled(!keepAllowed(row))
        .focused($focus, equals: .control("keep"))
        .help(
          Text(
            "Keep this dictation instead of deleting it in 24 hours",
            comment: "History dictation card: tooltip of Keep on a cancelled dictation."))
      }
      if hasChanges {
        Button {
          openChange = nil
          comparisonView = HistoryDictationPresentation.editsView
          if editsOn || editsRequested {
            editsRequested = false
            withAnimation(editsMotion) { editsOn = false }
          } else if editsReady {
            withAnimation(editsMotion) { editsOn = true }
          } else {
            editsRequested = true
          }
        } label: {
          EnviousButtonLabel(
            verbatim: editsOn ? Self.hideEditsLabel : Self.showEditsLabel, size: .medium,
            systemImage: "text.badge.checkmark")
        }
        .settingsButton(editsOn ? .filled : .outlined, size: .medium, isEnabled: true)
        .focused($focus, equals: .control("edits"))
        .accessibilityAddTraits(editsOn ? .isSelected : [])
      }

      let copy = TranscribeFileExport.copyButtonPresentation(
        label: Self.copyLabel, copiedAt: copiedAt, now: Date(), holdSeconds: Self.copiedHoldSeconds)
      Button {
        guard let text = exportText else { return }
        TranscribeFileExport.copy(text)
        let pressed = Date()
        copiedAt = pressed
        Task {
          try? await Task.sleep(for: .seconds(Self.copiedHoldSeconds))
          if copiedAt == pressed { copiedAt = nil }
        }
      } label: {
        Image(systemName: copy.systemImage)
          .frame(width: 16, height: 16)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .focused($focus, equals: .control("copy"))
      .help(Text(verbatim: copy.title))
      .accessibilityLabel(Text(verbatim: copy.title))

      moreMenu(row)
    }
    .fixedSize()
  }

  private func moreMenu(_ row: HistoryDictationDisplay) -> some View {
    // #4611: the app's own menu (the approved mock), under a round outlined button like Copy.
    Button {
      guard let anchor = moreAnchor.view else { return }
      historyMenu.toggle(items: moreItems(row), from: anchor)
    } label: {
      Image(systemName: "ellipsis")
        .fontWeight(.bold)
        .frame(width: 16, height: 16)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
    .background(HistoryMenuAnchor(holder: moreAnchor))
    .focused($focus, equals: .control("more"))
    .help(Text("More actions", comment: "History dictation card: opens the More menu."))
    .accessibilityLabel(
      Text("More actions", comment: "History dictation card: opens the More menu."))
  }

  /// The More menu's items, built when it opens, from the card's live state.
  private func moreItems(_ row: HistoryDictationDisplay) -> [HistoryMenuItem] {
    var items: [HistoryMenuItem] = [
      .init(
        id: "paste", title: EscapeRecoveryRowPresentation.pasteLabel,
        systemImage: "arrow.right.doc.on.clipboard",
        isEnabled: pasteAllowed(row) || !permissions.accessibilityGranted,
        kind: .action {
          if permissions.accessibilityGranted {
            paste(row)
          } else {
            navigation.request(.appSettings(.permissions))
          }
        }),
      .init(
        id: "share",
        title: String(localized: "Share…", comment: "History dictation card: shares the text."),
        systemImage: "square.and.arrow.up",
        kind: .action {
          guard let anchor = moreAnchor.view else { return }
          // Delivery reads the live row when the receiving app asks (`DeliverableText`), so a
          // deletion or a changed preference while the picker is open never sends old text
          // (cloud review on #4616).
          let provider = NSItemProvider()
          let history = transcripts
          let id = rowID
          provider.register(
            DeliverableText(resolve: { history.dictationTextForDelivery(id: id) }))
          NSSharingServicePicker(items: [provider]).show(
            relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }),
      .init(
        id: "save",
        title: String(
          localized: "Save as…", comment: "Export button: save the transcript to a file."),
        systemImage: "square.and.arrow.down", kind: .action { saveDocument() }),
      .divider("d1"),
    ]
    let polish = HistoryPolishMenu.menuItems(
      surface: .dictation, choices: historyRepolish.choices(.dictation),
      currentProvider: row.llmProvider, currentModel: row.llmModel, currentSize: row.egOneSize,
      isEnabled: polishPreview.canStart,
      select: { choice in
        polishPreview.start(
          rowID: rowID, choice: choice, runner: historyRepolish, history: transcripts)
      },
      setUp: {
        navigation.request(.aiPolish)
        appWindow.showWindow()
      })
    // #2087: a held Escape Recovery dictation cannot be polished again (the runner refuses it).
    if row.escapeRecoveredAt == nil {
      items.append(
        .init(
          id: "polish",
          title: String(
            localized: "Polish again with",
            comment: "History: opens the list of AI models to polish this text again."),
          systemImage: "sparkles", kind: .submenu(polish)))
    }
    if case .available(_, _, let pinned) = status {
      items.append(
        .init(
          id: "keep",
          title: String(
            localized: "Keep this recording",
            comment: "History: keeps this dictation's recording from being removed automatically."),
          isChecked: pinned, kind: .action { setKeep(!pinned) }))
    }
    switch HistoryDictationPresentation.preferenceAction(for: row) {
    case .restoreOriginal:
      items.append(
        .init(
          id: "restore",
          title: String(
            localized: "Restore original text",
            comment:
              "History dictation card, More menu: shows and delivers your words before AI polish instead of the polished text."
          ),
          systemImage: "arrow.uturn.backward", kind: .action { setPreference(.original) }))
    case .usePolished:
      items.append(
        .init(
          id: "use-polished",
          title: String(
            localized: "Use polished text",
            comment:
              "History dictation card, More menu: shows and delivers the AI-polished text again."),
          systemImage: "sparkles", kind: .action { setPreference(nil) }))
    case nil:
      break
    }
    items.append(.divider("d2"))
    if case .available = status {
      items.append(
        .init(
          id: "delete-recording",
          title: String(
            localized: "Delete recording, keep text",
            comment: "History: deletes this dictation's audio and keeps its text."),
          // Red like the meeting's: it deletes audio for good (DESIGN.md menus, founder #4611).
          systemImage: "waveform.slash", isDestructive: true,
          kind: .action { confirming = .recordingsOnly }))
    }
    items.append(
      .init(
        id: "delete",
        title: String(
          localized: "Delete dictation",
          comment: "VoiceOver label of the History delete button for a dictation."),
        systemImage: "trash", isDestructive: true, kind: .action { confirming = .textAndRecordings }
      ))
    return items
  }

  // MARK: - Delivery

  /// The live row's History text, read when asked; nil for a row that no longer exists, so
  /// nothing is delivered for an entry the user was told is gone.
  private var exportText: String? {
    transcripts.dictationTextForDelivery(id: rowID)
  }

  private func pasteAllowed(_ row: HistoryDictationDisplay) -> Bool {
    permissions.accessibilityGranted
      && EscapeRecoveryRowPresentation.allowsPaste(
        escapeRecoveredAt: row.escapeRecoveredAt, now: Date(),
        dictationInFlight: liveRecordingState.pipelineState.isActive)
  }

  /// #2087: whether this is a held Escape Recovery dictation whose Keep offer still stands. The
  /// rule lives in `EscapeRecoveryRowPresentation`.
  private func isHeld(_ row: HistoryDictationDisplay) -> Bool {
    if case .held = EscapeRecoveryRowPresentation.badge(
      escapeRecoveredAt: row.escapeRecoveredAt, takeID: row.escapeRecoveryTakeID, now: Date())
    {
      return true
    }
    return false
  }

  private func keepAllowed(_ row: HistoryDictationDisplay) -> Bool {
    EscapeRecoveryRowPresentation.allowsKeep(
      escapeRecoveredAt: row.escapeRecoveredAt, takeID: row.escapeRecoveryTakeID, now: Date(),
      dictationInFlight: liveRecordingState.pipelineState.isActive)
  }

  /// Keep, checked again at the press (a dictation may have started since the button was
  /// drawn); the coordinator revalidates the live row through the store.
  private func keepHeld(_ row: HistoryDictationDisplay) {
    guard keepAllowed(row) else { return }
    Task {
      guard let live = transcripts.liveHistoryRow(id: rowID) else { return }
      await transcripts.keep(live)
    }
  }

  /// History's Paste: the same clipboard transaction as Paste Last Dictation, into the app the
  /// user came from, reading the row's text at the press (#3875, #4101).
  private func paste(_ row: HistoryDictationDisplay) {
    historyPaste.paste(
      destination: previousApplication.lastOtherApplication,
      allowed: { [transcripts, liveRecordingState] in
        guard let live = transcripts.liveHistoryRow(id: rowID) else { return false }
        return EscapeRecoveryRowPresentation.allowsPaste(
          for: live, now: Date(), dictationInFlight: liveRecordingState.pipelineState.isActive)
      },
      text: { exportText },
      showHistory: {
        navigation.request(.history)
        appWindow.showWindow()
      },
      showNotice: { showPasteNotice($0) },
      dispatched: { [transcripts] in
        if let live = transcripts.liveHistoryRow(id: rowID) {
          transcripts.reportRestoredFromHistory(live)
        }
      })
  }

  /// The text is read AFTER the panel closes: the row can be deleted or expire while it is open.
  private func saveDocument() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = Self.dictationWord
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let text = exportText else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      saveError = error.localizedDescription
    }
  }

  // MARK: - Recording lifecycle (moved from DictationRecordingSection)

  /// Reads the recording's state and keeps a player only for the current file. A lookup that a
  /// deletion overtook is dropped, so a stale answer never builds a player for deleted audio.
  private func refreshRecording() async {
    guard let recordings = transcripts.recordings else { return }
    let arbiter = recordings.arbiter
    let id = PlaybackSourceID.dictation(rowID)
    let before = (arbiter?.deletionCount(for: id), arbiter?.dictationEpoch)
    let read = await recordings.status(for: rowID)
    guard !Task.isCancelled else { return }
    guard before == (arbiter?.deletionCount(for: id), arbiter?.dictationEpoch) else { return }
    status = read
    recordingFence = RecordingFence(deletions: before.0, epoch: before.1)
    switch read {
    case .available: recordings.changes.note(rowID, hasRecording: true)
    case .absent: recordings.changes.note(rowID, hasRecording: false)
    case .unreadable: break
    }
    guard case .available(let url, _, _) = read else {
      dropPlayer()
      return
    }
    // #4611: the player is built at the first Play, not when the card appears; a player built
    // for another file (or one a deletion stopped) goes now.
    if player != nil, Self.needsNewPlayer(current: player, currentURL: playerURL, read: url) {
      dropPlayer()
    }
  }

  /// The card's player, built on first use for the recording `status` names.
  private func ensurePlayer() -> MeetingPlaybackController? {
    if let player { return player }
    guard case .available(let url, let durationMs, _) = status,
      let recordings = transcripts.recordings, let fence = recordingFence
    else { return nil }
    let arbiter = recordings.arbiter
    guard
      fence
        == RecordingFence(
          deletions: arbiter?.deletionCount(for: .dictation(rowID)), epoch: arbiter?.dictationEpoch)
    else { return nil }
    let made = MeetingPlaybackController(
      media: .dictation(url), durationMs: durationMs, output: MeetingPlaybackEngineOutput(),
      sourceID: .dictation(rowID), arbiter: arbiter)
    player = made
    playerURL = url
    return made
  }

  /// One line per recorded reason (#3147 §3.4). Legacy or unexplained absence never guesses. An
  /// expiry names the keep period recorded when it happened, never today's setting.
  static func absenceLine(_ absence: RecordedAbsence?) -> LocalizedStringResource {
    switch absence?.reason {
    case .recordingsOff:
      LocalizedStringResource(
        "Recordings were off for this dictation.",
        comment: "History: no recording because recordings were off when this dictation started.")
    case .saveFailed:
      LocalizedStringResource(
        "Recording couldn't be saved.",
        comment: "History: the recording of this dictation failed to save.")
    case .deleted:
      LocalizedStringResource(
        "Recording deleted. The text stays.",
        comment: "History: the user deleted this dictation's recording and kept its text.")
    case .expired:
      if absence?.expiredAfterDays == 1 {
        LocalizedStringResource(
          "Recording expired after 1 day. The text stays.",
          comment:
            "History: the recording was removed after the one-day keep period chosen in Settings.")
      } else if let days = absence?.expiredAfterDays {
        LocalizedStringResource(
          "Recording expired after \(days) days. The text stays.",
          comment:
            "History: the recording was removed after the keep period chosen in Settings. %lld is a number of days, more than one."
        )
      } else {
        LocalizedStringResource(
          "Recording removed after your keep period. The text stays.",
          comment: "History: the recording was removed by the user's recording keep period.")
      }
    case .removedForSpace:
      LocalizedStringResource(
        "Recording removed to free space. The text stays.",
        comment: "History: the recording was removed automatically to free disk space.")
    case nil:
      LocalizedStringResource(
        "Recording unavailable.",
        comment: "History: this dictation has no recording and no recorded reason.")
    }
  }

  /// Whether a fresh, deletion-fenced read of available audio at `url` needs a new player. A
  /// player a deletion stopped stays stopped for good; when that removal failed and the audio is
  /// still there, a new player replaces it, so Play works again.
  static func needsNewPlayer(
    current: MeetingPlaybackController?, currentURL: URL?, read url: URL
  ) -> Bool {
    guard let current else { return true }
    return currentURL != url || current.state == .unavailable
  }

  private func dropPlayer() {
    player?.stop()
    player = nil
    playerURL = nil
  }

  private func play(from seconds: Double) {
    guard let player = ensurePlayer(), player.state != .unavailable else { return }
    player.seek(toMs: Int(seconds * 1000))
    player.play()
  }

  private func setKeep(_ keep: Bool) {
    guard let recordings = transcripts.recordings else { return }
    actionFailed = false
    actionFailureMessage = String(
      localized: "Couldn't change whether this recording is kept. Try again.",
      comment: "History dictation card: keeping or un-keeping the recording failed.")
    Task {
      do {
        if keep {
          try await recordings.pin(rowID: rowID)
        } else {
          try await recordings.unpin(rowID: rowID)
        }
      } catch {
        actionFailed = true
      }
    }
  }

  // MARK: - Preference and deletion

  /// Restore original text (`.original`) or Use polished text (`nil`, the default). The card
  /// shows the new preference at once (edits off, the preference's own view) and offers Undo.
  private func setPreference(_ version: Transcript.PreferredVersion?) {
    actionFailed = false
    actionFailureMessage = String(
      localized: "Couldn't change the saved text version. Try again.",
      comment: "History dictation card: Restore original text or Use polished text failed.")
    Task {
      do {
        guard let change = try await transcripts.setHistoryPreferredVersion(version, for: rowID)
        else {
          actionFailed = true
          return
        }
        editsOn = false
        editsRequested = false
        openChange = nil
        preferenceNotice = change
      } catch {
        actionFailed = true
      }
    }
  }

  private func undo(_ change: HistoryPreferenceChange) {
    actionFailed = false
    actionFailureMessage = String(
      localized: "Couldn't change the saved text version. Try again.",
      comment: "History dictation card: Restore original text or Use polished text failed.")
    Task {
      do {
        // False when a later choice replaced this one: nothing to put back, nothing failed.
        _ = try await transcripts.undoHistoryPreference(change)
        if preferenceNotice == change { preferenceNotice = nil }
      } catch {
        actionFailed = true
      }
    }
  }

  private func preferenceNoticeRow(_ change: HistoryPreferenceChange) -> some View {
    HStack(spacing: DesignSpacing.md) {
      Text(Self.preferenceNoticeLine(change))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      Button {
        undo(change)
      } label: {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Undo", comment: "History dictation card: undoes the text choice just made."),
          size: .medium)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .focused($focus, equals: .control("undo"))
    }
    .accessibilityElement(children: .contain)
  }

  /// Deletion through History's one command, with the outcome its owner reports. The recording
  /// stops playing before its file goes (the owner's own fence); a failure keeps the card and
  /// says so.
  private func delete(_ kind: HistoryDeleteKind) {
    confirming = nil
    actionFailed = false
    actionFailureMessage =
      kind == .recordingsOnly
      ? String(
        localized: "Couldn't delete the recording. Try again.",
        comment: "History dictation card: deleting only the recording failed.")
      : String(
        localized: "Couldn't delete the dictation. Try again.",
        comment: "History dictation card: deleting the dictation failed.")
    Task {
      let outcome = await transcripts.deleteHistoryItem(id: .transcript(rowID), kind: kind)
      if HistoryDictationPresentation.deletionFailed(outcome) { actionFailed = true }
    }
  }

  static func preferenceNoticeLine(_ change: HistoryPreferenceChange) -> LocalizedStringResource {
    change.after == .original
      ? LocalizedStringResource(
        "Original restored in History",
        comment:
          "History dictation card: History now shows and delivers your words before AI polish.")
      : LocalizedStringResource(
        "Polished text back in History",
        comment: "History dictation card: History shows and delivers the AI-polished text again.")
  }

  static func confirmTitle(_ kind: HistoryDeleteKind) -> LocalizedStringResource {
    switch kind {
    case .recordingsOnly:
      LocalizedStringResource(
        "Delete the recording?",
        comment: "History: confirmation title before deleting one dictation's audio.")
    case .textAndRecordings:
      LocalizedStringResource(
        "Delete this dictation?",
        comment: "History: confirmation title before deleting one dictation.")
    }
  }

  static func confirmMessage(_ kind: HistoryDeleteKind) -> LocalizedStringResource {
    switch kind {
    case .recordingsOnly:
      LocalizedStringResource(
        "The text stays in History. Only the audio is removed from this Mac.",
        comment: "History: confirmation message before deleting one dictation's audio.")
    case .textAndRecordings:
      LocalizedStringResource(
        "Its text and recording are removed from this Mac. This can't be undone.",
        comment: "History: confirmation message before deleting one dictation.")
    }
  }

  static func confirmButton(_ kind: HistoryDeleteKind) -> LocalizedStringResource {
    switch kind {
    case .recordingsOnly:
      LocalizedStringResource(
        "Delete recording", comment: "History: confirms deleting one dictation's audio.")
    case .textAndRecordings:
      LocalizedStringResource("Delete", comment: "History: confirms deleting one dictation.")
    }
  }

  // MARK: - Words

  static let copiedHoldSeconds: Double = TranscribeFileExport.copiedHoldSeconds

  static var dictationWord: String {
    String(
      localized: "Dictation",
      comment:
        "History detail title for a row made by dictating. Also the default file name when saving it."
    )
  }

  static var copyLabel: String {
    String(localized: "Copy", comment: "History dictation card: copies the text.")
  }

  static var showEditsLabel: String {
    String(
      localized: "Show edits", comment: "History dictation card: shows what AI Polish changed.")
  }

  static var hideEditsLabel: String {
    String(
      localized: "Hide edits", comment: "History dictation card: hides what AI Polish changed.")
  }

  static func viewLabel(_ view: HistoryDictationPresentation.TextView) -> String {
    switch view {
    case .polished:
      String(
        localized: "Polished",
        comment: "History dictation card: the view showing the AI-polished words.")
    case .markedUp:
      String(
        localized: "Marked up",
        comment: "History dictation card: the view showing what AI Polish changed.")
    case .original:
      String(
        localized: "Original",
        comment: "History dictation card: the view showing your words before AI polish.")
    }
  }

  static func viewHint(_ view: HistoryDictationPresentation.TextView) -> LocalizedStringResource {
    switch view {
    case .polished:
      LocalizedStringResource(
        "The polished version",
        comment: "History dictation card: hint beside the Polished view.")
    case .markedUp:
      LocalizedStringResource(
        "Click a marked word to compare",
        comment: "History dictation card: hint beside the Marked up view.")
    case .original:
      LocalizedStringResource(
        "Your words before AI polish",
        comment: "History dictation card: hint beside the Original view.")
    }
  }
}

/// #4586: the open Show edits text. Compared on what it draws (the texts, the chosen view, the
/// comparison it was drawn from and the search) and used with `.equatable()`, so a card redraw
/// that changes none of them (hover, focus, a Copy tick) does not split paragraphs or rebuild
/// the marked-up and highlighted text. `onOpenChange` is left out: it only sets the card's own
/// `@State`.
private struct HistoryEditsText: View, Equatable {
  let texts: HistoryDictationPresentation.Texts
  let view: HistoryDictationPresentation.TextView
  /// The comparison accepted for `texts`, or nil while none is.
  let prepared: HistoryDictationPresentation.Prepared?
  let query: String
  let onOpenChange: (Int) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.view == rhs.view && lhs.texts == rhs.texts && lhs.prepared?.texts == rhs.prepared?.texts
      && MeetingDocumentHash.sameBytes(lhs.query, rhs.query)
  }

  var body: some View {
    HistoryParagraphText(blocks: blocks, query: query, onOpenChange: onOpenChange)
  }

  private var blocks: [HistoryParagraphText.Block] {
    if view == .markedUp, let prepared {
      return HistoryDictationPresentation.markedUpParagraphs(prepared.markedUp).enumerated().map {
        HistoryParagraphText.Block(id: $0.offset, content: .markedUp($0.element))
      }
    }
    let text = HistoryDictationPresentation.plainText(
      texts, view: view == .markedUp ? .polished : view)
    return HistoryDictationPresentation.paragraphs(of: text).enumerated().map {
      HistoryParagraphText.Block(id: $0.offset, content: .plain($0.element.text))
    }
  }
}
