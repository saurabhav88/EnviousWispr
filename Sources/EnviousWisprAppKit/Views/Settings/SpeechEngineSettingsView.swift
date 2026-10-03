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
  /// #3385: whether the two engine cards are open under the summary.
  @State private var showEngineChoices: Bool = false

  init(choicesExpanded: Bool = false) {
    _showEngineChoices = State(initialValue: choicesExpanded)
  }
  /// A fresh read-only admission result, invalidated while re-checking.
  @State private var fastAdmission: Bool? = nil
  @State private var fastAdmissionRequest: UInt64 = 0
  #if DEBUG
  @Environment(\.fastAdmissionTestHooks) private var fastAdmissionTestHooks
  #endif

  /// #1171 — shown ONLY when the user's selected engine differs from the active
  /// one because a switch is deferred while a dictation/recovery is in flight.
  /// Not-installed is covered by the download UI below; transient mid-load shows
  /// nothing.
  private var engineSwitchDeferredNotice: String? {
    guard let status = engineCoordinator?.status, status.isDiverged,
      let reason = status.blockedReason
    else { return nil }
    switch reason {
    case .pipelineActive, .recovery:
      return String(
        localized: "Applies after the current dictation finishes.",
        comment:
          "Speech engine settings: an engine change waits until the dictation in progress ends.")
    case .notInstalled, .loading: return nil
    }
  }

  /// The two-engine selector: a pair of square selectable cards. Fast (Parakeet)
  /// leads on speed; All Languages (WhisperKit) leads on breadth. Adaptive grid
  /// so the pair reflows to a single column as the content card narrows.
  private var engineCards: some View {
    // ── Transcription Engine (card selector) ─────────────────────────
    // A primary choice with meaningful trade-offs, so it reads as two
    // selectable cards rather than a segmented pill (#3). Copy advertises
    // Parakeet's 25 European languages, not just English (founder, 2026-07-03).
    // (#3385: the cards now open under the summary's Change button.)
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
        title: String(
          localized: "Fast", comment: "Speech engine settings, engine card: the fast engine's name."
        ),
        tagline: String(
          localized: "Pick this for everyday English and European dictation.",
          comment: "Speech engine settings, engine card: when to pick the fast engine."),
        specs: [
          (
            String(
              localized: "Model",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            "Parakeet v3"
          ),
          (
            String(
              localized: "Languages",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "25 European languages",
              comment: "Speech engine settings, engine card: how many languages it covers.")
          ),
          (
            String(
              localized: "Runs on",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "Apple Neural Engine",
              comment:
                "Speech engine settings, engine card: the chip it runs on. Use Apple's own name for the Neural Engine in your language."
            )
          ),
          (
            String(
              localized: "Transcribe time",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "Usually ~0.1s after you speak",
              comment:
                "Speech engine settings, engine card: how quickly text appears. 0.1s is a tenth of a second."
            )
          ),
        ],
        isSelected: settings.selectedBackend == .parakeet
      ) {
        settings.selectedBackend = .parakeet
        // #3385: picking, including the engine already chosen, closes the choices.
        showEngineChoices = false
      }
      EngineCard(
        icon: "globe",
        title: String(
          localized: "All Languages",
          comment: "Speech engine settings, engine card: the multilingual engine's name."),
        tagline: String(
          localized: "Pick this for other languages or the toughest audio.",
          comment: "Speech engine settings, engine card: when to pick the multilingual engine."),
        specs: [
          (
            String(
              localized: "Model",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            "Whisper Large v3 Turbo"
          ),
          (
            String(
              localized: "Languages",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "99+ languages",
              comment: "Speech engine settings, engine card: how many languages it covers.")
          ),
          (
            String(
              localized: "Runs on",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "Apple GPU",
              comment:
                "Speech engine settings, engine card: the chip it runs on, the graphics processor.")
          ),
          (
            String(
              localized: "Transcribe time",
              comment: "Speech engine settings, engine card: a row label in the card's spec table."),
            String(
              localized: "Usually 1-2s after you speak",
              comment: "Speech engine settings, engine card: how quickly text appears, in seconds.")
          ),
        ],
        isSelected: settings.selectedBackend == .whisperKit
      ) {
        settings.selectedBackend = .whisperKit
        showEngineChoices = false
      }
    }
  }

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // ── Transcription Engine (summary + Change) ─────────────────────
      // #3385: the engine is a summary with Change; the two cards open in
      // place. The note beside this heading replaces the page-level banner:
      // One page-level notice instead of the footnote repeated under every
      // section: these settings freeze at recording start, stated once (#2).
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(title: Copy.sectionHeading) {
        Text(Copy.nextRecordingNote)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      SettingsSummaryCard(
        isExpanded: $showEngineChoices,
        changeAccessibilityLabel: Copy.changeEngine,
        keepCurrentTitle: Copy.keepCurrent
      ) {
        engineSummary
      } status: {
        engineStatus
      } choices: {
        engineCards
      }
      .statusAlongsideChange(isParakeet && engineSwitchDeferredNotice == nil
        && modelDelivery.map { parakeetDeliveryRow($0.parakeetState) == nil } == true)
      // An engine change made elsewhere (onboarding, a fallback) leaves the
      // summary describing the new engine; close choices it made obsolete.
      .onChange(of: settings.selectedBackend) { _, _ in
        showEngineChoices = false
      }

      }

      // ── The current engine's group (#3385, founder Q5 Option A) ─────
      // Language and Faster Transcription stay with the engine they are
      // explained for. Each is still ONE stored value shared by both engines
      // (`languageMode`, `useStreamingASR`); only the explanations differ. The
      // heading names the engine, so no note sits beside it (founder, 2026-10-03).
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(resolvedTitle: currentEngineHeading, icon: currentEngineIcon)

      BrandedSection {
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
          BrandedRow {
            SettingsRow(
              icon: "globe",
              resolvedTitle: String(localized: Copy.autoDetectTitle),
              resolvedShort: String(
                localized: settings.selectedBackend == .parakeet
                  ? Copy.autoDetectFastShort : Copy.autoDetectMultilingualShort),
              resolvedHelp: languageSectionCopy + "\n\n" + String(localized: Copy.suggestionsHelp)
            ) {
              HStack(spacing: 10) {
                // PR4 of #763 (#252): Reset language suggestions. Clears the
                // three-strike state machine (dismissal counts, suppression set,
                // last-shown lang) so the chip can surface fresh for previously
                // dismissed/suppressed languages.
                Button("Reset suggestions") { languageSuggestionPresenter.resetAllChipState() }
                  .buttonStyle(.plain)
                  .font(.stHelper)
                  .foregroundStyle(Color.stAccent)
                  .settingsHoverQuiet()
                  .help(String(localized: Copy.suggestionsHelp))
                  .accessibilityLabel("Reset")
                Toggle("", isOn: Binding(
                  get: { isAutoLanguage(settings.languageMode) },
                  set: { newValue in
                    settings.languageMode =
                      newValue
                      ? .auto
                      : .locked(currentOrDefaultLockCode())
                  }
                ))
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(Copy.autoDetectTitle))
              }
            }
          }

          if case .locked(let code) = settings.languageMode {
            BrandedRow {
              VStack(alignment: .leading, spacing: 6) {
                // #3124: names English (UK) when British spelling is chosen.
                let entry = LanguageCatalog.entry(
                  forLockedCode: code, spelling: settings.englishSpelling)
                SettingsRow(
                  icon: "character.bubble",
                  resolvedTitle: LanguageCatalog.lockDisplayName(for: entry),
                  resolvedShort: String(localized: Copy.lockedLanguageShort),
                  resolvedHelp: String(localized: Copy.lockedLanguageHelp)
                ) {
                  Button("Change") {
                    showLanguageLockSheet = true
                  }
                  .controlSize(.small)
                  .font(.stHelper)
                  .accessibilityLabel(String(localized: Copy.changeLanguage))
                }
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
                    String(
                      localized:
                        "The fast engine can't lock to this language, so it's detecting automatically. Choose one of its 25 European languages, or switch to the multilingual engine.",
                      comment:
                        "Speech engine settings: the locked language is not one the fast engine supports."
                    )
                  )
                  .font(.stHelper)
                  .foregroundStyle(.stWarning)
                  .fixedSize(horizontal: false, vertical: true)
                  .padding(.leading, 37)
                }
              }
            }
          }

        }

        // ── Section 4: Transcription Mode ────────────────────────────────
        // #1276 Step 2 (PR-2): the "Faster Transcription" toggle now shows for both
        // engines (it binds the same `useStreamingASR`). On WhisperKit with
        // Auto-detect language, streaming safely uses clean batch instead
        // (the footnote explains why); a picked language streams.
        if settings.selectedBackend == .parakeet || settings.selectedBackend == .whisperKit {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 6) {
              SettingsRow(
                icon: "waveform",
                resolvedTitle: LiveTranscriptionCopy.toggleLabel,
                resolvedShort: String(
                  localized: settings.selectedBackend == .parakeet
                    ? Copy.fasterFastShort : Copy.fasterMultilingualShort)
              ) {
                VStack(alignment: .leading, spacing: 12) {
                  Text(LiveTranscriptionCopy.toggleDescription(for: settings.selectedBackend))
                    .settingsReadingCopy()
                  liveTranscriptionHelpPanel
                }
                // The panel's own 340 plus its 16pt padding each side.
                .frame(width: 372, alignment: .leading)
              } control: {
                Toggle("", isOn: $settings.useStreamingASR)
                .labelsHidden()
                .toggleStyle(BrandedToggleStyle())
                .fixedSize()
                .accessibilityLabel(Text(LiveTranscriptionCopy.toggleLabel))
              }
              if settings.selectedBackend == .whisperKit,
                isAutoLanguage(settings.languageMode)
              {
                Text(LiveTranscriptionCopy.autoLanguageFootnote)
                  .settingsReadingCopy()
                  .padding(.leading, 37)
              }
            }
          }
        }
      }

      }

      // ── Applies to both engines (#3385) ──────────────────────────────
      // Section 3: Auto-Stop, Section 5: Cleanup and Section 6: Memory
      // before #3385, gathered under one heading because none of them
      // behaves differently by engine.
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(title: Copy.sharedHeading)

      BrandedSection {
        BrandedRow {
          SettingsRow(
            icon: "stopwatch",
            title: Copy.stopOnSilenceTitle,
            short: Copy.stopOnSilenceShort,
            help: Copy.stopOnSilenceHelp
          ) {
            Toggle("", isOn: $settings.vadAutoStop)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .accessibilityLabel(Text(Copy.stopOnSilenceTitle))
          }
        }
        if settings.vadAutoStop {
          BrandedRow {
            VStack(alignment: .leading, spacing: 6) {
              BrandedSlider(
                String(
                  localized: "Pause duration",
                  comment:
                    "Speech engine settings, Auto-Stop: slider for how long a silence ends the recording."
                ),
                value: $settings.vadSilenceTimeout, in: 0.5...3.0,
                step: 0.25, low: "0.5s", high: "3.0s", format: "%.1fs")
              HStack(spacing: 6) {
                Text(Copy.pauseShort)
                  .font(.stRowHelper)
                  .foregroundStyle(.stTextSecondary)
                  .fixedSize(horizontal: false, vertical: true)
                SettingsInfoButton(
                  rowTitle: String(
                    localized: "Pause duration",
                    comment:
                      "Speech engine settings, Auto-Stop: slider for how long a silence ends the recording."
                  ),
                  tooltip: String(localized: Copy.pauseHelp)
                ) {
                  SettingsHelpText(text: String(localized: Copy.pauseHelp))
                }
              }
            }
          }
        }
        BrandedRow {
          SettingsRow(
            icon: "sparkles",
            title: Copy.fillerTitle,
            short: Copy.fillerShort,
            help: Copy.fillerShort
          ) {
            Toggle("", isOn: $settings.fillerRemovalEnabled)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .accessibilityLabel(Text(Copy.fillerTitle))
          }
        }
        BrandedRow {
          SettingsRow(
            icon: "face.smiling",
            title: Copy.emojiTitle,
            short: Copy.emojiShort,
            help: Copy.emojiHelp
          ) {
            Toggle("", isOn: $settings.emojiFormatterEnabled)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .accessibilityLabel(Text(Copy.emojiTitle))
          }
        }
        BrandedRow {
          SettingsRow(
            icon: "text.quote",
            resolvedTitle: SpokenPunctuationCopy.toggleLabel,
            resolvedShort: String(localized: Copy.punctuationShort)
          ) {
            VStack(alignment: .leading, spacing: 12) {
              Text(SpokenPunctuationCopy.toggleDescription)
                .settingsReadingCopy()
              spokenPunctuationHelpPanel
            }
            // The panel's 280pt footnote plus its 16pt padding each side.
            .frame(width: 312, alignment: .leading)
          } control: {
            Toggle("", isOn: $settings.spokenPunctuationEnabled)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .accessibilityLabel(Text(SpokenPunctuationCopy.toggleLabel))
          }
        }
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 6) {
            SettingsRow(
              icon: "memorychip",
              title: Copy.unloadTitle,
              short: Copy.unloadShort,
              help: Copy.unloadHelp
            ) {
              Picker(String(localized: Copy.unloadTitle), selection: $settings.modelUnloadPolicy) {
                ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
                  Text(policy.displayName).tag(policy)
                }
              }
              .labelsHidden()
              .fixedSize()
            }
            // Kept visible as well as behind "?": it says what the chosen
            // policy costs on the next recording, which is a consequence of
            // the current value rather than an explanation of the control.
            if settings.modelUnloadPolicy != .never {
              Text(Copy.unloadHelp)
                .settingsReadingCopy()
                .padding(.leading, 37)
            }
            if settings.modelUnloadPolicy == .immediately {
              Text(
                "Model is freed after every transcription. Expect a reload delay on each recording."
              )
              .font(.stHelper)
              .foregroundStyle(.stWarning)
              .padding(.leading, 37)
            }
          }
        }
      }
      }
    }
    .environment(\.settingsPR1Density, true)
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

  private typealias Copy = DictationSettingsCopy.Engine

  // MARK: - Engine summary and status (#3385)

  private var isParakeet: Bool { settings.selectedBackend == .parakeet }

  private var currentEngineIcon: String { isParakeet ? "bolt.fill" : "globe" }

  private var currentEngineName: String {
    isParakeet
      ? String(
        localized: "Fast", comment: "Speech engine settings, engine card: the fast engine's name.")
      : String(
        localized: "All Languages",
        comment: "Speech engine settings, engine card: the multilingual engine's name.")
  }

  private var currentEngineModel: String {
    isParakeet ? "Parakeet v3" : "Whisper Large v3 Turbo"
  }

  /// "FAST · PARAKEET V3": the heading names the engine these explanations describe.
  private var currentEngineHeading: String {
    String(
      localized: "\(currentEngineName) · \(currentEngineModel)",
      comment:
        "Speech engine settings: heading naming the current engine, then its model. Shown in capitals."
    ).uppercased()
  }

  private var engineSummary: some View {
    EngineSummaryContent(icon: currentEngineIcon, name: currentEngineName,
      model: currentEngineModel,
      short: String(localized: isParakeet ? Copy.fastSummary : Copy.allLanguagesSummary))
  }

  private func requestFastRecheck() {
    Task { await recheckFastAdmission() }
  }

  private func recheckFastAdmission() async {
    #if DEBUG
    // Completion belongs to the SUBJECT, including every dropped reply. The
    // debug hook replaces only the disk read, never eligibility or request guards.
    defer { fastAdmissionTestHooks?.onFinished(fastAdmission) }
    #endif
    // Like the pack reload owner: an older answer must not replace a later
    // re-check, even if the delivery mirror went through the same state again.
    fastAdmissionRequest &+= 1
    let request = fastAdmissionRequest
    fastAdmission = nil
    guard let modelDelivery else { return }
    let state = modelDelivery.parakeetState
    let admitted: Bool
    #if DEBUG
    if let hooks = fastAdmissionTestHooks {
      admitted = await hooks.read()
    } else {
      admitted = await modelDelivery.currentParakeetAdmission()
    }
    #else
    admitted = await modelDelivery.currentParakeetAdmission()
    #endif
    guard isParakeet, Task.isCancelled == false, request == fastAdmissionRequest,
      state == modelDelivery.parakeetState else { return }
    fastAdmission = admitted
  }

  /// Everything that can need the user's attention about the model, kept on
  /// screen whether or not the engine choices are open.
  @ViewBuilder
  private var engineStatus: some View {
    if let notice = engineSwitchDeferredNotice {
      Text(notice)
        .font(.stHelper)
        .foregroundStyle(.stWarning)
        .padding(.leading, 4)
    }

    // ── Section 2: WhisperKit Model Setup (conditional) ───────────────
    if settings.selectedBackend == .whisperKit {
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

    if isParakeet, let modelDelivery {
      HStack(spacing: 8) {
        ProviderStatusChip(status: EngineSummaryPresentation.fastModelStatus(admitted: fastAdmission), isHeadline: true)
        Button(action: requestFastRecheck) {
          Image(systemName: "arrow.clockwise").settingsHoverQuiet()
        }
        .buttonStyle(.borderless)
        .disabled(fastAdmission == nil)
        .help(String(localized: EngineSummaryCopy.recheckFast))
        .accessibilityLabel(Text(EngineSummaryCopy.recheckFast))
      }
      .fixedSize(horizontal: true, vertical: false)
      .task(id: modelDelivery.parakeetState) { await recheckFastAdmission() }
      .onAppear {
        #if DEBUG
        fastAdmissionTestHooks?.captureRecheck(requestFastRecheck)
        #endif
      }
      .onDisappear {
        fastAdmissionRequest &+= 1
        fastAdmission = nil
      }
    }

    // ── Delivery row (#1348 Phase 2, D6 states 2/3/4/5/7/8/10/11): shows
    // ONLY while the Parakeet model download/repair is in a user-relevant
    // state. #3385 founder supersedes D6's silent admitted presentation with
    // a fresh read-only Model ready cue above; these action states stay intact.
    // Same state stream onboarding renders; second renderer.
    if settings.selectedBackend == .parakeet, let modelDelivery,
      let row = parakeetDeliveryRow(modelDelivery.parakeetState)
    {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "arrow.down.circle")
            VStack(alignment: .leading, spacing: 4) {
              Text(row.title).settingsRowLabel()
              if let detail = row.detail {
                Text(detail).settingsReadingCopy()
              }
            }
            Spacer()
            // #2447: both were system styles on a settings PAGE, where
            // `.borderedProminent` renders plain grey and `.bordered` renders
            // grey one shade darker — so Cancel and Resume were the same
            // colour as each other and as this app's disabled treatment, with
            // no hover to contradict it.
            if row.showsCancel {
              SettingsActionButton(title: "Cancel", isEnabled: true, emphasis: .quiet, shape: .roundedRect, size: .medium) {
                modelDelivery.cancelParakeetDownload()
              }
            }
            if let action = row.actionLabel {
              SettingsActionButton(verbatimTitle: action, isEnabled: true, emphasis: .filled, shape: .roundedRect, size: .medium) {
                modelDelivery.resumeParakeetDownload()
              }
            }
          }
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
      return String(
        localized:
          "Auto-detect your language, or lock to a specific one. WhisperKit supports 99+ languages.",
        comment:
          "Speech engine settings, Language section: explanation for the multilingual engine (WhisperKit)."
      )
    case .parakeet:
      return String(
        localized: """
          Auto-detect your language, or lock to one of 25 European languages. \
          Locking helps stop the fast engine reaching for a different alphabet, \
          like Greek or Cyrillic appearing in German. It cannot tell apart two \
          languages written in the same alphabet.
          """,
        comment: "Speech engine settings, Language section: explanation for the fast engine.")
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

  /// The codes the picker may offer, for the ACTIVE backend.
  ///
  /// The rule itself moved to `LanguageLockOptions` (#2154) because Live Preview's
  /// Change button opens the same sheet and needs the same set; a private property
  /// on this view could not be reached from there. This stays as a one-line
  /// convenience over the shared owner so the three readers below are unchanged.
  /// **Do not reintroduce the switch here** — two copies of a rule whose failure
  /// mode is silent is the defect `LanguageLockOptions` was created to prevent.
  private var lockableLanguageCodes: Set<String>? {
    LanguageLockOptions.lockableCodes(for: settings.selectedBackend)
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
        validating
          ? String(
            localized: "Checking speech model files...",
            comment:
              "Speech engine settings, speech model download: checking files already on disk.")
          : String(
            localized: "Preparing download...",
            comment: "Speech engine settings, speech model download: about to start."),
        nil, false, nil
      )
    case .downloading(_, let bytesWritten, let totalBytes):
      let mb = Int(Double(bytesWritten) / 1_048_576)
      let totalMB = Int(Double(totalBytes) / 1_048_576)
      return (
        String(
          localized: "Downloading speech model...",
          comment: "Speech engine settings, speech model download: in progress."),
        String(
          localized: "\(String(mb)) MB of \(String(totalMB)) MB",
          comment:
            "Speech engine settings, speech model download: progress. The first number is megabytes done, the second the total."
        ),
        true, nil
      )
    case .verifying:
      return (
        String(
          localized: "Verifying download...",
          comment: "Speech engine settings, speech model download: checking the downloaded files."),
        nil, false, nil
      )
    case .cancelled:
      return (
        String(
          localized: "Download paused. Resume anytime.",
          comment: "Speech engine settings, speech model download: the user paused it."),
        nil, false,
        String(
          localized: "Resume",
          comment: "Speech engine settings, speech model download: button that resumes it.")
      )
    case .failed(let failure):
      return (
        String(
          localized: "Speech model download failed.",
          comment: "Speech engine settings, speech model download: failed."),
        ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail),
        false,
        String(
          localized: "Try Again",
          comment: "Speech engine settings, speech model download: button after a failure.")
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
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

    case .notDownloaded:
      // #3385: the download explanation moved behind "?"; the action and the
      // re-check stay beside the row.
      SettingsRow(
        icon: "arrow.down.circle",
        title: Copy.modelNotSetUp,
        short: Copy.modelSetupShort,
        help: Copy.modelSetupHelp
      ) {
        HStack {
          SettingsActionButton(
            title: Copy.setUpModel, isEnabled: true, emphasis: .filled, shape: .roundedRect, size: .medium
          ) {
            setup.whisperKitSetup.downloadModel()
          }

          whisperKitRefreshButton
        }
      }

    case .downloading(let progress, let status):
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStepIndicator(
          LocalizedStringResource(
            "Downloading...",
            comment: "Speech engine settings, WhisperKit model: the current setup step."))

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
          Button {
            setup.whisperKitSetup.cancelDownload()
          } label: {
            Text("Cancel").font(.stHelper).settingsHoverQuiet(tint: .stError)
          }
          .controlSize(.small)
          .buttonStyle(.borderless)
          .foregroundStyle(.stError)
        }
      }

    case .paused:
      VStack(alignment: .leading, spacing: 8) {
        whisperKitStepIndicator(
          LocalizedStringResource(
            "Download Paused",
            comment: "Speech engine settings, WhisperKit model: the current setup step."))
        Text("Download paused. Resume anytime.")
          .settingsReadingCopy()
        HStack {
          SettingsActionButton(title: "Resume", isEnabled: true, emphasis: .filled, shape: .roundedRect, size: .medium) {
            setup.whisperKitSetup.downloadModel()
          }
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
            .font(.stHelper)
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
            Button {
              setup.whisperKitSetup.removeModel()
            } label: {
              Text("Remove Model").font(.stHelper).settingsHoverQuiet(tint: .stError)
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
          .font(.stHelper)
          .foregroundStyle(.stWarning)

        Text(message)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)

        Button("Try Again") {
          Task { await setup.whisperKitSetup.detectState() }
        }
        .controlSize(.small)
        .font(.stHelper)
      }
    }
  }

  @ViewBuilder
  private func whisperKitStepIndicator(_ title: LocalizedStringResource) -> some View {
    Label(String(localized: title), systemImage: "1.circle.fill")
      .foregroundStyle(Color.stAccent)
      .font(.stRowLabel)
  }

  @ViewBuilder
  private var whisperKitRefreshButton: some View {
    Button {
      Task { await setup.whisperKitSetup.forceDetectState() }
    } label: {
      Image(systemName: "arrow.clockwise")
        .settingsHoverQuiet()
    }
    .buttonStyle(.borderless)
    .help("Re-check model status")
    .accessibilityLabel("Re-check model status")
  }

  // MARK: - Faster Transcription help (#1337)

  // #3385: the panel below is the Faster Transcription row's "?" content, shown
  // through the shared `SettingsInfoButton`. The reason it is a real button is
  // carried there: a real `Button`, never a hover-only reveal, so it is
  // reachable by keyboard and VoiceOver. The two panels are the same
  // affordance and must read as one family.

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

  // A real `Button`, never a hover-only reveal. Hover cannot be reached by keyboard and
  // does not exist for VoiceOver, and the personas who most need this vocabulary are the
  // ones least able to reach a hover target. `.help()` gives the mouse-hover tooltip on
  // top; the button is what makes it reachable at all. (#3385: that button is now the
  // shared `SettingsInfoButton` on the Spoken punctuation row.)

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
