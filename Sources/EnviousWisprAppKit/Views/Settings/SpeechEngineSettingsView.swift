import EnviousWisprASR
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
  @State private var showSpokenPunctuationHelp: Bool = false
  @State private var showLiveTranscriptionHelp: Bool = false

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
            VStack(alignment: .leading, spacing: 6) {
              whisperKitSetupContent
              // Inline, in the section the user is looking at — never an
              // overlay. Rendered OUTSIDE the state switch: a failed removal
              // can flip the state to error/not-downloaded, and the notice
              // must survive that flip (Codex 2c-r1 P2).
              if let notice = setup.whisperKitSetup.removeNotice {
                Text(
                  notice == .refusedDictationInFlight
                    ? "Finish your current dictation first, then try again."
                    : "The model could not be removed. Please try again."
                )
                .font(.stHelper)
                .foregroundStyle(.stWarning)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }

      // ── Section 3: Language Selection ──
      // #1678: one control, both engines. It was WhisperKit-only, so a German
      // speaker on the default engine could not stop auto-detect guessing —
      // the reported bug (Greek recognised in German speech). The two engines
      // genuinely do different amounts with a lock, and that difference is
      // carried by the help copy below, not by a different control or label.
      // WhisperKit still waits for setup: its language list is only meaningful
      // once its model is ready. Parakeet's lock is a stored preference that
      // applies at decode time, so it needs no readiness gate.
      if languageSectionIsAvailable {
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
                Text(languageSectionCopy)
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
                  // #1678: a lock can outlive the engine that could honour it.
                  // Someone locked to Japanese on the multilingual engine who
                  // switches to the fast one keeps the stored code, and the
                  // decoder silently falls back to auto-detect — a lock they set
                  // and are not getting. We say so rather than substituting a
                  // different language or clearing their choice, because either
                  // would be us deciding something they did not ask for. The
                  // stored code is preserved, so switching back restores it.
                  if !isLockHonouredByActiveEngine(code) {
                    Text(
                      "The fast engine can't lock to this language, so it's detecting "
                        + "automatically. Choose one of its 25 European languages, or switch "
                        + "to the multilingual engine."
                    )
                    .font(.stHelper)
                    .foregroundStyle(.stWarning)
                    .fixedSize(horizontal: false, vertical: true)
                  }
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
                HStack(spacing: 6) {
                  Toggle(isOn: $settings.useStreamingASR) {
                    Text(LiveTranscriptionCopy.toggleLabel).settingsRowLabel()
                  }
                  .toggleStyle(BrandedToggleStyle())
                  liveTranscriptionHelpButton
                }
                Text(LiveTranscriptionCopy.toggleDescription(for: settings.selectedBackend))
                  .settingsReadingCopy()
                if settings.selectedBackend == .whisperKit,
                  isAutoLanguage(settings.languageMode)
                {
                  Text(LiveTranscriptionCopy.autoLanguageFootnote)
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
        BrandedRow(showDivider: true) {
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
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "text.quote")
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 6) {
                Toggle(isOn: $settings.spokenPunctuationEnabled) {
                  Text(SpokenPunctuationCopy.toggleLabel).settingsRowLabel()
                }
                .toggleStyle(BrandedToggleStyle())
                spokenPunctuationHelpButton
              }
              Text(SpokenPunctuationCopy.toggleDescription)
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
      LanguageLockSheet(lockableCodes: lockableLanguageCodes)
    }
  }

  // MARK: - Language section (#1678)

  /// WhisperKit's list is only meaningful once its model is ready. Parakeet's
  /// lock is a stored preference applied at decode time, so it has no such gate.
  private var languageSectionIsAvailable: Bool {
    switch settings.selectedBackend {
    case .whisperKit:
      if case .ready = setup.whisperKitSetup.setupState { return true }
      return false
    case .parakeet:
      return true
    }
  }

  /// Per-engine, because the same control genuinely does different amounts on
  /// each and one sentence would give one of them wrong advice.
  ///
  /// The Parakeet wording is deliberately weaker than "only transcribe German".
  /// The vendor's filter partitions by SCRIPT, not language, so a German lock
  /// suppresses Greek and Cyrillic and does nothing to separate German from
  /// Dutch. Measured: Greek audio under a German lock changes 9 of 9 clips,
  /// while German audio is byte-identical across 120. A control must describe
  /// what it does; copy promising more than the mechanism delivers is the
  /// defect this issue was raised for, not a stylistic preference.
  private var languageSectionCopy: String {
    switch settings.selectedBackend {
    case .whisperKit:
      return
        "Auto-detect your language, or lock to a specific one. WhisperKit supports 99 languages."
    case .parakeet:
      return """
        Auto-detect your language, or lock to one of 25 European languages. \
        Locking helps stop the fast engine reaching for a different alphabet, \
        like Greek or Cyrillic appearing in German. It cannot tell apart two \
        languages written in the same alphabet.
        """
    }
  }

  /// Whether the ACTIVE engine can actually honour a stored locked code.
  ///
  /// False is not an error state to clean up: the stored code stays exactly as
  /// the user set it, so switching engines back restores the lock. What must not
  /// happen is silence — the decoder falls back to auto-detect and nothing on
  /// screen would say so.
  private func isLockHonouredByActiveEngine(_ code: String) -> Bool {
    guard let lockableLanguageCodes else { return true }
    return lockableLanguageCodes.contains(code)
  }

  /// The codes the picker may offer. Restricted on the fast engine to what the
  /// model is declared to transcribe — offering more would be a silent failure,
  /// because an unclaimed code maps to no vendor language and the decoder
  /// quietly falls back to auto-detect while the user believes they are locked.
  private var lockableLanguageCodes: Set<String>? {
    switch settings.selectedBackend {
    case .whisperKit: return nil  // all 99
    case .parakeet: return ParakeetBackend.lockableLanguageCodes
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
        validating ? "Checking speech model files..." : "Preparing download...", nil, false, nil
      )
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
        false, "Try Again"
      )
    }
  }

  private func isAutoLanguage(_ mode: LanguageMode) -> Bool {
    if case .auto = mode { return true }
    return false
  }

  /// #1988: the preview runs on Apple's on-device recognizer, which is macOS 26
  /// API. Below that the toggle is visible but disabled, with the reason stated,
  /// rather than hidden: a user who read about the feature should find out why
  /// they do not have it instead of concluding it was removed.
  /// When the user flips the Auto toggle off, we need a concrete ISO code
  /// to lock to. Preserve the prior locked code if we have one (comes from
  /// the W2 migration of `whisperKitLanguage`), otherwise default to English.
  private func currentOrDefaultLockCode() -> String {
    Self.defaultLockCode(
      currentMode: settings.languageMode,
      migratedCode: settings.whisperKitLanguage,
      lockableCodes: lockableLanguageCodes)
  }

  /// Which code the Auto-detect toggle should lock to when it is switched OFF.
  ///
  /// Pure and `static` so it can be tested: this is the one place a lock is
  /// created without the user choosing from the filtered picker, so it is the
  /// one place the picker's restriction can be bypassed.
  ///
  /// #1678: every candidate must be honourable by the ACTIVE engine. Without
  /// that, turning Auto off on the fast engine could restore a legacy
  /// `whisperKitLanguage` such as Japanese — the user asks for a lock, the UI
  /// shows a lock, and the decoder maps it straight back to auto-detect. That is
  /// the same silent failure the picker restriction exists to prevent, arriving
  /// through the toggle instead of the list (Codex review r1).
  ///
  /// - Parameter lockableCodes: nil means "no restriction" (the multilingual
  ///   engine), which preserves the pre-#1678 behaviour exactly.
  static func defaultLockCode(
    currentMode: LanguageMode,
    migratedCode: String,
    lockableCodes: Set<String>?
  ) -> String {
    func honoured(_ code: String) -> Bool { lockableCodes?.contains(code) ?? true }

    if case .locked(let code) = currentMode, honoured(code) {
      return code
    }
    if LanguageTypes.isSupported(migratedCode), honoured(migratedCode) {
      return migratedCode
    }
    // English is in every engine's set, so this fallback is always honourable.
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
          "WhisperKit requires a ~1.5 GB model download. It runs fully on your Mac, no internet needed after setup."
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

    case .paused:
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStepIndicator("Download Paused")
        Text("Download paused. Resume anytime.")
          .settingsReadingCopy()
        HStack {
          Button("Resume") {
            setup.whisperKitSetup.downloadModel()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          whisperKitRefreshButton
        }
      }

    case .ready:
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          // #1635: delivery `.ready` means the model is on DISK. The engine then loads into
          // memory for a measured p50 of 27.4s on this path, and a press during that window
          // is correctly refused — so a green tick here contradicted the app for roughly
          // half a minute. `warmInFlight` is coordinator intent, published synchronously at
          // warm-start; do NOT swap it for adapter readiness, which is still `.notReady` at
          // that moment and is why the previous attempt's label could never appear.
          if ModelPreparingCopy.isPreparing(warmInFlight: engineCoordinator?.status.warmInFlight) {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text(
                ModelPreparingCopy.label(
                  warmInFlight: engineCoordinator?.status.warmInFlight)
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
            // #1635: on the SUBVIEW that renders the copy, so the event can only fire when
            // the words genuinely entered the visible hierarchy. `reason` is the constant
            // "engine_swap" because `warmInFlight` is set solely by the coordinator-owned
            // post-switch warm; the view has no wider reason to report and must not invent
            // one. Reappearance is another honest impression, so there is no dedup here.
            .onAppear {
              TelemetryService.shared.settingsModelPreparingImpression(
                engine: "whisperKit", reason: "engine_swap")
            }
          } else {
            Label(
              ModelPreparingCopy.label(
                warmInFlight: engineCoordinator?.status.warmInFlight),
              systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.stSuccess)
          }
          Spacer()
          // 2c: the way out. An app that installs 1.5 GB must offer deletion.
          // Removal does NOT switch the selected engine (founder ruling 2.5.5
          // "no engine swap at all"; L7 freezes engine writes; plan arm 9:
          // selectedBackend unchanged, next press gives L6's honest state).
          // Reviewers keep proposing the EG-1-style auto-switch — that is the
          // design the founder killed; do not restore it without a new ruling.
          // While the removal drain runs, the button is REPLACED by progress
          // (founder ruling 2026-07-17: visible, unspammable).
          if setup.whisperKitSetup.isRemoving {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Removing model...")
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
            }
          } else {
            Button("Remove Model") {
              setup.whisperKitSetup.removeModel()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(.stError)
            whisperKitRefreshButton
          }
        }
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

  // MARK: - Live transcription help (#1337)

  /// Same shape as `spokenPunctuationHelpButton` deliberately: a real `Button`, never a
  /// hover-only reveal, so it is reachable by keyboard and VoiceOver. The two panels are
  /// the same affordance and must read as one family.
  private var liveTranscriptionHelpButton: some View {
    Button {
      showLiveTranscriptionHelp = true
    } label: {
      Image(systemName: "questionmark.circle")
        .foregroundStyle(Color.stTextSecondary)
        .font(.stHelper)
    }
    .buttonStyle(.borderless)
    .help(LiveTranscriptionCopy.helpButtonAccessibilityLabel)
    .accessibilityLabel(LiveTranscriptionCopy.helpButtonAccessibilityLabel)
    .popover(isPresented: $showLiveTranscriptionHelp, arrowEdge: .bottom) {
      liveTranscriptionHelpPanel
    }
  }

  /// Ordered speed first, then accuracy, then why, then the recommendation. Speed leads
  /// because speed is why anyone turns this on, so the answer they came for should not be
  /// buried under a caveat.
  ///
  /// Content is per-engine. The two engines stream by different mechanisms and the evidence
  /// points opposite ways, so a single panel would give one of them wrong advice
  /// (diff review, 2026-07-31). The comparison table renders only when that engine actually
  /// has defensible figures.
  private var liveTranscriptionHelpPanel: some View {
    let panel = LiveTranscriptionCopy.panel(for: settings.selectedBackend)
    return VStack(alignment: .leading, spacing: 12) {
      Text(panel.title)
        .font(.stSectionHeader)

      helpSection(panel.speedHeading) {
        Text(panel.speedBody).settingsReadingCopy()
      }

      helpSection(panel.accuracyHeading) {
        VStack(alignment: .leading, spacing: 6) {
          if panel.comparisons.isEmpty == false {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
              GridRow {
                Text("")
                Text("Off")
                Text("On")
              }
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
              ForEach(panel.comparisons) { row in
                GridRow {
                  Text(row.metric)
                  Text(row.off)
                  Text(row.on)
                }
              }
            }
            .font(.stBody)
          }
          Text(panel.accuracyBody).settingsReadingCopy()
        }
      }

      helpSection(panel.whyHeading) {
        Text(panel.whyBody).settingsReadingCopy()
      }

      helpSection(panel.recommendationHeading) {
        Text(panel.recommendationBody).settingsReadingCopy()
      }

      Text(panel.footnote)
        .settingsReadingCopy()
    }
    .frame(maxWidth: 340, alignment: .leading)
    .padding(16)
  }

  /// A labelled block inside the help panel. Extracted so the four sections cannot drift
  /// apart in spacing or heading treatment.
  private func helpSection<Content: View>(
    _ heading: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(heading)
        .font(.stHelper)
        .foregroundStyle(Color.stTextSecondary)
      content()
    }
  }

  // MARK: - Spoken punctuation help (#1794)

  /// A real `Button`, never a hover-only reveal. Hover cannot be reached by keyboard and
  /// does not exist for VoiceOver, and the personas who most need this vocabulary are the
  /// ones least able to reach a hover target. `.help()` gives the mouse-hover tooltip on
  /// top; the button is what makes it reachable at all.
  private var spokenPunctuationHelpButton: some View {
    Button {
      showSpokenPunctuationHelp = true
    } label: {
      Image(systemName: "questionmark.circle")
        .foregroundStyle(Color.stTextSecondary)
        .font(.stHelper)
    }
    .buttonStyle(.borderless)
    .help(SpokenPunctuationCopy.helpButtonAccessibilityLabel)
    .accessibilityLabel(SpokenPunctuationCopy.helpButtonAccessibilityLabel)
    .popover(isPresented: $showSpokenPunctuationHelp, arrowEdge: .bottom) {
      spokenPunctuationHelpPanel
    }
  }

  private var spokenPunctuationHelpPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(SpokenPunctuationCopy.helpTitle)
        .font(.stSectionHeader)
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          Text(SpokenPunctuationCopy.helpSayColumn)
            .foregroundStyle(Color.stTextSecondary)
          Text(SpokenPunctuationCopy.helpGetColumn)
            .foregroundStyle(Color.stTextSecondary)
        }
        .font(.stHelper)
        ForEach(SpokenPunctuationCopy.phrases) { phrase in
          GridRow {
            Text("\"\(phrase.spoken)\"")
            Text(phrase.result)
          }
        }
      }
      .font(.stBody)
      Text(SpokenPunctuationCopy.helpFootnote)
        .settingsReadingCopy()
        .frame(maxWidth: 280, alignment: .leading)
    }
    .padding(16)
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
