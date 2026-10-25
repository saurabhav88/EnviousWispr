import CoreTransferable
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// Detail view for a single transcript: an action bar, a titled header with
/// metadata chips, and the polished/original text each in its own card (mockup
/// #27 aesthetic). Read-only display of existing data — no new features.
struct TranscriptDetailView: View {
  let transcript: Transcript
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(SettingsManager.self) private var settings
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator

  /// Screen-local, per-row UI state (#2811, phase 4 of #2807) — History has no persisted view
  /// mode today, and this phase does not add one (plan §2.2 non-goal). Reset on row change
  /// via `.onChange(of: transcript.id)`: without it, a stale Marked-up selection from one
  /// file would leak onto the next file's detail view, since SwiftUI otherwise preserves
  /// `@State` across a mere value change at the same tree position (§5 E2E audit).
  @State private var documentView: FileImportCoordinator.DocumentView = .cleaned
  @State private var timesOn = true
  /// Surfaced via `.alert` rather than swallowed by `try?` (found by chunk review) — a failed
  /// disk write must not look identical to a successful one.
  @State private var saveError: String?
  /// #3875: why a History Paste did not happen, shown once History is back in front.
  @State private var pasteNotice: String?

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
  ///
  /// #3972 R45: a meeting never reaches this view; History shows it in
  /// `MeetingHistoryDetailView`.
  private var kindWord: String {
    transcript.isImported
      ? String(
        localized: "Transcript",
        comment:
          "History detail title for a row made with Transcribe a File. Also the default file name when saving it."
      )
      : String(
        localized: "Dictation",
        comment:
          "History detail title for a row made by dictating. Also the default file name when saving it."
      )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      actionBar
      Divider().overlay(Color.stDivider)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header

          if let turns = displayTurns, !turns.isEmpty {
            transcriptSection(kindWord, icon: "doc.text") {
              // #4001 H10: compared on its inputs, so a detail redraw that leaves the
              // document unchanged does not render every turn again.
              TranscriptTurnsDocument(
                inputs: TranscriptTurnsDocument.Inputs(
                  rowID: transcript.id, text: transcript.text, turns: turns,
                  speakerNames: transcript.speakerNames ?? [:], language: transcript.language,
                  isMeeting: transcript.isMeeting, mode: documentView, timesOn: timesOn,
                  documentFinished: documentFinished)
              )
              .equatable()
            }
            // Reset the whole turn-rendering subtree, including rename-popover state and
            // the Marked up diffs, per document. Turn IDs are document-local: different
            // documents can have identical turn IDs, so row keys alone cannot isolate their
            // state. `HistoryContentView` reuses this view across row selections at a fixed
            // tree position (found by chunk review).
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
    .alert(
      pasteNotice ?? "",
      isPresented: Binding(
        get: { pasteNotice != nil }, set: { if !$0 { pasteNotice = nil } })
    ) {
      Button("OK") { pasteNotice = nil }
    }
  }

  // MARK: - Paste

  /// #3875: History's Paste goes through the same clipboard transaction as Paste Last
  /// Dictation, so "Restore clipboard after paste" and "Keep dictations out of clipboard
  /// history" hold here too. It used to write the board as a kept copy and post Cmd+V,
  /// which left the dictation on the clipboard in place of whatever the user had there.
  private func pasteFromHistory() {
    HistoryPaste.paste(
      allowed: { pasteAllowed },
      text: { transcriptCoordinator.textForDelivery(transcript) },
      settings: settings, permissions: permissions,
      showHistory: { showHistory() },
      showNotice: { showPasteNotice($0) },
      // #2087: the OTHER door back to a held recovery. The pill reports its restores; without
      // this one the funnel counted only the users who caught a three-second offer. No-op for
      // an ordinary row. Reported only once Cmd+V was posted: an attempt, never an arrival.
      dispatched: { transcriptCoordinator.reportRestoredFromHistory(transcript) })
  }

  private func showPasteNotice(_ notice: String) {
    showHistory()
    pasteNotice = notice
  }

  private func showHistory() {
    navigationCoordinator.request(.history)
    appWindowCoordinator.showWindow()
  }

  // MARK: - Action bar

  private var actionBar: some View {
    // #4001 H10: Save and Share are enabled from the displayed row without building the
    // export; pressing them still reads `exportText` from the live row.
    let availability = TranscriptDocumentPresenter.exportAvailability(
      turns: transcript.turns, fallback: transcriptCoordinator.textForDelivery(transcript))
    return HStack(spacing: 8) {
      Button {
        // #2087: `exportText` reads `textForDelivery` fresh by id rather than taking the
        // rendered row's own snapshot. A held recovery can lapse between this row appearing
        // and the press, and copying a snapshot would hand back text the user was told had
        // gone. Returns the text unchanged for an ordinary dictation.
        guard let text = exportText else { return }
        PasteService.copyToClipboard(text, kind: .kept)
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
      .disabled(availability == .none)
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
      .disabled(availability != .content)

      Button {
        if permissions.accessibilityGranted {
          pasteFromHistory()
        } else {
          navigationCoordinator.request(.appSettings(.permissions))
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
          Task { await transcriptCoordinator.keep(transcript) }
        } label: {
          Label(EscapeRecoveryRowPresentation.keepLabel, systemImage: "tray.and.arrow.down")
        }
        .disabled(!keepAllowed)
        .help("Keep this recording permanently instead of letting it be deleted")
      }

      Spacer()

      Button(role: .destructive) {
        Task { await transcriptCoordinator.delete(transcript) }
      } label: {
        Image(systemName: "trash")
          // The only irreversible control in the bar and the quietest thing in
          // it: borderless, secondary grey, no border. Hover in the error tone
          // so what it does is legible before it is pressed rather than after.
          .settingsHoverQuiet(tint: .stError)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.stTextSecondary)
      .accessibilityLabel(
        transcript.isImported
          ? String(
            localized: "Delete transcript",
            comment: "VoiceOver label of the History delete button for a transcript.")
          : String(
            localized: "Delete dictation",
            comment: "VoiceOver label of the History delete button for a dictation."))
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
      Image(systemName: kindIcon)
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
            metaChip(
              String(
                localized: "AI Polished",
                comment: "History detail chip: AI polish rewrote this text."), icon: nil,
              accent: true)
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
        transcript.polishedText == nil
          ? String(
            localized: "Processed", comment: "History detail section title: the cleaned-up text.")
          : String(
            localized: "Polished", comment: "History detail section title: the AI-polished text."),
        icon: transcript.polishedText == nil ? "doc.text" : "sparkles"
      ) {
        Text(output)
          .font(.system(size: 16))
          .lineSpacing(3)
          .foregroundStyle(.stTextPrimary)
          .textSelection(.enabled)
      }
      transcriptSection(
        String(
          localized: "Original",
          comment: "History detail section title: the words as first transcribed."),
        icon: "doc.text"
      ) {
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
    guard let turns = displayTurns else { return false }
    return !turns.isEmpty
  }

  private var kindIcon: String {
    transcript.isImported ? "doc.text" : "mic"
  }

  private var displayTurns: [Turn]? { transcript.turns }

  /// Finished unless the file import is still cleaning THIS row (#2851 §3 D, cloud review of
  /// PR #2871): a turn the cleanup has not reached yet is not "unpolished". Read in this
  /// view's body (#4001 H10), so a finishing import redraws the turn document.
  private var documentFinished: Bool {
    !(transcriptCoordinator.isImportInProgress?(transcript.id) ?? false)
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
    guard let live = transcriptCoordinator.currentRow(id: transcript.id) else { return nil }
    guard let base = transcriptCoordinator.textForDelivery(live) else { return nil }
    if let turns = live.turns,
      let result = TranscriptDocumentPresenter.exportText(
        turns: turns, rawText: live.text, speakerNames: live.speakerNames ?? [:],
        timesOn: timesOn, mode: documentView)
    {
      return result.text
    }
    return base
  }

  private var defaultFileName: String { kindWord }

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
    panel.nameFieldStringValue = defaultFileName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let text = exportText else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      // #3908: Foundation's localized sentence, never the NSError debug dump.
      saveError = error.localizedDescription
    }
  }
}

/// Defers reading the export text to whenever the system actually asks for the data, rather
/// than whenever SwiftUI last evaluated `body` (found by chunk review) — `resolve` closes
/// over `transcriptCoordinator` (a reference) and re-reads `exportText`'s own live,
/// expiry-checked selection at that later point, the same delivery-time validation Save gets
/// from being read after its modal returns.
// Module-internal so regression tests can cross the real CoreTransferable boundary.
struct DeliverableText: Transferable, Sendable {
  // #3566: the system requests data away from the UI executor. The resolver reads
  // MainActor-owned History state, so its type must preserve that isolation.
  let resolve: @MainActor @Sendable () -> String?

  /// A `nil` resolve must REFUSE delivery, never substitute empty content (found by chunk
  /// review): `Data("".utf8)` reads to the receiving app as a successful, if empty, export —
  /// exactly the silent "expiry reads as success" failure `textForDelivery`'s own contract
  /// exists to prevent.
  struct ExpiredError: Error {}

  @MainActor
  func exportData() throws -> Data {
    guard let text = resolve() else { throw ExpiredError() }
    return Data(text.utf8)
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { deliverable in
      try await deliverable.exportData()
    }
  }
}
