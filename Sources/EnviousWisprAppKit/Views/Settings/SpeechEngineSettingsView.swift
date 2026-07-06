import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprServices
import SwiftUI

/// Transcription engine, multi-language options, cleanup, and model-memory settings.
struct SpeechEngineSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(LanguageSuggestionPresenter.self) private var languageSuggestionPresenter
  /// #1171 — optional so the view never crashes if rendered outside the main
  /// window's environment. Drives the subtle "applies after the current
  /// dictation" hint (silent in the main UX).
  @Environment(EngineCoordinator.self) private var engineCoordinator: EngineCoordinator?
  // #1348 Phase 2: delivery state mirror for the Parakeet download row.
  // Optional — nil in previews/tests that don't inject the home.
  @Environment(ModelDeliveryHome.self) private var modelDelivery: ModelDeliveryHome?

  @State private var showLanguageLockSheet: Bool = false

  /// #1171 — shown ONLY when the user's selected engine differs from the active
  /// one because a switch is deferred while a dictation/recovery is in flight.
  /// Not-installed is covered by the download UI below; transient mid-load shows
  /// nothing.
  private var engineSwitchDeferredNotice: String? {
    guard let status = engineCoordinator?.status, status.isDiverged,
      let reason = status.blockedReason
    else { return nil }
    switch reason {
    case .pipelineActive, .recovery: return "Applies after the current dictation finishes."
    case .notInstalled, .loading: return nil
    }
  }

  /// The two-engine selector: a pair of square selectable cards. Fast (Parakeet)
  /// leads on speed; All Languages (WhisperKit) leads on breadth. Adaptive grid
  /// so the pair reflows to a single column as the content card narrows.
  private var engineCards: some View {
    // Two equal flexible columns so the pair always spans the full content
    // width (an adaptive grid left-packs them and strands empty space on the
    // right). Each card carries a "pick this when" tagline plus a four-row spec
    // table. Every value is grounded: Parakeet's 25-language support is
    // confirmed by the NVIDIA model card AND a live in-app test (French/Spanish/
    // German, 2026-07-03); transcribe times come from our own benchmark data
    // (asr-landscape-2026.md). The "Runs on" values are read from the actual
    // compute-unit config: Parakeet loads `.cpuAndNeuralEngine` (FluidAudio
    // AsrModels.defaultConfiguration), WhisperKit is pinned `.cpuAndGPU` and
    // explicitly avoids the Neural Engine (WhisperKitBackend dictationCompute-
    // Options, #879). Both run entirely on-device.
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
      spacing: 12
    ) {
      EngineCard(
        icon: "bolt.fill",
        title: "Fast",
        tagline: "Pick this for everyday English and European dictation.",
        specs: [
          ("Model", "Parakeet v3"),
          ("Languages", "25 European languages"),
          ("Runs on", "Apple Neural Engine"),
          ("Transcribe time", "Usually ~0.1s after you speak"),
        ],
        isSelected: settings.selectedBackend == .parakeet
      ) {
        settings.selectedBackend = .parakeet
      }
      EngineCard(
        icon: "globe",
        title: "All Languages",
        tagline: "Pick this for other languages or the toughest audio.",
        specs: [
          ("Model", "Whisper Large v3 Turbo"),
          ("Languages", "99 languages"),
          ("Runs on", "Apple GPU"),
          ("Transcribe time", "Usually 1-2s after you speak"),
        ],
        isSelected: settings.selectedBackend == .whisperKit
      ) {
        settings.selectedBackend = .whisperKit
      }
    }
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // One page-level notice instead of the footnote repeated under every
      // section: these settings freeze at recording start, stated once (#2).
      FrozenPerRecordingBanner()

      // ── Transcription Engine (card selector) ─────────────────────────
      // A primary choice with meaningful trade-offs, so it reads as two
      // selectable cards rather than a segmented pill (#3). Copy advertises
      // Parakeet's 25 European languages, not just English (founder, 2026-07-03).
      VStack(alignment: .leading, spacing: 10) {
        Text("Transcription Engine".uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
          .padding(.leading, 4)

        engineCards

        if let notice = engineSwitchDeferredNotice {
          Text(notice)
            .font(.stHelper)
            .foregroundStyle(.stWarning)
            .padding(.leading, 4)
        }
      }

      // ── Section 2: WhisperKit Model Setup (conditional) ───────────────
      if settings.selectedBackend == .whisperKit {
        BrandedSection(header: "Model Setup") {
          BrandedRow(showDivider: false) {
            whisperKitSetupContent
          }
        }
      }

      // ── Section 3: Language Selection (only when model is ready) ──
      if settings.selectedBackend == .whisperKit,
        case .ready = setup.whisperKitSetup.setupState
      {
        BrandedSection(header: "Language") {
          BrandedRow {
            HStack(alignment: .top, spacing: 11) {
              SettingsRowIcon(systemName: "globe")
              VStack(alignment: .leading, spacing: 4) {
                Toggle(
                  isOn: Binding(
                    get: { isAutoLanguage(settings.languageMode) },
                    set: { newValue in
                      settings.languageMode =
                        newValue
                        ? .auto
                        : .locked(currentOrDefaultLockCode())
                    }
                  )
                ) {
                  Text("Auto-detect language").settingsRowLabel()
                }
                .toggleStyle(BrandedToggleStyle())
                Text(
                  "Auto-detect your language, or lock to a specific one. WhisperKit supports 99 languages."
                )
                .settingsReadingCopy()
              }
            }
          }

          if case .locked(let code) = settings.languageMode {
            BrandedRow(showDivider: false) {
              HStack(spacing: 11) {
                SettingsRowIcon(systemName: "character.bubble")
                let entry = LanguageCatalog.entry(for: code)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Language")
                    .font(.stHelper)
                    .foregroundStyle(.stTextSecondary)
                  Text("\(entry.nativeName) (\(entry.englishName))")
                    .settingsRowLabel()
                }
                Spacer()
                Button("Change") {
                  showLanguageLockSheet = true
                }
                .controlSize(.small)
              }
            }
          }
          // PR4 of #763 (#252): Reset language suggestions. Clears the
          // three-strike state machine (dismissal counts, suppression set,
          // last-shown lang) so the chip can surface fresh for previously
          // dismissed/suppressed languages.
          BrandedRow(showDivider: false) {
            HStack(alignment: .top, spacing: 11) {
              SettingsRowIcon(systemName: "lightbulb")
              VStack(alignment: .leading, spacing: 2) {
                Text("Language suggestions")
                  .settingsRowLabel()
                Text(
                  "Reset to allow the app to suggest locking a detected language again."
                )
                .settingsReadingCopy()
              }
              Spacer()
              Button("Reset") {
                languageSuggestionPresenter.resetAllChipState()
              }
              .controlSize(.small)
            }
          }
        }
      }

      // ── Section 3: Auto-Stop ─────────────────────────────────────────
      BrandedSection(header: "Auto-Stop") {
        BrandedRow {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $settings.vadAutoStop) {
              HStack(spacing: 11) {
                SettingsRowIcon(systemName: "stopwatch")
                Text("Stop recording on silence").settingsRowLabel()
              }
            }
            .toggleStyle(BrandedToggleStyle())
          }
        }
        if settings.vadAutoStop {
          BrandedRow {
            VStack(alignment: .leading, spacing: 4) {
              BrandedSlider(
                "Pause duration", value: $settings.vadSilenceTimeout, in: 0.5...3.0,
                step: 0.25, low: "0.5s", high: "3.0s", format: "%.1fs")
              Text("How long to wait after you stop speaking before ending the recording.")
                .settingsReadingCopy()
            }
          }
        }
      }

      // ── Delivery row (#1348 Phase 2, D6 states 2/3/4/5/7/8/10/11): shows
      // ONLY while the Parakeet model download/repair is in a user-relevant
      // state — invisible when admitted (D6: visible iff the user must act
      // or wait). Same state stream onboarding renders; second renderer.
      if settings.selectedBackend == .parakeet, let modelDelivery,
        let row = parakeetDeliveryRow(modelDelivery.parakeetState)
      {
        BrandedSection(header: "Speech Model") {
          BrandedRow(showDivider: false) {
            HStack(alignment: .top, spacing: 11) {
              SettingsRowIcon(systemName: "arrow.down.circle")
              VStack(alignment: .leading, spacing: 4) {
                Text(row.title).settingsRowLabel()
                if let detail = row.detail {
                  Text(detail).settingsReadingCopy()
                }
              }
              Spacer()
              if row.showsCancel {
                Button("Cancel") { modelDelivery.cancelParakeetDownload() }
                  .buttonStyle(.bordered)
              }
              if let action = row.actionLabel {
                Button(action) { modelDelivery.resumeParakeetDownload() }
                  .buttonStyle(.borderedProminent)
              }
            }
          }
        }
      }

      // ── Section 4: Transcription Mode ────────────────────────────────
      // #1276 Step 2 (PR-2): the "Live transcription" toggle now shows for both
      // engines (it binds the same `useStreamingASR`). On WhisperKit with
      // Auto-detect language, live transcription safely uses clean batch instead
      // (the footnote explains why); a picked language streams.
      if settings.selectedBackend == .parakeet || settings.selectedBackend == .whisperKit {
        BrandedSection(header: "Transcription Mode") {
          BrandedRow(showDivider: false) {
            HStack(alignment: .top, spacing: 11) {
              SettingsRowIcon(systemName: "waveform")
              VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.useStreamingASR) {
                  Text("Live transcription").settingsRowLabel()
                }
                .toggleStyle(BrandedToggleStyle())
                Text(
                  "Transcribes while you speak for faster results. Turn off for cleaner text on longer recordings."
                )
                .settingsReadingCopy()
                if settings.selectedBackend == .whisperKit,
                  isAutoLanguage(settings.languageMode)
                {
                  Text(
                    "Live transcription needs a selected language. With Auto-detect, EnviousWispr uses clean batch transcription for accuracy."
                  )
                  .settingsReadingCopy()
                }
              }
            }
          }
        }
      }

      // ── Section 5: Cleanup ────────────────────────────────────────────
      BrandedSection(header: "Cleanup") {
        BrandedRow(showDivider: true) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "sparkles")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.fillerRemovalEnabled) {
                Text("Remove filler words (um, uh, hmm...)").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text("Strips common filler words from transcriptions.")
                .settingsReadingCopy()
            }
          }
        }
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "face.smiling")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.emojiFormatterEnabled) {
                Text("Convert spoken emoji (e.g. \"thumbs up emoji\" → 👍)").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text("Say \"<phrase> emoji\" to get the glyph. Bare words never convert.")
                .settingsReadingCopy()
            }
          }
        }
      }

      // ── Section 6: Memory ─────────────────────────────────────────────
      BrandedSection(header: "Memory") {
        BrandedRow {
          HStack(spacing: 11) {
            SettingsRowIcon(systemName: "memorychip")
            Picker("Unload model after", selection: $settings.modelUnloadPolicy) {
              ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
                Text(policy.displayName).tag(policy)
              }
            }
          }
        }
        if settings.modelUnloadPolicy != .never {
          BrandedRow {
            Text(
              "The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s)."
            )
            .settingsReadingCopy()
          }
        }
        if settings.modelUnloadPolicy == .immediately {
          BrandedRow(showDivider: false) {
            Text(
              "Model is freed after every transcription. Expect a reload delay on each recording."
            )
            .font(.stHelper)
            .foregroundStyle(.stWarning)
          }
        }
      }
    }
    .onAppear {
      if settings.selectedBackend == .whisperKit {
        Task { await setup.whisperKitSetup.detectState() }
      }
    }
    .onChange(of: settings.selectedBackend) { _, newBackend in
      if newBackend == .whisperKit {
        Task { await setup.whisperKitSetup.detectState() }
      }
    }
    .sheet(isPresented: $showLanguageLockSheet) {
      LanguageLockSheet()
    }
  }

  // MARK: - Language mode helpers

  /// True when the current mode is `.auto`. Defined as a free helper so the
  /// Toggle binding stays trivially readable.
  /// D6 row model for the delivery state; nil = render nothing (notReady /
  /// admitted are silent in settings).
  private func parakeetDeliveryRow(_ state: DeliveryState) -> (
    title: String, detail: String?, showsCancel: Bool, actionLabel: String?
  )? {
    switch state {
    case .notReady, .admitted:
      return nil
    case .preparing(let validating):
      return (
        validating ? "Checking speech model files..." : "Preparing download...", nil, false, nil)
    case .downloading(_, let bytesWritten, let totalBytes):
      let mb = Int(Double(bytesWritten) / 1_048_576)
      let totalMB = Int(Double(totalBytes) / 1_048_576)
      return ("Downloading speech model...", "\(mb) MB of \(totalMB) MB", true, nil)
    case .verifying:
      return ("Verifying download...", nil, false, nil)
    case .cancelled:
      return ("Download paused. Resume anytime.", nil, false, "Resume")
    case .failed(let failure):
      return (
        "Speech model download failed.",
        ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail),
        false, "Try Again")
    }
  }


  private func isAutoLanguage(_ mode: LanguageMode) -> Bool {
    if case .auto = mode { return true }
    return false
  }

  /// When the user flips the Auto toggle off, we need a concrete ISO code
  /// to lock to. Preserve the prior locked code if we have one (comes from
  /// the W2 migration of `whisperKitLanguage`), otherwise default to English.
  private func currentOrDefaultLockCode() -> String {
    if case .locked(let code) = settings.languageMode {
      return code
    }
    let migrated = settings.whisperKitLanguage
    if LanguageTypes.isSupported(migrated) {
      return migrated
    }
    return "en"
  }

  // MARK: - WhisperKit Setup UI

  @ViewBuilder
  private var whisperKitSetupContent: some View {
    switch setup.whisperKitSetup.setupState {
    case .checking:
      HStack {
        ProgressView()
          .controlSize(.small)
        Text("Checking model status...")
          .foregroundStyle(.stTextSecondary)
      }

    case .notDownloaded:
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStepIndicator("Download Model")

        Text(
          "WhisperKit requires a ~1.5 GB model download. It runs fully on your Mac — no internet needed after setup."
        )
        .settingsReadingCopy()

        HStack {
          Button("Download WhisperKit Model") {
            setup.whisperKitSetup.downloadModel()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)

          whisperKitRefreshButton
        }
      }

    case .downloading(let progress, let status):
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStepIndicator("Downloading...")

        ProgressView(value: progress)
          .progressViewStyle(.linear)

        HStack {
          Text(status)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .lineLimit(1)
          Spacer()
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.stHelper)
              .monospacedDigit()
              .foregroundStyle(.stTextSecondary)
          }
          Button("Cancel") {
            setup.whisperKitSetup.cancelDownload()
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          .foregroundStyle(.stError)
        }
      }

    case .ready:
      HStack {
        Label("Model Ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.stSuccess)
        Spacer()
        whisperKitRefreshButton
      }

    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.stWarning)

        Text(message)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)

        Button("Try Again") {
          Task { await setup.whisperKitSetup.detectState() }
        }
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func whisperKitStepIndicator(_ title: String) -> some View {
    Label(title, systemImage: "1.circle.fill")
      .foregroundStyle(Color.stAccent)
      .font(.stRowLabel)
  }

  @ViewBuilder
  private var whisperKitRefreshButton: some View {
    Button {
      Task { await setup.whisperKitSetup.forceDetectState() }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.borderless)
    .help("Re-check model status")
    .accessibilityLabel("Re-check model status")
  }
}

// MARK: - Engine selector card

/// One selectable transcription-engine option: a lavender icon tile, a title,
/// and a short description, laid out as a square card. The selected card carries
/// the accent border and a filled accent check badge. Mirrors `AppearanceCard`
/// so the two card selectors read as one family.
private struct EngineCard: View {
  let icon: String
  let title: String
  let tagline: String
  /// Ordered (label, value) rows rendered as the card's little spec table.
  let specs: [(label: String, value: String)]
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.stAccent)
            .frame(width: 20, alignment: .center)
          Text(title)
            .font(.stRowTitle)
            .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
          Spacer(minLength: 8)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Color.white, Color.stAccentSolid)
          } else {
            Circle()
              .strokeBorder(Color.stDivider, lineWidth: 1.5)
              .frame(width: 20, height: 20)
          }
        }

        Text(tagline)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)

        // The little spec table: label on the left, value right-aligned, thin
        // rules between rows. Both cards share the same row order so the two
        // read as a side-by-side comparison.
        VStack(spacing: 0) {
          ForEach(Array(specs.enumerated()), id: \.offset) { index, row in
            if index != 0 {
              Divider().overlay(Color.stDivider)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(row.label)
                .font(.stHelper)
                .foregroundStyle(.stTextTertiary)
              Spacer(minLength: 12)
              Text(row.value)
                .font(.stHelper)
                .fontWeight(.medium)
                .foregroundStyle(.stTextBody)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
