import EnviousWisprCore
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

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── Section 1: Transcription Engine ──────────────────────────────
      BrandedSection(header: "Transcription Engine") {
        BrandedRow {
          BrandedSegmentedPicker(
            options: [
              ("Fast (English)", ASRBackendType.parakeet),
              ("Multi-Language", ASRBackendType.whisperKit),
            ],
            selection: $settings.selectedBackend
          )
        }
        BrandedRow(showDivider: engineSwitchDeferredNotice != nil) {
          Text(
            settings.selectedBackend == .parakeet
              ? "Powered by Parakeet — fast English transcription with built-in punctuation."
              : "Powered by WhisperKit — broader language support with optimized quality defaults."
          )
          .settingsReadingCopy()
        }
        if let notice = engineSwitchDeferredNotice {
          BrandedRow(showDivider: false) {
            Text(notice)
              .font(.stHelper)
              .foregroundStyle(.stWarning)
          }
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
            VStack(alignment: .leading, spacing: 4) {
              Toggle(
                "Auto-detect language",
                isOn: Binding(
                  get: { isAutoLanguage(settings.languageMode) },
                  set: { newValue in
                    settings.languageMode =
                      newValue
                      ? .auto
                      : .locked(currentOrDefaultLockCode())
                  }
                )
              )
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Auto-detect your language, or lock to a specific one. WhisperKit supports 99 languages."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
            }
          }

          if case .locked(let code) = settings.languageMode {
            BrandedRow(showDivider: false) {
              HStack(spacing: 10) {
                let entry = LanguageCatalog.entry(for: code)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Language")
                    .font(.system(size: 12))
                    .foregroundStyle(.stTextTertiary)
                  Text("\(entry.nativeName) (\(entry.englishName))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
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
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Language suggestions")
                  .font(.system(size: 12))
                  .foregroundStyle(.stTextTertiary)
                Text(
                  "Reset to allow the app to suggest locking a detected language again."
                )
                .font(.stHelper)
                .foregroundStyle(.stTextTertiary)
              }
              Spacer()
              Button("Reset") {
                languageSuggestionPresenter.resetAllChipState()
              }
              .controlSize(.small)
            }
          }
        } footer: {
          FrozenPerRecordingFootnote()
        }
      }

      // ── Section 3: Auto-Stop ─────────────────────────────────────────
      BrandedSection(header: "Auto-Stop") {
        BrandedRow {
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Stop recording on silence", isOn: $settings.vadAutoStop)
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
                .font(.stHelper)
                .foregroundStyle(.stTextTertiary)
            }
          }
        }
      } footer: {
        FrozenPerRecordingFootnote()
      }

      // ── Section 4: Transcription Mode ────────────────────────────────
      if settings.selectedBackend == .parakeet {
        BrandedSection(header: "Transcription Mode") {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 4) {
              Toggle("Live transcription", isOn: $settings.useStreamingASR)
                .toggleStyle(BrandedToggleStyle())
              Text(
                "Transcribes while you speak for faster results. Turn off for cleaner text on longer recordings."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
            }
          }
        } footer: {
          FrozenPerRecordingFootnote()
        }
      }

      // ── Section 5: Cleanup ────────────────────────────────────────────
      BrandedSection(header: "Cleanup") {
        BrandedRow(showDivider: true) {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(
              "Remove filler words (um, uh, hmm...)", isOn: $settings.fillerRemovalEnabled
            )
            .toggleStyle(BrandedToggleStyle())
            Text("Strips common filler words from transcriptions.")
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
          }
        }
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(
              "Convert spoken emoji (e.g. \"thumbs up emoji\" → 👍)",
              isOn: $settings.emojiFormatterEnabled
            )
            .toggleStyle(BrandedToggleStyle())
            Text("Say \"<phrase> emoji\" to get the glyph. Bare words never convert.")
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
          }
        }
      }

      // ── Section 6: Memory ─────────────────────────────────────────────
      BrandedSection(header: "Memory") {
        BrandedRow {
          Picker("Unload model after", selection: $settings.modelUnloadPolicy) {
            ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
              Text(policy.displayName).tag(policy)
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
      } footer: {
        FrozenPerRecordingFootnote()
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
          .foregroundStyle(.stTextTertiary)
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
            .font(.caption2)
            .foregroundStyle(.stTextTertiary)
            .lineLimit(1)
          Spacer()
          if progress > 0 {
            Text("\(Int(progress * 100))%")
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.stTextTertiary)
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
          .foregroundStyle(.stTextTertiary)
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
      .font(.caption.bold())
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
