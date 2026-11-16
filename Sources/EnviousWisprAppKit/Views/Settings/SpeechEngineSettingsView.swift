import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
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
  /// #4216: the Spoken punctuation window (start word and the English period switch).
  @State private var showSpokenPunctuationSheet = false
  /// #3385: whether the two engine cards are open under the summary.
  @State private var showEngineChoices: Bool = false

  init(choicesExpanded: Bool = false) {
    _showEngineChoices = State(initialValue: choicesExpanded)
  }
  /// #4578: the installation owner the engine status lines read.
  @Environment(SpeechModelLibrary.self) private var library: SpeechModelLibrary?

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
  /// leads on speed; All Languages (Whisper) leads on breadth. Adaptive grid
  /// so the pair reflows to a single column as the content card narrows.
  private var engineCards: some View {
    // ── Transcription Engine (card selector) ─────────────────────────
    // A primary choice with meaningful trade-offs, so it reads as two
    // selectable cards rather than a segmented pill (#3).
    // (#3385: the cards now open under the summary's Change button.)
    // Two equal flexible columns so the pair always spans the full content
    // width (an adaptive grid left-packs them and strands empty space on the
    // right). Each card carries a "pick this when" tagline plus a spec table
    // ending in the short/medium/long transcribe times (#3792), owned by
    // EngineChoicePresentation (#3482), where the grounding for every value
    // lives beside it.
    // Eager (`Grid`, not `LazyVGrid`): a lazy grid below the fold has no cards, so a Settings
    // search for an engine could not arrive at one (#3482). Two cards gain nothing from laziness;
    // flexible frames split the row evenly, as the flexible columns did.
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
      GridRow(alignment: .top) {
        ForEach(EngineChoicePresentation.choices(parakeetModel: parakeetModelLabel), id: \.backend) { choice in
          EngineCard(
            icon: choice.icon,
            map: .id(choice.mapID),
            tagline: String(localized: choice.tagline),
            specs: choice.specs.map { (String(localized: $0.label), $0.value.resolved) },
            times: EngineCardTimes(
              label: String(localized: EngineChoicePresentation.transcribeTimeLabel),
              values: choice.times.values,
              captions: EngineChoicePresentation.timeCaptions.map { String(localized: $0) },
              help: choice.times.help),
            isSelected: settings.selectedBackend == choice.backend,
            onSelect: {
              settings.selectedBackend = choice.backend
              // #3385: picking, including the engine already chosen, closes the choices.
              showEngineChoices = false
            },
            fillsHeight: true,
            footer: {
              // #4578: each engine's status line: Remove on every downloaded engine, picked
              // or not; Set up model on one that is not.
              SpeechEngineStatusRow(engine: choice.backend, place: .dictationCard)
                .padding([.horizontal, .bottom], 16)
            }
          )
          .frame(maxWidth: .infinity, alignment: .top)
        }
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
      SettingsSectionHeading(map: .id(.sectionTranscriptionEngine)) {
        Text(Copy.nextRecordingNote)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      SettingsSummaryCard(
        map: .id(.transcriptionEngine),
        isExpanded: $showEngineChoices,
        changeAccessibilityLabel: Copy.changeEngine,
        change: .transcriptionEngineChange,
        keepCurrent: .transcriptionEngineKeepCurrent
      ) {
        engineSummary
      } status: {
        engineStatus
      } choices: {
        engineCards
      }
      .statusAlongsideChange(statusIsCompact)
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
      SettingsSectionHeading(map: currentEngineRef, icon: currentEngineIcon)

      BrandedSection {
        // ── Section 3: Language Selection ──
        // #1678: one control, both engines. It was WhisperKit-only, so a German
        // speaker on the default engine could not stop auto-detect guessing —
        // the reported bug (Greek recognised in German speech). The two engines
        // genuinely do different amounts with a lock, and that difference is
        // carried by the help copy below, not by a different control or label.
        // Whisper still waits for setup: its language list is only meaningful
        // once its model is ready. Parakeet's lock is a stored preference that
        // applies at decode time, so it needs no readiness gate.
        if languageSectionIsAvailable {
          BrandedRow {
            SettingsRow(
              map: .id(.autoDetectLanguage),
              icon: "globe",
              runtimeShort: String(
                localized: settings.selectedBackend == .parakeet
                  ? Copy.autoDetectFastShort : Copy.autoDetectMultilingualShort),
              resolvedHelp: languageSectionCopy + "\n\n" + String(localized: Copy.suggestionsHelp)
            ) {
              HStack(spacing: 10) {
                // PR4 of #763 (#252): Reset language suggestions. Clears the
                // three-strike state machine (dismissal counts, suppression set,
                // last-shown lang) so the chip can surface fresh for previously
                // dismissed/suppressed languages.
                Button(SettingsItemCopy.Engine.resetSuggestions) { languageSuggestionPresenter.resetAllChipState() }
                  .settingsArrivalFocusControl()
                  .settingsMapRegistration(.autoDetectLanguageResetSuggestions)
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
                // #3124: names English (UK) when British spelling is chosen; the map's
                // locked-language resolver reads the same catalog entry (#3482).
                SettingsRow(
                  map: .dynamic(
                    .lockedLanguage, .lockedLanguage(code: code, spelling: settings.englishSpelling)),
                  icon: "character.bubble",
                  resolvedHelp: String(localized: Copy.lockedLanguageHelp)
                ) {
                  Button {
                    showLanguageLockSheet = true
                  } label: {
                    EnviousButtonLabel(SettingsItemCopy.Engine.lockedLanguageChange)
                  }
                  .settingsButton(isEnabled: true)
                  .accessibilityLabel(String(localized: Copy.changeLanguage))
                  .settingsMapRegistration(.lockedLanguageChange)
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
        // #3809: present the settings owner's language prerequisite without disabling
        // its remedy or help. #1276's clean-batch runtime fallback stays unchanged.
        if settings.selectedBackend == .parakeet || settings.selectedBackend == .whisper {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 6) {
              SettingsRow(
                map: .id(.fasterTranscription),
                icon: "waveform",
                runtimeShort: String(
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
                .accessibilityHint(Text(settings.canUseStreamingASR ? "" : LiveTranscriptionCopy.autoLanguageFootnote))
                .disabled(!settings.canUseStreamingASR)
                .opacity(settings.canUseStreamingASR ? 1 : 0.5)
              }
              if !settings.canUseStreamingASR {
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
      SettingsSectionHeading(map: .id(.sectionEngineShared))

      BrandedSection {
        BrandedRow {
          SettingsRow(
            map: .id(.stopOnSilence),
            icon: "stopwatch",
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
                String(localized: SettingsItemCopy.Engine.pauseDuration),
                value: $settings.vadSilenceTimeout, in: SilenceTimeoutSlider.range,
                step: SilenceTimeoutSlider.step, low: "0.5s", high: "3.0s", format: "%.1fs")
              HStack(spacing: 6) {
                Text(Copy.pauseShort)
                  .font(.stRowHelper)
                  .foregroundStyle(.stTextSecondary)
                  .fixedSize(horizontal: false, vertical: true)
                SettingsInfoButton(
                  rowTitle: String(localized: SettingsItemCopy.Engine.pauseDuration),
                  tooltip: String(localized: Copy.pauseHelp)
                ) {
                  SettingsHelpText(text: String(localized: Copy.pauseHelp))
                }
              }
            }
            .settingsMapRegistration(.pauseDuration)
          }
        }
        BrandedRow {
          SettingsRow(
            map: .id(.fillerRemoval),
            icon: "sparkles",
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
            map: .id(.spokenEmoji),
            icon: "face.smiling",
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
            map: .id(.spokenPunctuation),
            icon: "text.quote"
          ) {
            SpokenPunctuationHelpPanel()
          } control: {
            HStack(spacing: 10) {
              // #4216: the start word and the English period switch live in their own window.
              if settings.spokenPunctuation.enabled {
                Button {
                  showSpokenPunctuationSheet = true
                } label: {
                  EnviousButtonLabel(verbatim: SpokenPunctuationCopy.configureButton)
                }
                .settingsButton(isEnabled: true)
                .settingsArrivalWithoutInheritedPlace()
                .accessibilityLabel(Text(SpokenPunctuationCopy.configureAccessibilityLabel))
              }
              Toggle("", isOn: $settings.spokenPunctuation.enabled)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(SpokenPunctuationCopy.toggleLabel))
            }
          }
        }
        BrandedRow {
          SettingsRow(
            map: .id(.casualMode),
            icon: "bubble.left",
            help: Copy.casualHelp
          ) {
            Toggle("", isOn: $settings.casualModeEnabled)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .accessibilityLabel(Text(Copy.casualTitle))
          }
        }
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 6) {
            SettingsRow(
              map: .id(.unloadModelAfter),
              icon: "memorychip",
              help: Copy.unloadHelp
            ) {
              SettingsMenuPicker(
                title: String(localized: Copy.unloadTitle),
                selection: $settings.modelUnloadPolicy,
                valueLabel: settings.modelUnloadPolicy.displayName
              ) {
                ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
                  Text(policy.displayName).tag(policy)
                }
              }
              .settingsArrivalFocusControl()
              .accessibilityLabel(Text(Copy.unloadTitle))
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
      if settings.selectedBackend == .whisper {
        Task { await setup.whisperSetup.detectState() }
      }
    }
    .onChange(of: settings.selectedBackend) { _, newBackend in
      if newBackend == .whisper {
        Task { await setup.whisperSetup.detectState() }
      }
    }
    .sheet(isPresented: $showLanguageLockSheet) {
      LanguageLockSheet(lockableCodes: lockableLanguageCodes)
    }
    .sheet(isPresented: $showSpokenPunctuationSheet) {
      SpokenPunctuationConfigureSheet(settings: settings)
    }
  }

  private typealias Copy = DictationSettingsCopy.Engine

  // MARK: - Engine summary and status (#3385)

  private var isParakeet: Bool { settings.selectedBackend == .parakeet }

  private var currentEngine: EngineChoicePresentation.Choice {
    EngineChoicePresentation.choice(for: settings.selectedBackend, parakeetModel: parakeetModelLabel)
  }

  /// #3546: the Parakeet model this Mac presents (serving, or pending), never
  /// one that is merely downloading or admitted. No delivery home means the
  /// no-handle route, which serves v3.
  private var parakeetModelLabel: String {
    modelDelivery?.parakeetModelLabel ?? ParakeetModel.v3.displayName
  }

  private var currentEngineIcon: String { currentEngine.icon }

  private var currentEngineName: String { String(localized: currentEngine.title) }

  private var currentEngineModel: String { currentEngine.model }

  /// "FAST · PARAKEET ULTRA": the heading names the engine these explanations describe. The
  /// Settings Map owns the composition (#3482).
  private var currentEngineRef: SettingsMapRef {
    .dynamic(.currentEngineSection, .currentEngine(currentEngine))
  }

  private var engineSummary: some View {
    EngineSummaryContent(icon: currentEngineIcon, name: currentEngineName,
      model: currentEngineModel,
      short: String(localized: currentEngine.summary))
  }

  /// Everything that can need the user's attention about the model, kept on screen while the
  /// engine choices are closed. #4578: the selected engine's status line, the same one each
  /// engine card shows when the choices are open (so it is never drawn twice).
  @ViewBuilder
  private var engineStatus: some View {
    if let notice = engineSwitchDeferredNotice {
      Text(notice)
        .font(.stHelper)
        .foregroundStyle(.stWarning)
        .padding(.leading, 4)
    }
    if !showEngineChoices {
      SpeechEngineStatusRow(engine: settings.selectedBackend, place: .dictationSummary)
    }
  }

  /// The summary's status sits beside Change only when it is the plain Parakeet "Model ready"
  /// line with nothing else to say (#3385 layout).
  private var statusIsCompact: Bool {
    guard isParakeet, engineSwitchDeferredNotice == nil, let library else { return false }
    let status = SpeechEngineStatus.parakeet(
      installed: library.installedSnapshot(.parakeet), removing: library.isRemovingParakeet,
      leftovers: library.parakeetHasLeftovers,
      row: modelDelivery.flatMap { Self.parakeetRow(of: $0) })
    return status.install == .ready && status.operation == nil
      && library.parakeetRemoveNotice == nil
  }


  // MARK: - Language section (#1678)

  /// Whisper's list is only meaningful once its model is ready. Parakeet's
  /// lock is a stored preference applied at decode time, so it has no such gate.
  private var languageSectionIsAvailable: Bool {
    switch settings.selectedBackend {
    case .whisper:
      if case .ready = setup.whisperSetup.setupState { return true }
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
    case .whisper:
      return String(
        localized:
          "Auto-detect your language, or lock to a specific one. Whisper supports 99+ languages.",
        comment:
          "Speech engine settings, Language section: explanation for the multilingual engine (Whisper)."
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
    // #3905: the same rule the recording freezes with, so this sentence cannot drift from it.
    LanguageLockOptions.isLockHonoured(code, in: lockableLanguageCodes)
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
  /// Which owner a Parakeet row's buttons act on (#3546).
  enum ParakeetRowOwner { case foreground, backgroundUpgrade, retry }

  struct ParakeetRow: Equatable {
    let title: String
    let detail: String?
    let showsCancel: Bool
    let action: SettingsMapID?
    let owner: ParakeetRowOwner
  }

  /// #3546: the one Parakeet row Settings shows, or none. Row T's explicit
  /// Retry first; then, while v3 serves under an upgrade target, the background
  /// Ultra download (downloading or declined; idle, deferred and failed stay
  /// silent because dictation works); otherwise the serving model's own
  /// delivery states, unchanged.
  func parakeetRow(_ delivery: ModelDeliveryHome) -> ParakeetRow? { Self.parakeetRow(of: delivery) }

  /// #4578: the same row, read by the shared engine status line on both Settings tabs.
  static func parakeetRow(of delivery: ModelDeliveryHome) -> ParakeetRow? {
    Self.parakeetRow(
      needsExplicitRetry: delivery.parakeetNeedsExplicitRetry,
      rowIsBackgroundUpgrade: delivery.parakeetRowIsBackgroundUpgrade,
      background: delivery.parakeetBackgroundUpgrade,
      foreground: delivery.parakeetState)
  }

  /// The pure chooser behind `parakeetRow(_:)`, so every state is testable.
  static func parakeetRow(
    needsExplicitRetry: Bool, rowIsBackgroundUpgrade: Bool,
    background: ParakeetUpgradeCoordinator.BackgroundUpgradeState, foreground: DeliveryState
  ) -> ParakeetRow? {
    if needsExplicitRetry {
      return ParakeetRow(
        title: String(
          localized: "Speech model couldn't load.",
          comment:
            "Speech engine settings, speech model: the downloaded model could not be loaded after several tries; Try again starts another attempt."
        ),
        detail: nil, showsCancel: false, action: .fastModelTryAgain, owner: .retry)
    }
    if rowIsBackgroundUpgrade {
      switch background {
      case .downloading(_, let bytesWritten, let totalBytes):
        let row = Self.downloadingRow(bytesWritten: bytesWritten, totalBytes: totalBytes)
        return ParakeetRow(
          title: row.title, detail: row.detail, showsCancel: true, action: nil,
          owner: .backgroundUpgrade)
      case .declined:
        return ParakeetRow(
          title: Self.pausedTitle, detail: nil, showsCancel: false, action: .fastModelResume,
          owner: .backgroundUpgrade)
      case .idle, .deferredDisk, .failed:
        return nil
      }
    }
    return parakeetDeliveryRow(foreground).map {
      ParakeetRow(
        title: $0.title, detail: $0.detail, showsCancel: $0.showsCancel, action: $0.action,
        owner: .foreground)
    }
  }

  private static func downloadingRow(bytesWritten: Int64, totalBytes: Int64) -> (
    title: String, detail: String
  ) {
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
      )
    )
  }

  private static var pausedTitle: String {
    String(
      localized: "Download paused. Resume anytime.",
      comment: "Speech engine settings, speech model download: the user paused it.")
  }

  private static func parakeetDeliveryRow(_ state: DeliveryState) -> (
    title: String, detail: String?, showsCancel: Bool, action: SettingsMapID?
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
      let row = Self.downloadingRow(bytesWritten: bytesWritten, totalBytes: totalBytes)
      return (row.title, row.detail, true, nil)
    case .verifying:
      return (
        String(
          localized: "Verifying download...",
          comment: "Speech engine settings, speech model download: checking the downloaded files."),
        nil, false, nil
      )
    case .cancelled:
      return (
        Self.pausedTitle,
        nil, false,
        .fastModelResume
      )
    case .failed(let failure):
      return (
        String(
          localized: "Speech model download failed.",
          comment: "Speech engine settings, speech model download: failed."),
        ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail),
        false,
        .fastModelTryAgain
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
  /// to lock to. Preserve the prior locked code if we have one; otherwise the Mac's own language
  /// (#4528 B3, the Setup recommender's language contract), then the W2 migration of
  /// `whisperKitLanguage`, then English. Each must be supported and honoured by the engine.
  private func currentOrDefaultLockCode() -> String {
    LanguageLockOptions.defaultLockCode(
      current: settings.languageMode,
      candidates: [SetupAdvice.macLanguageCode, settings.whisperKitLanguage].compactMap { $0 },
      lockable: lockableLanguageCodes)
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
}

extension SpeechEngineSettingsView {
  /// The inline line under the Whisper setup after a Remove press that did not remove. Shared by
  /// dictation's Engine tab and EnviousMeet's Transcript engine card (#4325).
  static func removeNoticeText(_ notice: WhisperRemoveNotice) -> String {
    switch notice {
    case .refusedDictationInFlight:
      String(localized: "Finish your current dictation first, then try again.")
    case .refusedMeetingActive:
      MeetingDownloadAdmission.refusal
    case .failed:
      String(localized: "The model could not be removed. Please try again.")
    }
  }
}
