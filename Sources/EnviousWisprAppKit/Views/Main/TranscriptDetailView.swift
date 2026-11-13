import CoreTransferable
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// Detail view for a HELD Escape Recovery dictation (#2087): an action bar with its own Paste,
/// Keep and Delete, a titled header with metadata chips, and the polished/original text each in
/// its own card. Every other dictation shows `HistoryDictationCard`, and an imported transcript
/// shows `HistoryTranscriptView` (#3147 PR3), so this view never draws turns.
struct TranscriptDetailView: View {
  let transcript: Transcript
  /// #4101: why a History Paste did not happen; the History page holds the notice, so replacing
  /// this detail (a deletion, another selection) does not lose it.
  let showPasteNotice: @MainActor (String) -> Void
  @Environment(PermissionsService.self) private var permissions
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  @Environment(HistoryPaste.self) private var historyPaste
  @Environment(PreviousApplicationTracker.self) private var previousApplication

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

  /// The row's kind by name. Only a dictation reaches this view.
  private var kindWord: String {
    String(
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
          plainTextSections
        }
        .padding(20)
      }
    }
    .background(Color.stPageBg)
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

  // MARK: - Paste

  /// #3875: History's Paste goes through the same clipboard transaction as Paste Last
  /// Dictation, so "Restore clipboard after paste" and "Keep dictations out of clipboard
  /// history" hold here too. It used to write the board as a kept copy and post Cmd+V,
  /// which left the dictation on the clipboard in place of whatever the user had there.
  ///
  /// #4101: into the app the user came from, read at the press.
  private func pasteFromHistory() {
    historyPaste.paste(
      destination: previousApplication.lastOtherApplication,
      allowed: { pasteAllowed },
      text: { transcriptCoordinator.textForDelivery(transcript) },
      showHistory: { showHistory() },
      showNotice: { showPasteNotice($0) },
      // #2087: the OTHER door back to a held recovery. The pill reports its restores; without
      // this one the funnel counted only the users who caught a three-second offer. No-op for
      // an ordinary row. Reported only once Cmd+V was posted: an attempt, never an arrival.
      dispatched: { transcriptCoordinator.reportRestoredFromHistory(transcript) })
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
        String(
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

  // MARK: - Text

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

  private var kindIcon: String { "mic" }

  /// What Copy/Save/Share hand over: `textForDelivery`'s expiry-checked selection.
  ///
  /// Reads the LIVE row, never `self.transcript` (found by second-pass review): this view's
  /// value is a snapshot from when the row was selected, while Save's panel and Share's
  /// sheet can stay open across a "Clean it again" landing new turns, or across the row
  /// being deleted. `nil` for a row that no longer exists, so nothing is delivered for a
  /// recording the user was told is gone.
  private var exportText: String? {
    HistoryTranscriptExport.text(
      rowID: transcript.id, coordinator: transcriptCoordinator, mode: .cleaned, timesOn: true)
  }

  private var defaultFileName: String { kindWord }

  /// Copy/Save/Share titles, the same general export rule as the wizard (plan §2.1).
  private var exportButtonLabels: (copy: String, save: String, share: String) {
    TranscriptDocumentPresenter.exportButtonLabels(mode: .cleaned)
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
