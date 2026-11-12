import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Telemetry Bible Phase 4 (#1173): the privacy projection shared by the
/// baseline `settings.snapshot` (its comprehensive `config` block) and the
/// per-change `settings.changed` deltas. ONE source of the projected value
/// vocabulary so the holistic per-user config reconstructs cleanly query-side
/// (baseline overlaid with subsequent deltas). No raw model strings, key codes,
/// or locked language codes ever leave memory.
enum SettingsProjection {
  /// Every user-facing logical setting that gets a `settings.changed` delta.
  /// Excludes the Phase-2-owned backend, dev-only knobs (debug mode/level),
  /// device overrides, the deprecated WhisperKit language, the uninstrumented
  /// `ollamaModel` mirror, the cold XPC knob, and lifecycle/onboarding state.
  enum Logical: String, CaseIterable {
    case recordingMode = "recording_mode"
    case llmProvider = "llm_provider"
    case llmModel = "llm_model"
    /// #2772: the FILE-IMPORT polisher, separate from dictation's.
    ///
    /// This exists to answer one question the plan named before the code was written: do
    /// people actually run different engines for dictation and for imports, or is the
    /// per-surface split machinery nobody uses? The projection deliberately reports
    /// `follows_dictation` rather than the resolved engine when the user has not chosen,
    /// because "never touched it" and "chose the same engine on purpose" are the two
    /// answers that decide whether the split earned its cost, and the resolved value
    /// cannot tell them apart.
    case fileImportLLMProvider = "file_import_llm_provider"
    case fileImportLLMModel = "file_import_llm_model"
    /// #4287: the meeting summary engine's provider KIND only, no model, to answer whether
    /// people choose a different engine for summaries than for dictation.
    case meetingSummaryLLMProvider = "meeting_summary_llm_provider"
    case autoCopy = "auto_copy"
    case hotkeyEnabled = "hotkey_enabled"
    case vadAutoStop = "vad_auto_stop"
    case vadSilenceTimeout = "vad_silence_timeout"
    case vadSensitivity = "vad_sensitivity"
    case vadEnergyGate = "vad_energy_gate"
    case modelUnloadPolicy = "model_unload_policy"
    case restoreClipboard = "restore_clipboard"
    case keepDictationsOutOfClipboardHistory = "keep_dictations_out_of_clipboard_history"
    /// Quick Add's clipboard fallback (#2465). Instrumented from the start rather than added later,
    /// because the question this setting exists to answer is whether users reach for it — and a
    /// toggle nobody measured cannot answer it.
    case quickAddClipboardFallback = "quick_add_clipboard_fallback"
    case smartInsertion = "smart_insertion"
    // #2087. Adoption is the question the feature was built to answer: it ships
    // off, and whether anyone turns it on decides whether the rest of it earns
    // its keep. On/off only — a shape, never content.
    case escapeRecovery = "escape_recovery"
    case wordCorrection = "word_correction"
    case fillerRemoval = "filler_removal"
    case contactsSync = "contacts_sync"
    case emojiFormatter = "emoji_formatter"
    case spokenPunctuation = "spoken_punctuation"
    /// #2450: whether any language's start word has been customised (`default` / `customised`).
    /// A coarse shape, never the word the user typed. Written by the same `SettingKey` as the
    /// switch, so each logical coalesces and suppresses its own net no-ops: flipping the switch
    /// never reports a customisation, and editing a word never reports the switch.
    case spokenPunctuationStartWord = "spoken_punctuation_start_word"
    /// #4216: the English "say period for a dot" switch (`on` / `off`). Ships on; the question is
    /// how many Spoken punctuation users turn it off. Written by the same `SettingKey` as the switch,
    /// so it coalesces and suppresses its own net no-ops like the start word. On/off only.
    case spokenPunctuationPeriodWord = "spoken_punctuation_period_word"
    /// #3737: Casual mode (leave off the final full stop). Ships off; adoption is the question.
    /// On/off only.
    case casualMode = "casual_mode"
    /// #4473: the EG-1 size the user prefers (`full`/`mini`/`micro`). Changes when a person
    /// presses "Use <size>" on a size card or removes the size in use; the first-launch
    /// resolution writes before any observer exists, so it is never a change event.
    case egOneSize = "eg1_size"
    case crashRecovery = "crash_recovery"
    /// #996: whether the "remember this correction?" card is on. Instrumented because
    /// adoption of a default-ON toggle is measured by who turns it OFF, and that
    /// decides whether the card is welcome. On/off only, never a word.
    case learnFromEdits = "learn_from_edits"
    case languageMode = "language_mode"
    /// #3124: the English spelling PREFERENCE (`american` / `british`), the adoption signal for
    /// English (UK). A closed enum value, never a language code or any dictated text.
    case englishSpelling = "english_spelling"
    case streamingASR = "streaming_asr"
    // #1988. Instrumented because adoption is the question this feature was built
    // to answer, and the answer decides whether the macOS 26 floor is worth
    // covering with a second engine for older Macs. A boolean setting value,
    // never any dictated content.
    case livePreview = "live_preview"
    /// #2123: WHICH engine, not whether the preview is on. The two answer
    /// different questions — adoption vs which engine that adoption runs on —
    /// and the second is what decides whether the download was worth shipping.
    /// A closed enum value, never a language, a model path or any dictated text.
    case livePreviewEngine = "live_preview_engine"
    /// #2649: S1-mini's three control-line picks, one logical each. Instrumented
    /// because the question the pickers exist to answer is which axis users
    /// actually change, and that decides whether automatic per-destination
    /// selection is worth building. Closed enum values, never dictated text.
    case s1Styling = "s1_styling"
    case s1Structure = "s1_structure"
    case s1Context = "s1_context"
    case warmEnginePolicy = "warm_engine_policy"
    case appearance = "appearance"
    case overlayPillPosition = "overlay_pill_position"
    case toggleHotkeyShape = "toggle_hotkey_shape"
    /// #1987 — WHICH key is configured, one level finer than shape. `key_shape`
    /// reports `modifier_only` for both Globe and Right Option, so it cannot
    /// answer whether the Globe key was adopted. Content-free class only.
    case toggleHotkeyIdentity = "toggle_hotkey_identity"
    case pushToTalkHotkeyShape = "push_to_talk_hotkey_shape"
    case cancelHotkeyShape = "cancel_hotkey_shape"
    /// #2381. Shape only — `chord` or `modifier_only` — never the key code, which would say
    /// which physical key a named user pressed.
    case quickAddHotkeyShape = "quick_add_hotkey_shape"
    /// #3106. Shape only, like Quick Add's.
    case pasteLastHotkeyShape = "paste_last_hotkey_shape"
    case copyLastHotkeyShape = "copy_last_hotkey_shape"
    case playRecordingSounds = "play_recording_sounds"
    case recordingSoundPairing = "recording_sound_pairing"
    /// #1413. The chosen mode only (a closed four-value enum); never which app or
    /// device it acted on.
    case otherAudioWhileDictating = "other_audio_while_dictating"
    /// #2480. On or off only. Answers how many people choose a menu-bar-only app
    /// once the Dock icon is the default.
    case showInDock = "show_in_dock"
    /// #3441. On or off only. Answers how many people turn off the menu bar update wave.
    case menuBarUpdateAlert = "menu_bar_update_alert"
  }

  /// Logicals whose underlying control is a slider; they earn the longer
  /// debounce so a drag collapses to one bucketed delta.
  static let sliderLogicals: Set<Logical> = [.vadSilenceTimeout, .vadSensitivity]

  /// Map a raw `SettingKey` to its logical settings; empty = not instrumented.
  /// Each hotkey role groups its keyCode + modifiers keys into one shape logical
  /// (so a key+modifier reassignment is one delta, never two).
  ///
  /// #1987: returns an ARRAY because the toggle hotkey now projects two logicals,
  /// shape and identity. Every other key returns exactly the one it always did, or
  /// none. The array is the whole fan-out contract: `handle(_:)` seeds or enqueues
  /// each element independently, so shape and identity coalesce and suppress net
  /// no-ops separately rather than as a pair.
  static func logicals(for key: SettingsManager.SettingKey) -> [Logical] {
    switch key {
    case .recordingMode: return [.recordingMode]
    case .llmProvider: return [.llmProvider]
    // #1173: both the cloud `llmModel` and the local `ollamaModel` feed the one
    // `llm_model` logical — the projection reads the EFFECTIVE model
    // (`SettingsManager.effectiveLLMModel`, ollama→ollamaModel else llmModel), so
    // a mirror/discovery write to either field re-emits. Coalescing-by-logical
    // collapses a `.llmModel`+`.ollamaModel` pair (the Ollama mirror) into ONE
    // delta. (Codex r7 pivot.)
    case .llmModel, .ollamaModel: return [.llmModel]
    // #2772: mirrors the dictation pair one line up, for the same reason — the import's
    // cloud and Ollama model fields feed ONE logical, projected through the effective
    // resolution, so a write to either re-emits and the two coalesce into one delta.
    // #2772: switching between FOLLOW and an override changes the model projection with no
    // model write of its own — `follows_dictation` becomes a redacted id or back — so the
    // model logical must be refreshed alongside. The flush drops it when the projection is
    // unchanged. Found by the local lens on the cloud review.
    case .fileImportLLMProvider: return [.fileImportLLMProvider, .fileImportLLMModel]
    case .fileImportLLMModel, .fileImportOllamaModel: return [.fileImportLLMModel]
    case .meetingSummaryLLMProvider: return [.meetingSummaryLLMProvider]
    // #4287: provider kind only; model ids never become a summary delta.
    case .meetingSummaryLLMModel, .meetingSummaryOllamaModel: return []
    case .autoCopyToClipboard: return [.autoCopy]
    // #3972: no settings delta. `meeting.ended` carries the call-sound track status of every
    // meeting, which is the question this choice answers.
    case .meetingCaptureCallSound: return []
    // #3972: a one-time acknowledgement, not a preference.
    case .meetingCallSoundExplained: return []
    // #3972 R48: no settings delta. `meeting.ended` carries `summary_plan=off` for every meeting
    // that ends with it off, which is the question this choice answers.
    case .meetingWriteSummary: return []
    // #4069: no settings delta and no adoption measure by decision (plan §8).
    case .meetingTurnsOffDictation: return []
    case .meetingFollowsCallMute: return []
    // #4017 R8: `meeting.setup` reports how setup ended; a settings delta would repeat it.
    case .meetingOnboardingComplete: return []
    // #4017: no settings delta yet; the calendar permission answer rides on `meeting.setup`.
    case .meetingUseCalendarForNames: return []
    // #4012: `meeting.call_prompt` carries the mode with every answer; the counters are state.
    case .meetingCallDetection, .meetingCallAppsOff, .meetingCallNoCounts,
      .meetingCallFirstTipShown:
      return []
    // #3973: no settings delta in PR 1 (no screen writes it yet); its Language row arrives with
    // PR 2, which decides its telemetry.
    case .meetingLanguageMode: return []
    // #3973 C3: the engine a meeting used travels on `meeting.ended.engine`; no settings delta.
    case .meetingTranscriptEngine: return []
    // #4105: no settings delta; EnviousMeet telemetry is out of this change's scope (plan §8).
    case .meetingLiveWordsEngine, .meetingLiveWordsLanguage: return []
    case .hotkeyEnabled: return [.hotkeyEnabled]
    case .vadAutoStop: return [.vadAutoStop]
    case .vadSilenceTimeout: return [.vadSilenceTimeout]
    case .vadSensitivity: return [.vadSensitivity]
    case .vadEnergyGate: return [.vadEnergyGate]
    case .modelUnloadPolicy: return [.modelUnloadPolicy]
    case .restoreClipboardAfterPaste: return [.restoreClipboard]
    case .keepDictationsOutOfClipboardHistory: return [.keepDictationsOutOfClipboardHistory]
    case .quickAddClipboardFallback: return [.quickAddClipboardFallback]
    case .smartInsertion: return [.smartInsertion]
    case .escapeRecoveryEnabled: return [.escapeRecovery]
    case .wordCorrectionEnabled: return [.wordCorrection]
    case .fillerRemovalEnabled: return [.fillerRemoval]
    case .contactsSyncOnLaunchEnabled: return [.contactsSync]
    case .emojiFormatterEnabled: return [.emojiFormatter]
    case .spokenPunctuation:
      return [.spokenPunctuation, .spokenPunctuationStartWord, .spokenPunctuationPeriodWord]
    case .casualModeEnabled: return [.casualMode]
    case .crashRecoveryEnabled: return [.crashRecovery]
    case .learnFromEdits: return [.learnFromEdits]
    case .languageMode: return [.languageMode]
    case .englishSpelling: return [.englishSpelling]
    case .egOneSize: return [.egOneSize]
    case .useStreamingASR: return [.streamingASR]
    case .livePreviewEnabled: return [.livePreview]
    case .livePreviewEngine: return [.livePreviewEngine]
    case .s1MiniStyling: return [.s1Styling]
    case .s1MiniStructure: return [.s1Structure]
    case .s1MiniContext: return [.s1Context]
    case .warmEnginePolicy: return [.warmEnginePolicy]
    case .appearance: return [.appearance]
    case .overlayPillPosition: return [.overlayPillPosition]
    case .toggleKeyCode, .toggleModifiers: return [.toggleHotkeyShape, .toggleHotkeyIdentity]
    case .pushToTalkKeyCode, .pushToTalkModifiers: return [.pushToTalkHotkeyShape]
    case .cancelKeyCode, .cancelModifiers: return [.cancelHotkeyShape]
    case .quickAddKeyCode, .quickAddModifiers: return [.quickAddHotkeyShape]
    case .pasteLastKeyCode, .pasteLastModifiers: return [.pasteLastHotkeyShape]
    case .copyLastKeyCode, .copyLastModifiers: return [.copyLastHotkeyShape]
    case .playRecordingSounds: return [.playRecordingSounds]
    case .recordingSoundPairing: return [.recordingSoundPairing]
    case .otherAudioWhileDictating: return [.otherAudioWhileDictating]
    case .showInDock: return [.showInDock]
    case .showMenuBarUpdateAlert: return [.menuBarUpdateAlert]
    // Not instrumented.
    case .selectedBackend, .onboardingState, .hasCompletedOnboarding,
      .isDebugModeEnabled, .debugLogLevel, .whisperKitLanguage,
      .selectedInputDeviceUID, .preferredInputDeviceIDOverride,
      // #2664: a UID-keyed map is device identity, which never leaves the Mac;
      // the effective channel is already carried per take by
      // `capture_input_channel`, so a settings delta would add nothing.
      .inputChannelByDeviceUID,
      // #1480: the popover's own lifecycle telemetry (`bt_awareness.*`) owns this
      // signal, incl. `suppressed_by_setting`; no separate settings.changed delta.
      .showBluetoothTips,
      // #2376: which recording pill a user picked. NOT instrumented, and that is
      // a decision rather than an omission. Adding a `Logical` would auto-emit the
      // value into the `settings.snapshot` config block, which iterates
      // `Logical.allCases`, and no consumer exists for it. A closed enum value is
      // shape rather than content, so `CLAUDE.md`'s privacy test permits it
      // whenever a consumer appears; it simply has not.
      .recordingPillDesignWithoutWords, .recordingPillDesignWithWords:
      return []
    case .dictationRecordingRetention, .meetingRecordingRetention,
      .recordingStorageWarningThreshold, .recordingThresholdBehavior:
      // #3147: not instrumented in PR1. Telemetry for recordings follows the plan's §16 C8
      // budget review first (reader, cadence, existing-event reuse); none is added here.
      return []
    case .shareUsageMetrics, .sendCrashReports:
      // #3269: the privacy switches themselves are never reported. The founder ruled out a
      // final "opted out" event (2026-09-28), and a `Logical` here would also put the choice
      // into every `settings.snapshot` config block.
      return []
    }
  }

  /// What a model logical is projected FROM (#4353 D6): the raw provider and id, or the import
  /// follower state. The change recorder keeps this, not only the projected string, so the
  /// value before and after a write are projected under ONE cloud model list: a list refresh
  /// that newly recognises an id is never reported as a model change.
  enum ModelInput: Equatable {
    case followsDictation
    case model(LLMProvider, String)
  }

  /// The raw input of `.llmModel` and `.fileImportLLMModel`; nil for every other logical.
  @MainActor
  static func modelInput(for logical: Logical, settings: SettingsManager) -> ModelInput? {
    switch logical {
    case .llmModel: return .model(settings.llmProvider, settings.effectiveLLMModel)
    case .fileImportLLMModel:
      guard settings.fileImportLLMProvider != nil else { return .followsDictation }
      return .model(settings.effectiveFileImportLLMProvider, settings.effectiveFileImportLLMModel)
    default: return nil
    }
  }

  @MainActor
  static func project(_ input: ModelInput, list: CloudModelList?) -> String {
    switch input {
    case .followsDictation: return "follows_dictation"
    case .model(let provider, let id): return model(provider: provider, id: id, list: list)
    }
  }

  /// Project one logical to its privacy-safe emitted value, reading the current
  /// state from `settings`. `list` is the caller's one captured cloud model list snapshot
  /// (#4353 D6); only the model logicals read it.
  @MainActor
  static func value(
    for logical: Logical, settings: SettingsManager, list: CloudModelList?
  ) -> String {
    switch logical {
    case .recordingMode: return settings.recordingMode.rawValue
    case .llmProvider: return settings.llmProvider.rawValue
    case .llmModel, .fileImportLLMModel:
      // Both model logicals, one path: `modelInput` holds the follower rule.
      guard let input = modelInput(for: logical, settings: settings) else { return "none" }
      return project(input, list: list)
    // Preserve follow mode as a preference.
    // Explicit model selections pass through the shared redaction policy.
    case .fileImportLLMProvider:
      // Three states, one optional. Absent is "never chose"; `LLMProvider.none` is
      // "turned polish off for imports only". Flattening them would lose exactly the
      // distinction this field exists to measure.
      guard let chosen = settings.fileImportLLMProvider else { return "follows_dictation" }
      return chosen.rawValue
    case .meetingSummaryLLMProvider:
      // Absent before migration (onboarding not finished) or unreadable after a downgrade.
      return settings.meetingSummaryLLMProvider?.rawValue ?? "unset"
    case .autoCopy: return onOff(settings.autoCopyToClipboard)
    case .hotkeyEnabled: return onOff(settings.hotkeyEnabled)
    case .vadAutoStop: return onOff(settings.vadAutoStop)
    case .vadSilenceTimeout: return silenceTimeout(settings.vadSilenceTimeout)
    case .vadSensitivity: return sensitivityBucket(settings.vadSensitivity)
    case .vadEnergyGate: return onOff(settings.vadEnergyGate)
    case .modelUnloadPolicy: return settings.modelUnloadPolicy.rawValue
    case .restoreClipboard: return onOff(settings.restoreClipboardAfterPaste)
    case .keepDictationsOutOfClipboardHistory:
      return onOff(settings.keepDictationsOutOfClipboardHistory)
    case .quickAddClipboardFallback: return onOff(settings.quickAddClipboardFallback)
    case .smartInsertion: return onOff(settings.smartInsertion)
    case .escapeRecovery: return onOff(settings.escapeRecoveryEnabled)
    case .wordCorrection: return onOff(settings.wordCorrectionEnabled)
    case .fillerRemoval: return onOff(settings.fillerRemovalEnabled)
    case .contactsSync: return onOff(settings.contactsSyncOnLaunchEnabled)
    case .emojiFormatter: return onOff(settings.emojiFormatterEnabled)
    case .spokenPunctuation: return onOff(settings.spokenPunctuation.enabled)
    case .spokenPunctuationStartWord:
      return settings.spokenPunctuation.startWordOverrides.isEmpty ? "default" : "customised"
    case .spokenPunctuationPeriodWord: return onOff(settings.spokenPunctuation.englishPeriodWord)
    case .casualMode: return onOff(settings.casualModeEnabled)
    case .egOneSize: return settings.preferredEGOneSize.rawValue
    case .crashRecovery: return onOff(settings.crashRecoveryEnabled)
    case .learnFromEdits: return onOff(settings.learnFromEdits)
    case .languageMode: return languageModeLabel(settings.languageMode)
    case .englishSpelling: return settings.englishSpelling.rawValue
    case .streamingASR: return onOff(settings.useStreamingASR)
    case .livePreview: return onOff(settings.livePreviewEnabled)
    case .livePreviewEngine: return settings.livePreviewEngine.rawValue
    case .s1Styling: return settings.s1MiniStyling.rawValue
    case .s1Structure: return settings.s1MiniStructure.rawValue
    case .s1Context: return settings.s1MiniContext.rawValue
    case .warmEnginePolicy: return settings.warmEnginePolicy.rawValue
    case .appearance: return settings.appearancePreference.rawValue
    case .overlayPillPosition: return settings.overlayPillPosition.rawValue
    case .toggleHotkeyShape: return hotkeyShape(settings.toggleKeyCode)
    // #1987: same key, one level finer. Projected through the Services-owned
    // classifier so the vocabulary has exactly one authority and no key code can
    // reach telemetry from here.
    case .toggleHotkeyIdentity:
      return HotkeyKeyIdentity.classify(keyCode: settings.toggleKeyCode).rawValue
    case .pushToTalkHotkeyShape: return hotkeyShape(settings.pushToTalkKeyCode)
    case .cancelHotkeyShape: return hotkeyShape(settings.cancelKeyCode)
    case .quickAddHotkeyShape: return hotkeyShape(settings.quickAddKeyCode)
    case .pasteLastHotkeyShape: return hotkeyShape(settings.pasteLastKeyCode)
    case .copyLastHotkeyShape: return hotkeyShape(settings.copyLastKeyCode)
    case .playRecordingSounds: return onOff(settings.playRecordingSounds)
    case .recordingSoundPairing: return settings.recordingSoundPairing.rawValue
    case .otherAudioWhileDictating: return settings.otherAudioWhileDictating.rawValue
    case .showInDock: return onOff(settings.showInDock)
    case .menuBarUpdateAlert: return onOff(settings.showMenuBarUpdateAlert)
    }
  }

  /// The comprehensive `config` block for `settings.snapshot` — every instrumented
  /// logical EXCEPT the three already emitted as dedicated typed snapshot fields
  /// (`recording_mode`, `llm_provider`, `filler_removal`), so keys never collide.
  @MainActor
  static func snapshotConfig(_ settings: SettingsManager, list: CloudModelList?) -> [String: String] {
    let typed: Set<Logical> = [.recordingMode, .llmProvider, .fillerRemoval]
    var out: [String: String] = [:]
    for logical in Logical.allCases where !typed.contains(logical) {
      out[logical.rawValue] = value(for: logical, settings: settings, list: list)
    }
    return out
  }

  // MARK: - Field projections

  private static func onOff(_ v: Bool) -> String { v ? "on" : "off" }

  /// Project the EFFECTIVE model (`SettingsManager.effectiveLLMModel` — the same
  /// value the runtime uses) DENY-BY-DEFAULT: a model id is emitted only when it
  /// is on a known-safe allowlist, otherwise `custom`. This makes a private local
  /// model name impossible to leak regardless of the brief provider/model lag
  /// after a switch (Codex r7 pivot):
  /// - Ollama: verbatim names come ONLY from strings we published — the SHIPPED
  ///   catalog + the curated-private first-party catalog (EG-1, #1269). A model
  ///   that merely LOOKS first-party (user names their own model `eg-1-something`;
  ///   `isFirstPartyModel` prefix match) emits the fixed literal `eg-1-variant`,
  ///   never the raw string. Everything else collapses to `custom`. No
  ///   user-authored name can ever be emitted (#1269 cloud review r2).
  /// - OpenAI / Gemini / Claude (#4353 D6): an id the cloud model list names FOR THAT
  ///   PROVIDER, matched case-sensitively: the exact id when it has its own row (a dated id
  ///   included), else its dated base when the base has a row
  ///   (`ProviderModelID.withoutDateSnapshot`), else `custom`. A hidden row is still
  ///   recognised. A stale or private id is never emitted raw.
  @MainActor
  /// Takes the provider and id as VALUES rather than reading dictation's settings, so both
  /// surfaces run one redaction policy. Lifted for #2772 for the same reason the discovery
  /// repair was: a second copy is how the two would come to disagree, and here the
  /// disagreement is whether a user's own words leave their Mac.
  static func model(provider: LLMProvider, id: String, list: CloudModelList?) -> String {
    switch provider {
    case .appleIntelligence: return "apple-intelligence"
    // #1271: native EG-1 — the model id is OUR fixed literal from the
    // manifest contract (`effectiveLLMModel` returns `eg-1`), never user
    // input, so verbatim is safe by construction.
    case .egOne: return LLMProvider.egOneModelName
    case .s1Mini: return LLMProvider.s1MiniModelName
    case .none: return "none"
    case .ollama:
      let canonical = OllamaSetupService.canonicalModelName(id)
      // Verbatim ONLY for published names (shipped catalog + curated-private).
      let published = Set(
        (OllamaSetupService.modelCatalog + OllamaSetupService.curatedPrivateCatalog)
          .map { OllamaSetupService.canonicalModelName($0.name) })
      if published.contains(canonical) { return canonical }
      // First-party-prefixed but unpublished (a future EG variant we haven't
      // cataloged, or a user-named eg-1* model): fixed literal, never the raw
      // string — routing may treat it as ours, telemetry must not leak the name.
      if OllamaSetupService.isFirstPartyModel(id) { return "eg-1-variant" }
      return "custom"
    case .openAI, .gemini, .claude:
      // #4353 D2: no cloud model chosen is "none", never redacted as a custom id.
      if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "none" }
      return recognisedCloudID(provider: provider, id: id, list: list) ?? "custom"
    }
  }

  /// The id telemetry may emit for a cloud choice, or nil. Case-sensitive on purpose: list ids
  /// are lowercase, so `GPT-5.5` is not the published `gpt-5.5` and reads `custom`.
  static func recognisedCloudID(
    provider: LLMProvider, id: String, list: CloudModelList?
  ) -> String? {
    guard let list else { return nil }
    func listed(_ candidate: String) -> Bool {
      list.models.contains { $0.provider == provider && $0.id == candidate }
    }
    if listed(id) { return id }
    if let base = ProviderModelID.withoutDateSnapshot(id), listed(base) { return base }
    return nil
  }

  private static func languageModeLabel(_ mode: LanguageMode) -> String {
    switch mode {
    case .auto: return "auto"
    case .locked: return "locked"  // mode only, never the language code
    }
  }

  /// Modifier-only trigger (e.g. right Option alone) vs a regular-key chord.
  /// Never the keys themselves — a chord→chord reassignment is a projected no-op.
  private static func hotkeyShape(_ keyCode: UInt16) -> String {
    ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
  }

  private static func sensitivityBucket(_ v: Float) -> String {
    switch v {
    case ..<0.34: return "low"
    case ..<0.67: return "medium"
    default: return "high"
    }
  }

  /// Already low-cardinality (0.5–3.0, stepped by 0.25); emit the stepped value.
  private static func silenceTimeout(_ v: Double) -> String {
    String(format: "%.2f", v)
  }
}

/// Telemetry Bible Phase 4 (#1173): observes the single `SettingsManager.onChange`
/// funnel, classifies each change's source, coalesces a burst into one truthful
/// delta per logical setting, and emits `settings.changed`. Also fires the
/// comprehensive baseline at onboarding-completion (the first-run gap). A limb:
/// it never throws or awaits in the setter path; the debounce is emission
/// coalescing on an already-observed change, not a watcher. Held as an
/// app-lifetime `let` on `WisprBootstrapper` (a weak-only hold would dealloc and
/// silently stop emitting).
@MainActor
final class SettingsChangeTelemetry {
  private let settings: SettingsManager
  /// #4353 D6: the cloud model list in use now. Read once per seed and once per flush, so the
  /// `from` and `to` of a delta are always projected under the same list.
  private let cloudModelList: @MainActor () -> CloudModelList?
  private let emitBaseline: @MainActor () -> Void
  private let toggleWindow: Duration
  private let sliderWindow: Duration

  /// Last emitted (or seeded) projected value per logical — the `from` source.
  private var committedBaseline: [SettingsProjection.Logical: String] = [:]
  /// Value at the start of the in-flight burst, set once per window per logical.
  private var pendingOriginal: [SettingsProjection.Logical: String] = [:]
  /// #4353 D6: the raw input behind the committed and pending model values. A model delta's
  /// `from` is re-projected from this under the flush's list, never taken from a string
  /// projected under an older list: a list refresh alone must not read as a model change.
  private var committedModelInput: [SettingsProjection.Logical: SettingsProjection.ModelInput] = [:]
  private var pendingOriginalModelInput: [SettingsProjection.Logical: SettingsProjection.ModelInput] =
    [:]
  /// Burst source per logical: last-writer-wins, the source of the most recent write in the
  /// window (see `enqueue`).
  private var pendingSource: [SettingsProjection.Logical: Source] = [:]
  private var settleTask: Task<Void, Never>?

  enum Source: String {
    case user, system
    #if DEBUG
      /// #3765: a write made by the DEBUG dev control door.
      case devControl = "dev_control"
    #endif
  }

  init(
    settings: SettingsManager,
    cloudModelList: @escaping @MainActor () -> CloudModelList?,
    emitBaseline: @escaping @MainActor () -> Void,
    toggleWindow: Duration = .milliseconds(500),
    sliderWindow: Duration = .seconds(1)
  ) {
    self.settings = settings
    self.cloudModelList = cloudModelList
    self.emitBaseline = emitBaseline
    self.toggleWindow = toggleWindow
    self.sliderWindow = sliderWindow
    // Seed the committed baseline so the first post-launch change emits a
    // truthful `from`. Constructed after `SettingsManager.init` (whose writes
    // fire before the funnel is wired), so these reads are the launch state.
    seedBaseline()
  }

  /// Snapshot every logical's current projected value into `committedBaseline`.
  /// Used at construction (launch) and after the onboarding-completion baseline
  /// so the committed `from` always matches the most recently emitted snapshot.
  private func seedBaseline() {
    let list = cloudModelList()
    for logical in SettingsProjection.Logical.allCases {
      commit(logical, list: list)
    }
  }

  /// Record `logical`'s current value (and, for a model logical, its raw input) as committed.
  private func commit(_ logical: SettingsProjection.Logical, list: CloudModelList?) {
    committedBaseline[logical] = SettingsProjection.value(
      for: logical, settings: settings, list: list)
    committedModelInput[logical] = SettingsProjection.modelInput(for: logical, settings: settings)
  }

  /// The funnel entry: every `SettingsManager.onChange(key)` routes here.
  func handle(_ key: SettingsManager.SettingKey) {
    // Onboarding completion → emit the comprehensive baseline once. Fixes the
    // first-run gap: a fresh user who finishes setup and keeps the app open has
    // no launch snapshot until the next relaunch. `onboardingState` is otherwise
    // not an instrumented setting.
    if key == .onboardingState {
      if settings.onboardingState == .completed {
        emitBaseline()
        // Re-sync to the just-emitted snapshot. Onboarding suppression updates
        // committedBaseline only for the logical whose key fired — a DERIVED
        // projection (e.g. `llm_model` after an onboarding provider switch with
        // no model write) would otherwise stay stale and make a later real
        // delta look like a no-op, drifting reconstruction off the snapshot
        // (Codex r4). Clear any straggler and re-seed every logical.
        settleTask?.cancel()
        settleTask = nil
        pendingOriginal.removeAll()
        pendingOriginalModelInput.removeAll()
        pendingSource.removeAll()
        seedBaseline()
      }
      return
    }
    let logicals = SettingsProjection.logicals(for: key)
    // #1987: an uninstrumented key returns an empty array; the old shape returned
    // nil. Same outcome, explicitly handled rather than falling out of a `guard`.
    guard !logicals.isEmpty else { return }

    // Suppress onboarding-time writes (the onboarding-completion baseline
    // captures the final state); keep the committed baseline current so the
    // first real post-onboarding change has a truthful `from`.
    if settings.onboardingState != .completed {
      // #1987: advance the baseline for EVERY logical this key projects, not just
      // the first. Missing one would leave a stale `from` and make the first real
      // post-onboarding change look like a no-op.
      let list = cloudModelList()
      for logical in logicals {
        commit(logical, list: list)
        pendingOriginal[logical] = nil
        pendingOriginalModelInput[logical] = nil
        pendingSource[logical] = nil
      }
      return
    }

    // Read now, while the writer's scope is open; the flags are restored before `flush`.
    #if DEBUG
      let source: Source =
        settings.isDevControlWrite ? .devControl : (settings.isApplyingSystemWrite ? .system : .user)
    #else
      let source: Source = settings.isApplyingSystemWrite ? .system : .user
    #endif
    // Each logical coalesces and suppresses net no-ops independently, so a
    // key-code change that alters identity but not shape (Globe and Right Option
    // are both modifier-only) emits one delta, not two.
    for logical in logicals {
      enqueue(logical, source: source)
    }
    // `llm_model`'s projection also depends on `llmProvider` (cloud id vs Ollama
    // catalog vs `none`/`apple-intelligence`), so a provider change can alter the
    // projected model even with NO `llmModel` write — e.g. turning polish off →
    // `none`. Refresh it so reconstruction never holds a stale model. The flush
    // no-op check drops it when the projection is unchanged (e.g. OpenAI → Gemini
    // keeping a cloud id). The provider switch is a user gesture, so this enqueues
    // `user`; if async discovery then corrects the model inside the same window,
    // last-writer-wins re-stamps it `system` (Codex r6).
    if logicals.contains(.llmProvider) {
      enqueue(.llmModel, source: source)
    }
    // Once per RAW change, never once per logical: a fan-out must not shorten or
    // multiply the settle window.
    scheduleSettle()
  }

  /// Stage a pending delta for `logical`. The burst ORIGIN (committed baseline)
  /// is fixed once per window; the SOURCE is last-writer-wins — it always tracks
  /// the most recent write, so a coalesced delta reports the provenance of the
  /// FINAL value in `to`. This is the unifying rule for `llm_model`, whose value
  /// can be set in one window by a user pick, a provider-switch canonicalization
  /// (user gesture), or an async `applyDiscoveredModels` correction (system):
  /// whichever wrote last owns the source (Codex r5/r6).
  private func enqueue(_ logical: SettingsProjection.Logical, source: Source) {
    if pendingOriginal[logical] == nil {
      pendingOriginal[logical] =
        committedBaseline[logical]
        ?? SettingsProjection.value(for: logical, settings: settings, list: cloudModelList())
      pendingOriginalModelInput[logical] =
        committedModelInput[logical]
        ?? SettingsProjection.modelInput(for: logical, settings: settings)
    }
    pendingSource[logical] = source
  }

  /// Emit one coalesced delta per pending logical (net no-op bursts skipped) and
  /// advance the committed baseline. Invoked by the debounce timer in production;
  /// tests call it directly — the debounce delay is not a SUT measurement, so no
  /// clock seam is needed (`tests-no-real-time-scheduling-precision`).
  func flush() {
    settleTask?.cancel()
    settleTask = nil
    let pending = pendingOriginal
    let pendingInputs = pendingOriginalModelInput
    let sources = pendingSource
    pendingOriginal.removeAll()
    pendingOriginalModelInput.removeAll()
    pendingSource.removeAll()
    // #4353 D6: ONE list for the whole comparison, `from` and `to` alike.
    let list = cloudModelList()
    for (logical, stored) in pending {
      let original = pendingInputs[logical].map { SettingsProjection.project($0, list: list) } ?? stored
      let latest = SettingsProjection.value(for: logical, settings: settings, list: list)
      committedModelInput[logical] = SettingsProjection.modelInput(for: logical, settings: settings)
      guard latest != original else {
        committedBaseline[logical] = latest
        continue  // net no-op (A→B→A)
      }
      TelemetryService.shared.settingsChanged(
        setting: logical.rawValue, from: original, to: latest,
        source: (sources[logical] ?? .user).rawValue)
      committedBaseline[logical] = latest
    }
  }

  private func scheduleSettle() {
    settleTask?.cancel()
    let hasSlider = pendingOriginal.keys.contains { SettingsProjection.sliderLogicals.contains($0) }
    let window = hasSlider ? sliderWindow : toggleWindow
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }
}
