import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// One dictation in History's diary (#3147 §3.4, approved mock Main.dc.html): the recording's
/// player (or one line saying why there is none), the text in the row's preferred version with a
/// reserved paragraph time gutter, Show edits with the Polished / Marked up / Original
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
struct HistoryDictationCard: View {
  let rowID: UUID
  /// #4101: why a History Paste did not happen; the History page holds the notice.
  let showPasteNotice: (String) -> Void

  init(rowID: UUID, showPasteNotice: @escaping (String) -> Void) {
    self.rowID = rowID
    self.showPasteNotice = showPasteNotice
  }

  /// What can hold keyboard focus in the card; any focus reveals the time gutter.
  enum Focus: Hashable {
    case gutter(Int)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // Recording
  @State private var status: DictationRecordingStatus?
  @State private var player: MeetingPlaybackController?
  @State private var playerURL: URL?
  @State private var timeline: [HistoryDictationPresentation.TimedSpan] = []
  @State private var actionFailed = false

  // Text
  @State private var prepared: HistoryDictationPresentation.Prepared?
  @State private var editsOn = false
  @State private var comparisonView: HistoryDictationPresentation.TextView =
    HistoryDictationPresentation.editsView
  @State private var openChange: Int?

  // Chrome
  @State private var hovering = false
  @FocusState private var focus: Focus?
  @State private var copiedAt: Date?
  @State private var saveError: String?
  @State private var confirming: HistoryDeleteKind?
  /// The last preference change made here, offered for Undo until another action replaces it.
  @State private var preferenceNotice: HistoryPreferenceChange?

  private struct RecordingKey: Hashable {
    let rowID: UUID
    let revision: Int
  }

  private struct TimingKey: Hashable {
    let rowID: UUID
    let revision: Int
    let original: String
    let available: Bool
  }

  var body: some View {
    if let row = transcripts.currentRow(id: rowID) {
      card(row)
    }
  }

  // MARK: - Card

  private func card(_ row: Transcript) -> some View {
    let texts = HistoryDictationPresentation.Texts(row)
    let current = prepared.flatMap {
      HistoryDictationPresentation.accepts($0, current: texts) ? $0 : nil
    }
    return VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      recordingRow
      if editsOn, current?.hasChanges == true { viewSwitch }
      HistoryParagraphText(
        blocks: blocks(row: row, texts: texts, prepared: current),
        hasGutter: player != nil && !timeline.isEmpty, revealGutter: revealGutter,
        reduceMotion: reduceMotion,
        focus: $focus,
        onPlay: { play(from: $0) },
        onOpenChange: { openChange = $0 })
      if let current, editsOn, let index = openChange,
        let detail = HistoryDictationPresentation.detail(of: index, in: current, timeline: timeline)
      {
        HistoryChangeInspector(
          detail: detail, onHear: { play(from: $0) },
          onCopyOriginal: { PasteService.copyToClipboard($0, kind: .kept) },
          onDone: { openChange = nil })
      }
      provenance(row)
      actions(row: row, hasChanges: current?.hasChanges == true)
      if let change = preferenceNotice {
        preferenceNoticeRow(change)
      }
      if actionFailed {
        Text(
          "That didn't work. Try again.",
          comment: "History: a recording action (keep or delete) failed."
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
      }
    }
    .padding(.horizontal, DesignSpacing.xl + DesignSpacing.xxs)
    .padding(.vertical, DesignSpacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(cardBorder, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .onHover { hovering = $0 }
    .task(id: RecordingKey(rowID: rowID, revision: recordingRevision)) { await refreshRecording() }
    .task(
      id: TimingKey(
        rowID: rowID, revision: recordingRevision, original: row.text, available: isAvailable)
    ) {
      await refreshTiming(original: row.text)
    }
    .task(id: texts) { await prepareComparison(texts) }
    .onDisappear { dropPlayer() }
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

  private var cardBorder: Color {
    player?.state == .playing ? Color.stAccent.opacity(0.35) : Color.stDivider
  }

  private var revealGutter: Bool { hovering || focus != nil }

  private var recordingRevision: Int {
    transcripts.recordings?.changes.revision(for: rowID) ?? 0
  }

  private var isAvailable: Bool {
    if case .available = status { return true }
    return false
  }

  // MARK: - Recording row

  @ViewBuilder
  private var recordingRow: some View {
    switch status {
    case .available:
      if let player {
        MeetingPlaybackControls(player: player, identifier: "history.card.recording.play")
          .id(ObjectIdentifier(player))
      }
    case .absent(let reason):
      Label {
        Text(Self.absenceLine(reason))
      } icon: {
        Image(systemName: "waveform.slash").accessibilityHidden(true)
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case .unreadable:
      Text(
        "The recording can't be read right now.",
        comment: "History: the recording's file or details could not be read just now."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    case nil:
      EmptyView()
    }
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
          })
      )
      .fixedSize()
      .accessibilityLabel(
        Text(
          "Which words to show",
          comment: "History dictation card: the Polished, Marked up and Original choice."))
      Text(Self.viewHint(comparisonView))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
  }

  private func blocks(
    row: Transcript, texts: HistoryDictationPresentation.Texts,
    prepared: HistoryDictationPresentation.Prepared?
  ) -> [HistoryParagraphText.Block] {
    let view: HistoryDictationPresentation.TextView =
      editsOn && prepared?.hasChanges == true
      ? comparisonView
      : HistoryDictationPresentation.defaultView(for: row.effectivePreferredVersion)
    if view == .markedUp, let prepared {
      return HistoryDictationPresentation.markedUpParagraphs(prepared.markedUp).enumerated().map {
        HistoryParagraphText.Block(
          id: $0.offset, content: .markedUp($0.element),
          seconds: HistoryDictationPresentation.time(ofMarkedUp: $0.element, in: timeline))
      }
    }
    let text = HistoryDictationPresentation.plainText(
      texts, view: view == .markedUp ? .polished : view)
    // Passage times index the original text; the polished text needs the alignment to carry
    // them, and stays untimed until it is prepared.
    let spans: [HistoryDictationPresentation.TimedSpan]
    if view == .original {
      spans = timeline
    } else if let prepared {
      spans = HistoryDictationPresentation.polishedTimeline(timeline, alignment: prepared.alignment)
    } else {
      spans = []
    }
    return HistoryDictationPresentation.paragraphs(of: text).enumerated().map {
      HistoryParagraphText.Block(
        id: $0.offset, content: .plain($0.element.text),
        seconds: HistoryDictationPresentation.time(of: $0.element.range, in: spans))
    }
  }

  private func prepareComparison(_ texts: HistoryDictationPresentation.Texts) async {
    if let cached = HistoryDiffCache.shared.result(for: texts) {
      prepared = cached
      return
    }
    let result = await HistoryDictationPresentation.prepareInBackground(texts)
    guard !Task.isCancelled else { return }
    HistoryDiffCache.shared.store(result)
    // The row may have changed while this ran (a restore): show only an answer for its texts.
    guard let live = transcripts.currentRow(id: rowID),
      HistoryDictationPresentation.accepts(
        result, current: HistoryDictationPresentation.Texts(live))
    else { return }
    prepared = result
  }

  // MARK: - Footer

  private func provenance(_ row: Transcript) -> some View {
    HStack(spacing: DesignSpacing.sm) {
      Image(systemName: "waveform").accessibilityHidden(true)
      Text(verbatim: row.backendType.displayName)
      if row.polishedText != nil, let model = row.llmModel {
        Text(verbatim: "·").accessibilityHidden(true)
        Image(systemName: "sparkles").accessibilityHidden(true)
        Text(verbatim: model)
      }
      if let line = expiryLine(row) {
        Text(verbatim: "·").accessibilityHidden(true)
        Text(line)
      }
    }
    .font(.stHelper)
    .foregroundStyle(.stTextSecondary)
    .lineLimit(1)
  }

  private func expiryLine(_ row: Transcript) -> LocalizedStringResource? {
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

  private func actions(row: Transcript, hasChanges: Bool) -> some View {
    HStack(spacing: DesignSpacing.md) {
      HStack(spacing: DesignSpacing.md) {
        pasteButton(row)
        ShareLink(
          item: DeliverableText(resolve: { exportText }),
          preview: SharePreview(Self.dictationWord)
        ) {
          EnviousButtonLabel(
            LocalizedStringResource("Share", comment: "History dictation card: shares the text."),
            size: .medium, systemImage: "square.and.arrow.up")
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
        .focused($focus, equals: .control("share"))
        Button {
          saveDocument()
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Save as…", comment: "Export button: save the transcript to a file."),
            size: .medium, systemImage: "square.and.arrow.down")
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
        .focused($focus, equals: .control("save"))
      }
      // Shown on hover and on keyboard focus anywhere in the card, as the mock places them.
      // The state changes without the fade under Reduce Motion.
      .opacity(revealGutter ? 1 : 0)
      .animation(reduceMotion ? nil : SettingsHover.animation, value: revealGutter)

      Spacer(minLength: 0)

      if hasChanges {
        Button {
          editsOn.toggle()
          openChange = nil
          comparisonView = HistoryDictationPresentation.editsView
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
        EnviousButtonLabel(verbatim: copy.title, size: .medium, systemImage: copy.systemImage)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .focused($focus, equals: .control("copy"))

      moreMenu(row)
    }
  }

  private func pasteButton(_ row: Transcript) -> some View {
    Button {
      if permissions.accessibilityGranted {
        paste(row)
      } else {
        navigation.request(.appSettings(.permissions))
      }
    } label: {
      EnviousButtonLabel(
        verbatim: EscapeRecoveryRowPresentation.pasteLabel, size: .medium,
        systemImage: "arrow.right.doc.on.clipboard")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: pasteAllowed(row))
    .focused($focus, equals: .control("paste"))
    .help(
      Text(
        "Paste into the app you were just using",
        comment: "History dictation card: tooltip of Paste."))
  }

  private func moreMenu(_ row: Transcript) -> some View {
    Menu {
      if case .available(_, _, let pinned) = status {
        Toggle(
          isOn: Binding(get: { pinned }, set: { setKeep($0) })
        ) {
          Text(
            "Keep this recording",
            comment: "History: keeps this dictation's recording from being removed automatically.")
        }
      }
      // The escape route sits beside the action that set it (§3.4: "The same menu offers Use
      // polished text when original is preferred").
      switch HistoryDictationPresentation.preferenceAction(for: row) {
      case .restoreOriginal:
        Button {
          setPreference(.original)
        } label: {
          Label {
            Text(
              "Restore original text",
              comment: "History dictation card, More menu: shows and delivers your words before AI polish instead of the polished text.")
          } icon: {
            Image(systemName: "arrow.uturn.backward")
          }
        }
      case .usePolished:
        Button {
          setPreference(nil)
        } label: {
          Label {
            Text(
              "Use polished text",
              comment: "History dictation card, More menu: shows and delivers the AI-polished text again.")
          } icon: {
            Image(systemName: "sparkles")
          }
        }
      case nil:
        EmptyView()
      }
      Divider()
      if case .available = status {
        Button {
          confirming = .recordingsOnly
        } label: {
          Label {
            Text(
              "Delete recording, keep text",
              comment: "History: deletes this dictation's audio and keeps its text.")
          } icon: {
            Image(systemName: "waveform.slash")
          }
        }
      }
      Button(role: .destructive) {
        confirming = .textAndRecordings
      } label: {
        Label {
          Text("Delete dictation", comment: "VoiceOver label of the History delete button for a dictation.")
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
    .focused($focus, equals: .control("more"))
    .accessibilityLabel(
      Text("More actions", comment: "History dictation card: opens the More menu."))
  }

  // MARK: - Delivery

  /// The live row's History text, read when asked; nil for a row that no longer exists, so
  /// nothing is delivered for an entry the user was told is gone.
  private var exportText: String? {
    guard let live = transcripts.currentRow(id: rowID) else { return nil }
    return transcripts.textForDelivery(live)
  }

  private func pasteAllowed(_ row: Transcript) -> Bool {
    permissions.accessibilityGranted
      && EscapeRecoveryRowPresentation.allowsPaste(
        for: row, now: Date(), dictationInFlight: liveRecordingState.pipelineState.isActive)
  }

  /// History's Paste: the same clipboard transaction as Paste Last Dictation, into the app the
  /// user came from, reading the row's text at the press (#3875, #4101).
  private func paste(_ row: Transcript) {
    historyPaste.paste(
      destination: previousApplication.lastOtherApplication,
      allowed: { [transcripts, liveRecordingState] in
        guard let live = transcripts.currentRow(id: rowID) else { return false }
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
        if let live = transcripts.currentRow(id: rowID) {
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
    guard case .available(let url, let durationMs, _) = read else {
      dropPlayer()
      return
    }
    guard
      Self.needsNewPlayer(current: player, currentURL: playerURL, read: url)
    else { return }
    dropPlayer()
    player = MeetingPlaybackController(
      media: .dictation(url), durationMs: durationMs, output: MeetingPlaybackEngineOutput(),
      sourceID: id, arbiter: arbiter)
    playerURL = url
  }

  /// Passage times, read off the main actor only while a recording exists. A missing or
  /// unreadable timing file leaves the card untimed; it never blocks playback.
  private func refreshTiming(original: String) async {
    guard isAvailable, let recordings = transcripts.recordings else {
      timeline = []
      return
    }
    let timing = try? await recordings.timing(for: rowID)
    guard !Task.isCancelled else { return }
    timeline = HistoryDictationPresentation.timeline(timing, original: original)
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
          comment: "History: the recording was removed after the one-day keep period chosen in Settings.")
      } else if let days = absence?.expiredAfterDays {
        LocalizedStringResource(
          "Recording expired after \(days) days. The text stays.",
          comment: "History: the recording was removed after the keep period chosen in Settings. %lld is a number of days, more than one.")
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
    guard let player, player.state != .unavailable else { return }
    player.seek(toMs: Int(seconds * 1000))
    player.play()
  }

  private func setKeep(_ keep: Bool) {
    guard let recordings = transcripts.recordings else { return }
    actionFailed = false
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
    Task {
      do {
        guard let change = try await transcripts.setHistoryPreferredVersion(version, for: rowID)
        else {
          actionFailed = true
          return
        }
        editsOn = false
        openChange = nil
        preferenceNotice = change
      } catch {
        actionFailed = true
      }
    }
  }

  private func undo(_ change: HistoryPreferenceChange) {
    actionFailed = false
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
          LocalizedStringResource("Undo", comment: "History dictation card: undoes the text choice just made."),
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
    Task {
      let outcome = await transcripts.deleteHistoryItem(id: .transcript(rowID), kind: kind)
      if HistoryDictationPresentation.deletionFailed(outcome) { actionFailed = true }
    }
  }

  static func preferenceNoticeLine(_ change: HistoryPreferenceChange) -> LocalizedStringResource {
    change.after == .original
      ? LocalizedStringResource(
        "Original restored in History",
        comment: "History dictation card: History now shows and delivers your words before AI polish.")
      : LocalizedStringResource(
        "Polished text back in History",
        comment: "History dictation card: History shows and delivers the AI-polished text again.")
  }

  static func confirmTitle(_ kind: HistoryDeleteKind) -> LocalizedStringResource {
    switch kind {
    case .recordingsOnly:
      LocalizedStringResource(
        "Delete the recording?", comment: "History: confirmation title before deleting one dictation's audio.")
    case .textAndRecordings:
      LocalizedStringResource(
        "Delete this dictation?", comment: "History: confirmation title before deleting one dictation.")
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

  static let copiedHoldSeconds: Double = 1.5

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
        "What was pasted", comment: "History dictation card: hint beside the Polished view.")
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
