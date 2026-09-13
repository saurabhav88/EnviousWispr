import CoreTransferable
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// Detail view for a single transcript: an action bar, a titled header with
/// metadata chips, and the polished/original text each in its own card (mockup
/// #27 aesthetic). Read-only display of existing data — no new features.
struct TranscriptDetailView: View {
  let transcript: Transcript
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @Environment(LiveRecordingState.self) private var liveRecordingState

  /// Screen-local, per-row UI state (#2811, phase 4 of #2807) — History has no persisted view
  /// mode today, and this phase does not add one (plan §2.2 non-goal). Reset on row change
  /// via `.onChange(of: transcript.id)`: without it, a stale Marked-up selection from one
  /// file would leak onto the next file's detail view, since SwiftUI otherwise preserves
  /// `@State` across a mere value change at the same tree position (§5 E2E audit).
  @State private var documentView: FileImportCoordinator.DocumentView = .cleaned
  @State private var timesOn = true
  @State private var turnDiffCache:
    (input: FileImportCoordinator.TurnDiffInput, results: [String: WordDiff.Result])?
  /// Surfaced via `.alert` rather than swallowed by `try?` (found by chunk review) — a failed
  /// disk write must not look identical to a successful one.
  @State private var saveError: String?

  /// #2087: the two actions this feature adds stand down while a dictation is
  /// in flight — Paste on a HELD recovery, and Keep.
  ///
  /// The decision lives in `EscapeRecoveryRowPresentation` rather than here, so
  /// its polarity is asserted behaviourally instead of by counting modifiers in
  /// this file. Both are checked for availability AND at press time, because a
  /// recording can start after the button is drawn and a disabled button is a
  /// hint, not a guarantee.
  ///
  /// Copy and an ordinary row's Paste are deliberately untouched: restricting
  /// them would change shipped behaviour for every user with this feature off.
  private var isDictationInFlight: Bool {
    liveRecordingState.pipelineState.isActive
  }

  private var pasteAllowed: Bool {
    EscapeRecoveryRowPresentation.allowsPaste(
      for: transcript, now: Date(), dictationInFlight: isDictationInFlight)
  }

  private var keepAllowed: Bool {
    EscapeRecoveryRowPresentation.allowsKeep(
      for: transcript, now: Date(), dictationInFlight: isDictationInFlight)
  }

  /// #2807: what this row IS, by name. A Dictation was made with the keybind; a Transcript
  /// came from Transcribe a File. Read from `isImported`, the row's only kind.
  private var kindWord: String {
    transcript.isImported ? "Transcript" : "Dictation"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      actionBar
      Divider().overlay(Color.stDivider)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header

          if let renderedTurns {
            transcriptSection(kindWord, icon: "doc.text") {
              // `fallback` is genuinely unreachable here — `renderedTurns` is already known
              // non-nil — so it carries no risk of the double-card nesting a reachable
              // `plainTextSections` would produce inside this same `transcriptSection`.
              TurnDocumentView(
                turns: renderedTurns,
                onRename: { id, name in
                  transcriptCoordinator.renameSpeaker(
                    id: transcript.id, speakerId: id, name: name)
                },
                onRenameCancelled: { transcriptCoordinator.noteRenameCancelled() },
                onTurnsDisplayed: { transcriptCoordinator.noteTurnsDisplayed(id: transcript.id) },
                fallback: { EmptyView() }
              )
            }
            .task(
              id: FileImportCoordinator.TurnDiffRequest(
                input: turnDiffInput, markedUp: documentView == .markedUp)
            ) {
              guard documentView == .markedUp else { return }
              await prepareTurnDiffs()
            }
            // Gives the WHOLE turn-rendering subtree — including every `TurnRowView`'s own
            // rename-popover `@State` — a fresh identity per document (found by chunk
            // review): `HistoryContentView` reuses this view across row selections at a
            // fixed tree position, and `ForEach`'s own `id: \.offset` can otherwise let a
            // rename popover opened on document A's turn survive into document B if B has a
            // turn at the same position, committing a rename against the wrong document.
            .id(transcript.id)
          } else {
            plainTextSections
          }
        }
        .padding(20)
      }
    }
    .background(Color.stPageBg)
    .onChange(of: transcript.id) {
      documentView = .cleaned
      timesOn = true
      turnDiffCache = nil
    }
    .alert(
      "Couldn't save the file",
      isPresented: Binding(
        get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button("OK") { saveError = nil }
    } message: {
      Text(saveError ?? "")
    }
  }

  // MARK: - Action bar

  private var actionBar: some View {
    HStack(spacing: 8) {
      Button {
        // #2087: `exportText` reads `textForDelivery` fresh by id rather than taking the
        // rendered row's own snapshot. A held recovery can lapse between this row appearing
        // and the press, and copying a snapshot would hand back text the user was told had
        // gone. Returns the text unchanged for an ordinary dictation.
        guard let text = exportText else { return }
        PasteService.copyToClipboard(text)
      } label: {
        Label(exportButtonLabels.copy, systemImage: "doc.on.doc")
      }
      .help("Copy to clipboard")

      // #2811, phase 4: History gains Save and Share, which did not exist before this phase
      // (plan §6 downstream consumer matrix) — reusing `exportText`'s SAME expiry-checked
      // selection as Copy, never a separate one.
      Button {
        saveDocument()
      } label: {
        Label(exportButtonLabels.save, systemImage: "square.and.arrow.down")
      }
      .disabled(exportText == nil)
      .help("Save as a text file")

      // `DeliverableText`, never a plain `String` item (found by chunk review): a share sheet
      // can sit open far longer than Save's modal, and a bare `String` freezes `exportText`
      // at THIS body evaluation — a row that expires (the escape-recovery 24-hour promise)
      // while the sheet is still open would still hand over its text. The closure defers the
      // read to whenever the system actually asks for the data.
      ShareLink(
        item: DeliverableText(resolve: { exportText }),
        preview: SharePreview(kindWord)
      ) {
        Label(exportButtonLabels.share, systemImage: "square.and.arrow.up")
      }
      .disabled(exportText == nil || exportText?.isEmpty == true)

      Button {
        if permissions.accessibilityGranted {
          guard pasteAllowed,
            let text = transcriptCoordinator.textForDelivery(transcript)
          else { return }
          PasteService.copyToClipboard(text)
          // #2087: the OTHER door back to a held recovery. The pill reports its
          // restores; without this one the funnel counted only the users who
          // caught a three-second offer. No-op for an ordinary row.
          transcriptCoordinator.reportRestoredFromHistory(transcript)
          NSApp.hide(nil)
          Task {
            try? await Task.sleep(for: .milliseconds(TimingConstants.appHideBeforePasteDelayMs))
            PasteService.simulatePaste()
          }
        } else {
          navigationCoordinator.request(.permissions)
        }
      } label: {
        Label(EscapeRecoveryRowPresentation.pasteLabel, systemImage: "arrow.right.doc.on.clipboard")
      }
      .disabled(!permissions.accessibilityGranted || !pasteAllowed)
      .help(
        permissions.accessibilityGranted
          ? "Paste into active app"
          : "Accessibility permission required for paste")

      // #2087: only while the offer stands. `keep` revalidates through the
      // store, so a press arriving after the row lapsed writes nothing — but
      // showing the button for a row that can no longer be kept would promise
      // an action that silently does nothing.
      if case .held = EscapeRecoveryRowPresentation.badge(for: transcript, now: Date()) {
        Button {
          guard keepAllowed else { return }
          transcriptCoordinator.keep(transcript)
        } label: {
          Label(EscapeRecoveryRowPresentation.keepLabel, systemImage: "tray.and.arrow.down")
        }
        .disabled(!keepAllowed)
        .help("Keep this recording permanently instead of letting it be deleted")
      }

      Spacer()

      Button(role: .destructive) {
        transcriptCoordinator.delete(transcript)
      } label: {
        Image(systemName: "trash")
          // The only irreversible control in the bar and the quietest thing in
          // it: borderless, secondary grey, no border. Hover in the error tone
          // so what it does is legible before it is pressed rather than after.
          .settingsHoverQuiet(tint: .stError)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.stTextSecondary)
      .accessibilityLabel("Delete \(kindWord.lowercased())")
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .tint(.stAccent)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: transcript.isImported ? "doc.text" : "mic")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 46, height: 46)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(kindWord)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.stTextPrimary)

        // Metadata: created time, then chips built only from real fields.
        HStack(spacing: 8) {
          Text(
            transcript.createdAt,
            format: .dateTime.month().day().year().hour().minute()
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)

          if transcript.polishedText != nil, let model = transcript.llmModel {
            metaChip(model, icon: "sparkles", accent: true)
          }
          metaChip(transcript.backendType.displayName, icon: nil, accent: false)
          if transcript.polishedText != nil {
            metaChip("AI Polished", icon: nil, accent: true)
          }
        }

        // View mode + Times (#2811 §2.1) — only meaningful once there are turns to show.
        // `hasRenderableTurns`, never a bare `!= nil` (found by chunk review): `turns == []`
        // is a real, reachable state (`TurnAssembler.assemble` can return it) that must
        // collapse to "nothing to show" exactly like `nil`, or these controls appear with
        // nothing for them to control.
        if hasRenderableTurns {
          HStack(spacing: 10) {
            Picker(
              "View", selection: $documentView
            ) {
              Text("Cleaned").tag(FileImportCoordinator.DocumentView.cleaned)
              Text("Marked up").tag(FileImportCoordinator.DocumentView.markedUp)
              Text("Original").tag(FileImportCoordinator.DocumentView.original)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Which words to show")
            Toggle("Times", isOn: $timesOn)
              .controlSize(.small)
              .toggleStyle(.switch)
          }
        }
      }
      Spacer(minLength: 0)
    }
  }

  private func metaChip(_ text: String, icon: String?, accent: Bool) -> some View {
    HStack(spacing: 3) {
      if let icon {
        Image(systemName: icon)
      }
      Text(text)
    }
    .font(.caption2)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      (accent ? Color.stAccent : Color.stTextSecondary).opacity(accent ? 0.16 : 0.14),
      in: Capsule()
    )
    .foregroundStyle(accent ? Color.stAccent : Color.stTextSecondary)
  }

  // MARK: - Transcript section card

  private func transcriptSection(
    _ eyebrow: String,
    icon: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        Text(eyebrow.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
      }

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.stSectionBg)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
        .overlay(
          RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
            .strokeBorder(Color.stDivider, lineWidth: 1)
        )
    }
  }

  // MARK: - Turn-labeled rendering (#2811, phase 4 of #2807)

  /// Today's own rendering, UNCHANGED — `TurnDocumentView`'s fallback, structurally
  /// unreachable here since the call site already gates on `transcript.turns != nil`, exactly
  /// mirroring the wizard's own `legacyTranscriptContent` shape.
  @ViewBuilder
  private var plainTextSections: some View {
    // #2772: a THIRD rung. An import whose polish was bypassed or failed everywhere
    // still has a derived document worth showing — numbers formatted, saved words
    // corrected — and it must not be labelled as AI-polished. Falling back to the raw
    // words instead would silently discard that work.
    // #2807: the section names say what the TEXT is (polished, processed, original);
    // the title above says what the row is (a dictation or a transcript).
    if let output = transcript.polishedText ?? transcript.processedText {
      transcriptSection(
        transcript.polishedText == nil ? "Processed" : "Polished",
        icon: transcript.polishedText == nil ? "doc.text" : "sparkles"
      ) {
        Text(output)
          .font(.system(size: 16))
          .lineSpacing(3)
          .foregroundStyle(.stTextPrimary)
          .textSelection(.enabled)
      }
      transcriptSection("Original", icon: "doc.text") {
        Text(transcript.text)
          .font(.system(size: 15))
          .lineSpacing(3)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
      }
    } else {
      transcriptSection(kindWord, icon: "doc.text") {
        Text(transcript.text)
          .font(.system(size: 16))
          .lineSpacing(3)
          .foregroundStyle(.stTextPrimary)
          .textSelection(.enabled)
      }
    }
  }

  /// `TurnAssembler.assemble` can return `[]` — collapses to the SAME "nothing to render"
  /// outcome as `nil` everywhere this view branches on turns, never just `!= nil`.
  private var hasRenderableTurns: Bool {
    guard let turns = transcript.turns else { return false }
    return !turns.isEmpty
  }

  private var renderedTurns: [TranscriptDocumentPresenter.RenderedTurn]? {
    let diffs = turnDiffs
    return TranscriptDocumentPresenter.render(
      turns: transcript.turns, rawText: transcript.text,
      speakerNames: transcript.speakerNames ?? [:], mode: documentView, timesOn: timesOn,
      // A stored row is read as finished: the disclosure follows the stored turns, and a
      // row still being imported clears it turn by turn as the cleanup lands (#2851 §3 D).
      documentFinished: true,
      diffLookup: { diffs?[$0.id] })
  }

  /// Mirrors `FileImportCoordinator.turnDiffInput`, reusing its own `TurnDiffPair`/
  /// `TurnDiffInput` types (chunk review found their FIRST duplicate; this would have been a
  /// second) — the wizard and History prepare the same per-turn diff shape from different
  /// live/persisted sources.
  private var turnDiffInput: FileImportCoordinator.TurnDiffInput {
    guard let turns = transcript.turns else {
      return FileImportCoordinator.TurnDiffInput(pairs: [], language: transcript.language)
    }
    let text = transcript.text
    let pairs = turns.map { turn -> FileImportCoordinator.TurnDiffPair in
      let original = TranscriptDocumentPresenter.slice(text, turn.originalTextRange)
      return FileImportCoordinator.TurnDiffPair(
        id: turn.id, original: original, cleaned: turn.processedText ?? original)
    }
    return FileImportCoordinator.TurnDiffInput(pairs: pairs, language: transcript.language)
  }

  /// `nil` while `prepareTurnDiffs` is still running or the input has moved — same
  /// input-matches-cache contract as `FileImportCoordinator.turnDiffs` (found by chunk
  /// review: an unkeyed dictionary can go on describing OLDER text after this row's own
  /// turns change under it — a retry or a background pass replacing `processedText` while
  /// this row happens to still be selected — even though the turn ids themselves survive).
  private var turnDiffs: [String: WordDiff.Result]? {
    guard let cached = turnDiffCache, cached.input == turnDiffInput else { return nil }
    return cached.results
  }

  /// Off the main actor, same reason as the wizard's own `prepareTurnDiffs` (chunk-1 review:
  /// `WordDiff` can take ~3 seconds on worst-case inputs). `View` is a VALUE type, so this
  /// `async` method runs against a `self` FROZEN at the moment `.task(id:)` invoked it —
  /// `turnDiffInput` inside this function keeps reading THAT frozen `transcript` forever, so
  /// it can never observe a row-selection change on its own (found by chunk review: two
  /// selections whose diffs finish OUT OF ORDER — A's slow computation outliving a switch to
  /// B, then landing after B's own already has — would otherwise let A silently overwrite B's
  /// cache, since the input comparison alone always reads true against itself). `Task
  /// .isCancelled` is the one signal that DOES observe it: `.task(id:)` cancels the previous
  /// invocation's Task the instant the id changes, which is exactly A's task in that repro.
  private func prepareTurnDiffs() async {
    let input = turnDiffInput
    guard turnDiffs == nil, !input.pairs.isEmpty else { return }
    let worker = Task.detached(priority: .userInitiated) {
      var results: [String: WordDiff.Result] = [:]
      for pair in input.pairs {
        // Between compares: selecting another row cancels this `.task(id:)` invocation, and
        // the handler below forwards that to the worker, which stops at the next turn
        // instead of diffing a long transcript nobody is looking at (found by cloud review,
        // round 4). `Task.detached` does not inherit the caller's cancellation on its own.
        guard !Task.isCancelled else { break }
        results[pair.id] = WordDiff.compare(
          original: pair.original, cleaned: pair.cleaned, language: input.language)
      }
      return results
    }
    let computed = await withTaskCancellationHandler(
      operation: { await worker.value },
      onCancel: { worker.cancel() }
    )
    guard !Task.isCancelled, turnDiffInput == input else { return }
    turnDiffCache = (input, computed)
  }

  /// What Copy/Save/Share hand over. Turn-labeled documents route through the presenter
  /// FIRST, exactly mirroring `FileImportCoordinator.exportText`'s own fallback contract —
  /// its `nil` for `turns == nil`/empty falls through to `textForDelivery`'s existing,
  /// expiry-checked selection, UNCHANGED.
  ///
  /// Reads the LIVE row, never `self.transcript` (found by second-pass review): this view's
  /// value is a snapshot from when the row was selected, while Save's panel and Share's
  /// sheet can stay open across a "Clean it again" landing new turns, or across the row
  /// being deleted. `nil` for a row that no longer exists, so nothing is delivered for a
  /// recording the user was told is gone.
  private var exportText: String? {
    guard let live = transcriptCoordinator.currentRow(id: transcript.id),
      let base = transcriptCoordinator.textForDelivery(live)
    else { return nil }
    if let turns = live.turns,
      let result = TranscriptDocumentPresenter.exportText(
        turns: turns, rawText: live.text, speakerNames: live.speakerNames ?? [:],
        timesOn: timesOn, mode: documentView)
    {
      return result.text
    }
    return base
  }

  /// Copy/Save/Share titles — the SAME general export rule as the wizard (plan §2.1), never
  /// scoped to turn-labeled documents.
  private var exportButtonLabels: (copy: String, save: String, share: String) {
    TranscriptDocumentPresenter.exportButtonLabels(mode: documentView)
  }

  /// `exportText` is read AFTER the modal returns, never before it (found by chunk review):
  /// `NSSavePanel.runModal()` blocks for as long as the user takes, and a row can expire
  /// (the escape-recovery 24-hour promise) or be deleted in that window — writing a value
  /// captured before the panel opened would export text the user was told had gone.
  private func saveDocument() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = kindWord
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let text = exportText else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      saveError = String(describing: error)
    }
  }
}

/// Defers reading the export text to whenever the system actually asks for the data, rather
/// than whenever SwiftUI last evaluated `body` (found by chunk review) — `resolve` closes
/// over `transcriptCoordinator` (a reference) and re-reads `exportText`'s own live,
/// expiry-checked selection at that later point, the same delivery-time validation Save gets
/// from being read after its modal returns.
private struct DeliverableText: Transferable, Sendable {
  let resolve: @Sendable () -> String?

  /// A `nil` resolve must REFUSE delivery, never substitute empty content (found by chunk
  /// review): `Data("".utf8)` reads to the receiving app as a successful, if empty, export —
  /// exactly the silent "expiry reads as success" failure `textForDelivery`'s own contract
  /// exists to prevent.
  struct ExpiredError: Error {}

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { deliverable in
      guard let text = deliverable.resolve() else { throw ExpiredError() }
      return Data(text.utf8)
    }
  }
}
