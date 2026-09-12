import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

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
        .padding(20)
      }
    }
    .background(Color.stPageBg)
  }

  // MARK: - Action bar

  private var actionBar: some View {
    HStack(spacing: 8) {
      Button {
        // #2087: asked for by id rather than taken from the rendered row. A held
        // recovery can lapse between this row appearing and the press, and
        // copying the snapshot would hand back text the user was told had gone.
        // Returns the text unchanged for an ordinary dictation.
        guard let text = transcriptCoordinator.textForDelivery(transcript) else { return }
        PasteService.copyToClipboard(text)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .help("Copy to clipboard")

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
}
