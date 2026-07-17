import AppKit
import EnviousWisprCore

@MainActor
@Observable
public final class SettingsManager {
  public enum SettingKey {
    case selectedBackend
    case recordingMode
    case llmProvider
    case llmModel
    case ollamaModel
    case autoCopyToClipboard
    case hotkeyEnabled
    case vadAutoStop
    case vadSilenceTimeout
    case vadSensitivity
    case vadEnergyGate
    case onboardingState
    case hasCompletedOnboarding  // Legacy — kept for backward-compat writes only
    case cancelKeyCode
    case cancelModifiers
    case toggleKeyCode
    case toggleModifiers
    case pushToTalkKeyCode
    case pushToTalkModifiers
    case modelUnloadPolicy
    case restoreClipboardAfterPaste
    case wordCorrectionEnabled
    case fillerRemovalEnabled
    case emojiFormatterEnabled
    case crashRecoveryEnabled
    case contactsSyncOnLaunchEnabled
    case isDebugModeEnabled
    case isDictationAudioArchiveEnabled
    case debugLogLevel
    case useExtendedThinking
    case whisperKitLanguage
    case languageMode
    case selectedInputDeviceUID
    case preferredInputDeviceIDOverride
    case useStreamingASR
    case warmEnginePolicy
    case appearance
    case overlayPillPosition
    case showBluetoothTips
    case playRecordingSounds
    case recordingSoundPairing
  }

  public var onChange: ((SettingKey) -> Void)?

  /// Telemetry Bible Phase 4 (#1173) support flag — true only while async model
  /// DISCOVERY (`applyDiscoveredModels`) is auto-correcting a setting behind the
  /// user's back, so the change observer can stamp that delta `source=system`.
  /// Provider-switch canonicalization is deliberately NOT flagged — it is part of
  /// the user's provider gesture and stays `source=user` (Codex r5). NOT a
  /// product-behavior knob: it gates no logic, only the telemetry label. Set/
  /// reset synchronously on the main actor (no `await` between, so no reentrancy).
  public var isApplyingSystemWrite = false

  /// The store backing all user-preference reads/writes. Injected for testability;
  /// production resolves to `SettingsDefaults.store` (the build-shared suite, #923).
  /// EXCEPTION: the per-build `devAdapterPolishEnabled` knob (DEBUG only)
  /// deliberately uses `UserDefaults.standard` directly, never this store.
  private let defaults: UserDefaults

  /// The UserDefaults keys SettingsManager owns that are UNIFIED across builds
  /// (the #923 migration's source of truth). Excludes the per-build DEBUG
  /// `devAdapterPolishEnabled` knob; the legacy `noiseSuppression` key is not a
  /// live setting and is stripped on load by the #734 migration below.
  public nonisolated static let unifiedDefaultsKeys: [String] = [
    "selectedBackend", "recordingMode", "llmProvider", "lastLLMProvider", "llmModel", "ollamaModel",
    "autoCopyToClipboard", "hotkeyEnabled", "vadAutoStop", "vadSilenceTimeout",
    "vadSensitivity", "vadEnergyGate", "onboardingState", "hasCompletedOnboarding",
    "cancelKeyCode", "cancelModifiersRaw", "toggleKeyCode", "toggleModifiersRaw",
    "pushToTalkKeyCode", "pushToTalkModifiersRaw", "modelUnloadPolicy",
    "restoreClipboardAfterPaste", "wordCorrectionEnabled", "fillerRemovalEnabled",
    "emojiFormatterEnabled", "crashRecoveryEnabled", "contactsSyncOnLaunchEnabled",
    "isDebugModeEnabled", "isDictationAudioArchiveEnabled", "debugLogLevel",
    "useExtendedThinking", "whisperKitLanguage", "languageMode",
    "selectedInputDeviceUID", "preferredInputDeviceIDOverride",
    "useStreamingASR", "warmEnginePolicy", "appearancePreference", "overlayPillPosition",
    "showBluetoothTips", "playRecordingSounds", "recordingSoundPairing",
    WhatsNewConstants.lastSeenVersionDefaultsKey,
  ]

  public var selectedBackend: ASRBackendType {
    didSet {
      defaults.set(selectedBackend.rawValue, forKey: "selectedBackend")
      onChange?(.selectedBackend)
    }
  }

  public var recordingMode: RecordingMode {
    didSet {
      defaults.set(recordingMode.rawValue, forKey: "recordingMode")
      onChange?(.recordingMode)
    }
  }

  public var llmProvider: LLMProvider {
    didSet {
      if oldValue != llmProvider {
        TelemetryService.shared.providerChanged(from: oldValue.rawValue, to: llmProvider.rawValue)
      }
      defaults.set(llmProvider.rawValue, forKey: "llmProvider")
      // Canonicalize the model for the new provider. This is NOT flagged a system
      // write (#1173 / Codex r5): it is a synchronous consequence of the user's
      // provider pick, so the resulting `llm_model` delta stays `source=user`,
      // consistent across providers (turning polish off from Apple Intelligence
      // vs OpenAI both read `user`). Only async background discovery
      // (`applyDiscoveredModels`) is `system`.
      canonicalizeLLMModelForProvider()
      // Remember the last real engine so the top on/off toggle can restore it
      // when polish is turned back on (#1285). `.none` is the "off" state, not
      // an engine, so it is never remembered. Maintained here (and seeded in
      // init) so SettingsManager is the single owner of the remembered engine.
      if llmProvider != .none {
        lastLLMProvider = llmProvider
      }
      onChange?(.llmProvider)
    }
  }

  /// The last non-off polish engine the user selected. Backs the AI Polish
  /// on/off toggle (#1285): turning polish off sets `llmProvider = .none`;
  /// turning it back on restores this. Plain stored property with a persisting
  /// `didSet` (NOT an observed setting with an `onChange` case) — nothing in the
  /// pipeline reconciles on it, it is pure UI memory. Seeded in `init` with an
  /// explicit write-through because Swift does not fire `didSet` for init
  /// assignments.
  public var lastLLMProvider: LLMProvider {
    didSet {
      defaults.set(lastLLMProvider.rawValue, forKey: "lastLLMProvider")
    }
  }

  /// Canonicalize `llmModel` for the current provider (single authority —
  /// called from the provider didSet AND init). Fixed-literal providers
  /// (Apple Intelligence, EG-1) pin their literal; switching AWAY from one
  /// must sweep that literal too, or a cloud provider inherits it as its
  /// model name and every polish request fails until discovery repairs it
  /// (#1271 Codex r7: only "apple-intelligence" was swept, so "eg-1"
  /// leaked into OpenAI/Gemini).
  private func canonicalizeLLMModelForProvider() {
    let fixedLiterals = ["apple-intelligence", LLMProvider.egOneModelName]
    switch llmProvider {
    case .appleIntelligence:
      llmModel = "apple-intelligence"
    case .egOne:
      llmModel = LLMProvider.egOneModelName
    case .ollama:
      // #1305: empty stays empty for Ollama — refilling from `ollamaModel`
      // here silently re-armed the phantom picker selection at every launch
      // after discovery had cleared it. Only discovery and an explicit user
      // pick may arm an Ollama model; fixed literals still get swept.
      if fixedLiterals.contains(llmModel) {
        llmModel = LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
      }
    case .openAI, .gemini, .none:
      if fixedLiterals.contains(llmModel) || llmModel.isEmpty {
        llmModel = LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
      }
    }
  }

  public var llmModel: String {
    didSet {
      defaults.set(llmModel, forKey: "llmModel")
      onChange?(.llmModel)
    }
  }

  public var ollamaModel: String {
    didSet {
      defaults.set(ollamaModel, forKey: "ollamaModel")
      onChange?(.ollamaModel)
    }
  }

  public var autoCopyToClipboard: Bool {
    didSet {
      defaults.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
      onChange?(.autoCopyToClipboard)
    }
  }

  public var hotkeyEnabled: Bool {
    didSet {
      defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled")
      onChange?(.hotkeyEnabled)
    }
  }

  public var vadAutoStop: Bool {
    didSet {
      defaults.set(vadAutoStop, forKey: "vadAutoStop")
      onChange?(.vadAutoStop)
    }
  }

  public var vadSilenceTimeout: Double {
    didSet {
      defaults.set(vadSilenceTimeout, forKey: "vadSilenceTimeout")
      onChange?(.vadSilenceTimeout)
    }
  }

  public var vadSensitivity: Float {
    didSet {
      defaults.set(vadSensitivity, forKey: "vadSensitivity")
      onChange?(.vadSensitivity)
    }
  }

  public var vadEnergyGate: Bool {
    didSet {
      defaults.set(vadEnergyGate, forKey: "vadEnergyGate")
      onChange?(.vadEnergyGate)
    }
  }

  public var onboardingState: OnboardingState {
    didSet {
      defaults.set(onboardingState.rawValue, forKey: "onboardingState")
      // Keep legacy key in sync so any existing observers see the right value.
      defaults.set(onboardingState == .completed, forKey: "hasCompletedOnboarding")
      // #1176: a durable "ever completed" flag (NEVER reset, unlike the legacy key
      // which a Diagnostics restart flips false). Lets onboarding telemetry label
      // `source` as first_run vs diagnostics_restart in the SHARED settings store.
      if onboardingState == .completed {
        defaults.set(true, forKey: Self.onboardingEverCompletedKey)
      }
      onChange?(.onboardingState)
    }
  }

  static let onboardingEverCompletedKey = "ew.onboarding.everCompleted"

  /// #1176: true once the user has EVER finished onboarding (durable; survives a
  /// Diagnostics restart). Read by the onboarding-abandon `source` label. Backfilled
  /// from the legacy completion key in `init` for users who completed before this key.
  public var onboardingEverCompleted: Bool {
    defaults.bool(forKey: Self.onboardingEverCompletedKey)
  }

  /// Backward-compat computed property — true when onboarding is fully complete.
  public var hasCompletedOnboarding: Bool {
    get { onboardingState == .completed }
    set { onboardingState = newValue ? .completed : .notStarted }
  }

  public var cancelKeyCode: UInt16 {
    didSet {
      defaults.set(Int(cancelKeyCode), forKey: "cancelKeyCode")
      onChange?(.cancelKeyCode)
    }
  }

  public var cancelModifiers: NSEvent.ModifierFlags {
    didSet {
      defaults.set(cancelModifiers.rawValue, forKey: "cancelModifiersRaw")
      onChange?(.cancelModifiers)
    }
  }

  public var toggleKeyCode: UInt16 {
    didSet {
      defaults.set(Int(toggleKeyCode), forKey: "toggleKeyCode")
      onChange?(.toggleKeyCode)
    }
  }

  public var toggleModifiers: NSEvent.ModifierFlags {
    didSet {
      defaults.set(toggleModifiers.rawValue, forKey: "toggleModifiersRaw")
      onChange?(.toggleModifiers)
    }
  }

  public var pushToTalkKeyCode: UInt16 {
    didSet {
      defaults.set(Int(pushToTalkKeyCode), forKey: "pushToTalkKeyCode")
      onChange?(.pushToTalkKeyCode)
    }
  }

  public var pushToTalkModifiers: NSEvent.ModifierFlags {
    didSet {
      defaults.set(pushToTalkModifiers.rawValue, forKey: "pushToTalkModifiersRaw")
      onChange?(.pushToTalkModifiers)
    }
  }

  public var modelUnloadPolicy: ModelUnloadPolicy {
    didSet {
      defaults.set(modelUnloadPolicy.rawValue, forKey: "modelUnloadPolicy")
      onChange?(.modelUnloadPolicy)
    }
  }

  public var restoreClipboardAfterPaste: Bool {
    didSet {
      defaults.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste")
      onChange?(.restoreClipboardAfterPaste)
    }
  }

  public var wordCorrectionEnabled: Bool {
    didSet {
      defaults.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
      onChange?(.wordCorrectionEnabled)
    }
  }

  public var fillerRemovalEnabled: Bool {
    didSet {
      defaults.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled")
      onChange?(.fillerRemovalEnabled)
    }
  }

  /// Opt-in: re-read Contacts on launch and add any new names (#636). Default
  /// OFF. Add-only — never updates or deletes existing terms. Limb: the launch
  /// path never awaits or blocks on it.
  public var contactsSyncOnLaunchEnabled: Bool {
    didSet {
      defaults.set(contactsSyncOnLaunchEnabled, forKey: "contactsSyncOnLaunchEnabled")
      onChange?(.contactsSyncOnLaunchEnabled)
    }
  }

  /// Spoken-emoji conversion toggle (#341). Default ON (#923, founder-ratified
  /// 2026-05-30): safe because the formatter fires only on explicit
  /// "<phrase> emoji" triggers, never sentiment inference. Canonical default in
  /// `SettingsDefaultValues.emojiFormatterEnabled`.
  public var emojiFormatterEnabled: Bool {
    didSet {
      defaults.set(emojiFormatterEnabled, forKey: "emojiFormatterEnabled")
      onChange?(.emojiFormatterEnabled)
    }
  }

  /// Crash-recovery audio safety copy (#1063). Default ON. When on, every
  /// recording is streamed to an encrypted spool that is deleted on a clean
  /// stop and replayed into History after an abnormal exit; off means audio is
  /// never persisted.
  public var crashRecoveryEnabled: Bool {
    didSet {
      defaults.set(crashRecoveryEnabled, forKey: "crashRecoveryEnabled")
      onChange?(.crashRecoveryEnabled)
    }
  }

  public var useStreamingASR: Bool {
    didSet {
      defaults.set(useStreamingASR, forKey: "useStreamingASR")
      onChange?(.useStreamingASR)
    }
  }

  public var warmEnginePolicy: WarmEnginePolicy {
    didSet {
      defaults.set(warmEnginePolicy.rawValue, forKey: "warmEnginePolicy")
      onChange?(.warmEnginePolicy)
    }
  }

  /// Window-appearance preference. UI-only — the app shell applies it to
  /// `NSApp.appearance`; pipeline sync treats `.appearance` as a no-op.
  public var appearancePreference: AppearancePreference {
    didSet {
      defaults.set(appearancePreference.rawValue, forKey: "appearancePreference")
      onChange?(.appearance)
    }
  }

  /// #1341: where the recording pill and status notices appear on screen.
  /// UI-only — read once at fresh-panel-creation time by `RecordingOverlayPanel`,
  /// never live-patched into an already-showing panel; pipeline sync is a no-op.
  public var overlayPillPosition: OverlayPillPosition {
    didSet {
      defaults.set(overlayPillPosition.rawValue, forKey: "overlayPillPosition")
      onChange?(.overlayPillPosition)
    }
  }

  /// #1480: show the once-per-launch Bluetooth cold-start education popover.
  /// UI-only — no pipeline sync; `BluetoothAwarenessPresenter` reads it via the
  /// injected `tipsEnabled` closure and reconciles a visible card off when it
  /// flips to false. Default ON (`SettingsDefaultValues.showBluetoothTips`).
  public var showBluetoothTips: Bool {
    didSet {
      defaults.set(showBluetoothTips, forKey: "showBluetoothTips")
      onChange?(.showBluetoothTips)
    }
  }

  /// #1342: play a short sound when recording starts and stops. UI-only —
  /// no pipeline sync; read live by `RecordingSoundCue` at each cue moment.
  /// Default OFF (`SettingsDefaultValues.playRecordingSounds`).
  public var playRecordingSounds: Bool {
    didSet {
      defaults.set(playRecordingSounds, forKey: "playRecordingSounds")
      onChange?(.playRecordingSounds)
    }
  }

  /// #1342: which original sound pairing plays for the recording start/stop
  /// cue. UI-only — no pipeline sync; snapshotted per-recording by
  /// `RecordingSoundCue`, not read live mid-recording.
  public var recordingSoundPairing: RecordingSoundPairing {
    didSet {
      defaults.set(recordingSoundPairing.rawValue, forKey: "recordingSoundPairing")
      onChange?(.recordingSoundPairing)
    }
  }

  public var isDebugModeEnabled: Bool {
    didSet {
      defaults.set(isDebugModeEnabled, forKey: "isDebugModeEnabled")
      onChange?(.isDebugModeEnabled)
    }
  }

  /// Sticky, founder-controlled opt-in for the DEBUG-only per-dictation audio
  /// archive (#1230). Survives rebuilds/relaunches, unlike the env-var opt-in
  /// (`EW_KEEP_DICTATION_AUDIO`) it ORs with at `DictationAudioArchive.archive()`.
  public var isDictationAudioArchiveEnabled: Bool {
    didSet {
      defaults.set(isDictationAudioArchiveEnabled, forKey: "isDictationAudioArchiveEnabled")
      onChange?(.isDictationAudioArchiveEnabled)
    }
  }

  public var debugLogLevel: DebugLogLevel {
    didSet {
      defaults.set(debugLogLevel.rawValue, forKey: "debugLogLevel")
      onChange?(.debugLogLevel)
    }
  }

  public var useExtendedThinking: Bool {
    didSet {
      defaults.set(useExtendedThinking, forKey: "useExtendedThinking")
      onChange?(.useExtendedThinking)
    }
  }

  /// WhisperKit language code (ISO 639-1). Manual selection, not auto-detect.
  /// EN, DE, TA supported. "en" is default.
  /// Deprecated: superseded by `languageMode` (Multilingual v1). Retained for
  /// one-time migration and will be removed in a later stream.
  public var whisperKitLanguage: String {
    didSet {
      defaults.set(whisperKitLanguage, forKey: "whisperKitLanguage")
      onChange?(.whisperKitLanguage)
    }
  }

  /// Language detection mode (Multilingual v1).
  /// `.auto` is the default. `.locked("xx")` pins to an ISO 639-1 code and
  /// short-circuits the `LanguageDetector`.
  public var languageMode: LanguageMode {
    didSet {
      if let data = try? JSONEncoder().encode(languageMode) {
        defaults.set(data, forKey: "languageMode")
      }
      onChange?(.languageMode)
    }
  }

  public var selectedInputDeviceUID: String {
    didSet {
      defaults.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID")
      onChange?(.selectedInputDeviceUID)
    }
  }

  /// User override for input device. Empty string means "Auto" (smart selection).
  public var preferredInputDeviceIDOverride: String {
    didSet {
      defaults.set(
        preferredInputDeviceIDOverride, forKey: "preferredInputDeviceIDOverride")
      onChange?(.preferredInputDeviceIDOverride)
    }
  }

  #if DEBUG
    /// DEV-ONLY per-build knob (AFM adapter PoC): when ON and EW_AFM_ADAPTER_PATH
    /// is set, on-device Apple Intelligence polish runs through the local
    /// `.fmadapter`. Lets the founder A/B adapter↔stock live on dev builds.
    /// PER-BUILD EXCEPTION (#923): persisted to
    /// `UserDefaults.standard` (the build's own store), excluded from
    /// `unifiedDefaultsKeys` + the #923 migration, NOT in the `SettingKey` enum
    /// (no onChange/telemetry — the connector reads it fresh per dictation).
    /// Compiled out of release entirely.
    public var devAdapterPolishEnabled: Bool {
      didSet {
        UserDefaults.standard.set(devAdapterPolishEnabled, forKey: "devAdapterPolishEnabled")
      }
    }
  #endif

  // MARK: - What's New

  public var lastSeenWhatsNewVersion: String {
    didSet {
      defaults.set(
        lastSeenWhatsNewVersion, forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
      hasUnreadWhatsNew = (lastSeenWhatsNewVersion != WhatsNewConstants.currentContentVersion)
    }
  }

  public private(set) var hasUnreadWhatsNew: Bool

  public func markWhatsNewSeen() {
    guard hasUnreadWhatsNew else { return }
    lastSeenWhatsNewVersion = WhatsNewConstants.currentContentVersion
  }

  // MARK: - Computed Configurations

  public var activePolishInstructions: PolishInstructions { .default }

  /// The model the runtime actually uses for the current provider — the SINGLE
  /// source of truth (#1173). Apple Intelligence is a fixed literal; Ollama reads
  /// `ollamaModel` (its picker-mirrored / discovery-resolved local model); cloud
  /// providers read `llmModel`. `DictationSessionConfigFactory` and the settings
  /// telemetry projection both read THIS, so neither re-derives the model from
  /// raw fields that lag during a provider switch.
  public var effectiveLLMModel: String {
    switch llmProvider {
    case .appleIntelligence: return "apple-intelligence"
    // #1271: fixed literal, the apple-intelligence pattern — Services cannot
    // import the LLM-module manifest; version detail rides eg1.* telemetry.
    case .egOne: return LLMProvider.egOneModelName
    case .ollama: return ollamaModel
    case .openAI, .gemini, .none: return llmModel
    }
  }

  public var isPushToTalk: Bool {
    get { recordingMode == .pushToTalk }
    set { recordingMode = newValue ? .pushToTalk : .toggle }
  }

  /// - Parameter defaults: the store backing all preferences. Pass `nil` (the
  ///   default) for production (resolves to `SettingsDefaults.store`, the
  ///   build-shared suite); tests inject a private suite. `nil` (not a direct
  ///   `SettingsDefaults.store` default arg) keeps the accessor Services-internal.
  public init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? SettingsDefaults.store
    self.defaults = defaults
    // #1176: backfill the durable everCompleted flag for users who completed
    // onboarding before it existed — runs at launch, BEFORE any Diagnostics restart
    // resets the legacy key, so their first restart still reads diagnostics_restart.
    if !defaults.bool(forKey: Self.onboardingEverCompletedKey),
      defaults.bool(forKey: "hasCompletedOnboarding")
    {
      defaults.set(true, forKey: Self.onboardingEverCompletedKey)
    }
    selectedBackend =
      ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "")
      ?? SettingsDefaultValues.selectedBackend
    recordingMode =
      RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "")
      ?? SettingsDefaultValues.recordingMode
    let resolvedProvider =
      LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "")
      ?? SettingsDefaultValues.llmProvider
    llmProvider = resolvedProvider
    // Seed the remembered engine. If the key is already stored, honor it.
    // Otherwise seed from the resolved provider (existing users keep their
    // engine as the restore target) or the default when that is off. Write
    // through explicitly: `didSet` does not fire on init assignment, so
    // without this an upgrading user who toggles off then quits before ever
    // switching engines would lose their remembered engine (#1285).
    let seededLastProvider =
      LLMProvider(rawValue: defaults.string(forKey: "lastLLMProvider") ?? "")
      ?? (resolvedProvider != .none ? resolvedProvider : SettingsDefaultValues.lastLLMProvider)
    lastLLMProvider = seededLastProvider
    defaults.set(seededLastProvider.rawValue, forKey: "lastLLMProvider")
    llmModel = defaults.string(forKey: "llmModel") ?? LLMProvider.defaultModel(for: .openAI)
    ollamaModel = defaults.string(forKey: "ollamaModel") ?? SettingsDefaultValues.ollamaModel
    autoCopyToClipboard =
      defaults.object(forKey: "autoCopyToClipboard") as? Bool
      ?? SettingsDefaultValues.autoCopyToClipboard
    hotkeyEnabled = SettingsDefaultValues.hotkeyEnabled  // toggle removed; always enabled
    vadAutoStop =
      defaults.object(forKey: "vadAutoStop") as? Bool ?? SettingsDefaultValues.vadAutoStop
    vadSilenceTimeout =
      defaults.object(forKey: "vadSilenceTimeout") as? Double
      ?? SettingsDefaultValues.vadSilenceTimeout
    vadSensitivity =
      defaults.object(forKey: "vadSensitivity") as? Float ?? SettingsDefaultValues.vadSensitivity
    vadEnergyGate =
      defaults.object(forKey: "vadEnergyGate") as? Bool ?? SettingsDefaultValues.vadEnergyGate
    // Migrate legacy hasCompletedOnboarding Bool → OnboardingState enum.
    // If the new "onboardingState" key exists, use it directly.
    // Otherwise, fall back to the old Bool (existing users → .completed).
    if let rawState = defaults.string(forKey: "onboardingState"),
      let state = OnboardingState(rawValue: rawState)
    {
      onboardingState = state
    } else if defaults.object(forKey: "hasCompletedOnboarding") as? Bool == true {
      onboardingState = .completed
    } else {
      onboardingState = .notStarted
    }

    let savedCancelKeyCode = defaults.object(forKey: "cancelKeyCode") as? Int
    cancelKeyCode = UInt16(savedCancelKeyCode ?? SettingsDefaultValues.cancelKeyCode)

    let savedCancelModRaw = defaults.object(forKey: "cancelModifiersRaw") as? UInt
    cancelModifiers = NSEvent.ModifierFlags(
      rawValue: savedCancelModRaw ?? SettingsDefaultValues.cancelModifiersRaw)

    let savedToggleKeyCode = defaults.object(forKey: "toggleKeyCode") as? Int
    toggleKeyCode = UInt16(savedToggleKeyCode ?? SettingsDefaultValues.toggleKeyCode)

    let savedToggleModRaw = defaults.object(forKey: "toggleModifiersRaw") as? UInt
    toggleModifiers = NSEvent.ModifierFlags(
      rawValue: savedToggleModRaw ?? SettingsDefaultValues.toggleModifiersRaw)

    // PTT migration: old modifier-only → new key+modifier format
    let legacyPTTModRaw = defaults.object(forKey: "pushToTalkModifierRaw") as? UInt
    if let legacyMod = legacyPTTModRaw, defaults.object(forKey: "pushToTalkKeyCode") == nil {
      // Migrate old-style modifier-only PTT to modifier+Space
      pushToTalkKeyCode = UInt16(SettingsDefaultValues.pushToTalkKeyCode)  // Space
      pushToTalkModifiers = NSEvent.ModifierFlags(rawValue: legacyMod)
      defaults.set(SettingsDefaultValues.pushToTalkKeyCode, forKey: "pushToTalkKeyCode")
      defaults.set(legacyMod, forKey: "pushToTalkModifiersRaw")
      defaults.removeObject(forKey: "pushToTalkModifierRaw")
      defaults.removeObject(forKey: "pushToTalkModifierKeyCode")
    } else {
      let savedPTTKeyCode = defaults.object(forKey: "pushToTalkKeyCode") as? Int
      pushToTalkKeyCode = UInt16(savedPTTKeyCode ?? SettingsDefaultValues.pushToTalkKeyCode)
      let savedPTTModRaw = defaults.object(forKey: "pushToTalkModifiersRaw") as? UInt
      pushToTalkModifiers = NSEvent.ModifierFlags(
        rawValue: savedPTTModRaw ?? SettingsDefaultValues.pushToTalkModifiersRaw)
    }

    modelUnloadPolicy =
      ModelUnloadPolicy(
        rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
      ) ?? SettingsDefaultValues.modelUnloadPolicy
    restoreClipboardAfterPaste =
      defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool
      ?? SettingsDefaultValues.restoreClipboardAfterPaste
    wordCorrectionEnabled =
      defaults.object(forKey: "wordCorrectionEnabled") as? Bool
      ?? SettingsDefaultValues.wordCorrectionEnabled
    fillerRemovalEnabled =
      defaults.object(forKey: "fillerRemovalEnabled") as? Bool
      ?? SettingsDefaultValues.fillerRemovalEnabled
    contactsSyncOnLaunchEnabled =
      defaults.object(forKey: "contactsSyncOnLaunchEnabled") as? Bool
      ?? SettingsDefaultValues.contactsSyncOnLaunchEnabled
    emojiFormatterEnabled =
      defaults.object(forKey: "emojiFormatterEnabled") as? Bool
      ?? SettingsDefaultValues.emojiFormatterEnabled
    crashRecoveryEnabled =
      defaults.object(forKey: "crashRecoveryEnabled") as? Bool
      ?? SettingsDefaultValues.crashRecoveryEnabled
    isDebugModeEnabled =
      defaults.object(forKey: "isDebugModeEnabled") as? Bool
      ?? SettingsDefaultValues.isDebugModeEnabled
    isDictationAudioArchiveEnabled =
      defaults.object(forKey: "isDictationAudioArchiveEnabled") as? Bool
      ?? SettingsDefaultValues.isDictationAudioArchiveEnabled
    debugLogLevel =
      DebugLogLevel(
        rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
      ) ?? SettingsDefaultValues.debugLogLevel
    useExtendedThinking =
      defaults.object(forKey: "useExtendedThinking") as? Bool
      ?? SettingsDefaultValues.useExtendedThinking
    whisperKitLanguage =
      defaults.string(forKey: "whisperKitLanguage") ?? SettingsDefaultValues.whisperKitLanguage
    // Load languageMode, or migrate from whisperKitLanguage on first launch
    // (Multilingual v1). Both paths normalize (lowercase) and validate against
    // the Whisper-supported 99-lang set; unsupported, empty, or case-variant
    // codes fall back to .auto so a stale or bogus persisted value cannot
    // lock the user into a non-existent language.
    let resolvedLanguageMode: LanguageMode = {
      let validate: (LanguageMode) -> LanguageMode = { mode in
        switch mode {
        case .auto:
          return .auto
        case .locked(let code):
          let normalized = code.lowercased()
          guard !normalized.isEmpty, LanguageTypes.isSupported(normalized) else {
            return .auto
          }
          return .locked(normalized)
        }
      }
      if let data = defaults.data(forKey: "languageMode"),
        let decoded = try? JSONDecoder().decode(LanguageMode.self, from: data)
      {
        return validate(decoded)
      }
      let legacy = (defaults.string(forKey: "whisperKitLanguage") ?? "en").lowercased()
      let migrated: LanguageMode
      if legacy.isEmpty || legacy == "en" || !LanguageTypes.isSupported(legacy) {
        migrated = .auto
      } else {
        migrated = .locked(legacy)
      }
      if let encoded = try? JSONEncoder().encode(migrated) {
        defaults.set(encoded, forKey: "languageMode")
      }
      return migrated
    }()
    languageMode = resolvedLanguageMode
    selectedInputDeviceUID =
      defaults.string(forKey: "selectedInputDeviceUID")
      ?? SettingsDefaultValues.selectedInputDeviceUID
    preferredInputDeviceIDOverride =
      defaults.string(forKey: "preferredInputDeviceIDOverride")
      ?? SettingsDefaultValues.preferredInputDeviceIDOverride
    #if DEBUG
      // PER-BUILD EXCEPTION (#923): AFM adapter PoC dev knob, read from the
      // build's own store, default ON. Stays out of unifiedDefaultsKeys + the
      // migration. Compiled out of release.
      devAdapterPolishEnabled =
        UserDefaults.standard.object(forKey: "devAdapterPolishEnabled") as? Bool ?? true
    #endif

    // Migration (issue #614, 2026-05-04): the Formal/Standard/Friendly preset axis and the
    // hidden custom-prompt path were removed. Drop their orphaned UserDefaults keys so the
    // next load is clean. Idempotent: removeObject on an absent key is a no-op.
    defaults.removeObject(forKey: "writingStylePreset")
    defaults.removeObject(forKey: "customSystemPrompt")
    // Migration (issue #734, 2026-05-15): noise-suppression toggle removed. Apple Voice
    // Processing was hostile to dictation accuracy and engine stability. Drop the persisted
    // key so existing users with `noiseSuppression=true` are migrated to raw audio on first
    // launch after upgrade. Idempotent: removeObject on an absent key is a no-op.
    defaults.removeObject(forKey: "noiseSuppression")
    useStreamingASR =
      defaults.object(forKey: "useStreamingASR") as? Bool ?? SettingsDefaultValues.useStreamingASR
    warmEnginePolicy =
      WarmEnginePolicy(
        rawValue: defaults.string(forKey: "warmEnginePolicy") ?? ""
      ) ?? SettingsDefaultValues.warmEnginePolicy

    appearancePreference =
      AppearancePreference(
        rawValue: defaults.string(forKey: "appearancePreference") ?? ""
      ) ?? SettingsDefaultValues.appearancePreference

    overlayPillPosition =
      OverlayPillPosition(
        rawValue: defaults.string(forKey: "overlayPillPosition") ?? ""
      ) ?? SettingsDefaultValues.overlayPillPosition

    showBluetoothTips =
      defaults.object(forKey: "showBluetoothTips") as? Bool
      ?? SettingsDefaultValues.showBluetoothTips

    playRecordingSounds =
      defaults.object(forKey: "playRecordingSounds") as? Bool
      ?? SettingsDefaultValues.playRecordingSounds

    recordingSoundPairing =
      RecordingSoundPairing(
        rawValue: defaults.string(forKey: "recordingSoundPairing") ?? ""
      ) ?? SettingsDefaultValues.recordingSoundPairing

    // What's New: fresh install (nil) defaults to current version so new users aren't badged.
    let storedWhatsNew =
      defaults.string(forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
      ?? WhatsNewConstants.currentContentVersion
    lastSeenWhatsNewVersion = storedWhatsNew
    hasUnreadWhatsNew = (storedWhatsNew != WhatsNewConstants.currentContentVersion)

    // Canonicalize provider-coupled model names after all properties are loaded.
    canonicalizeLLMModelForProvider()
  }

  /// Apply discovered models from async discovery. SettingsManager decides whether to update.
  /// - Parameters:
  ///   - models: Models returned by the provider's API.
  ///   - provider: The provider these models belong to. Stale results (user already switched) are dropped.
  public func applyDiscoveredModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
    guard provider == llmProvider else { return }
    // System write (#1173): the model/ollamaModel mutations below are an
    // auto-correction, not a user pick — tag their deltas `source=system`. The
    // flag covers the full body (incl. the early-return `models.isEmpty` path)
    // via `defer`.
    isApplyingSystemWrite = true
    defer { isApplyingSystemWrite = false }
    if models.isEmpty {
      // #1305: for Ollama, empty discovery means NOTHING is installed — arming
      // the remembered `ollamaModel` name here was the root cause of the
      // phantom-model bug (a picker selection and dictation model no /api/tags
      // list contains). "" is the explicit "nothing armed" state the picker
      // already renders as "No models found". `ollamaModel` (the remembered
      // preference) DELIBERATELY stays untouched — it powers the
      // Download-suggestion copy, and although `effectiveLLMModel` keeps
      // returning it for dictation configs, every polish attempt is guarded by
      // the readiness preflight in `LLMPolishStep` (the stale name probes as
      // model-missing and skips instantly); dictation-time truth is owned by
      // that gate, not by clearing this field. Cloud providers keep the
      // default-fill (their catalogs are never legitimately empty; an empty
      // result is a discovery hiccup).
      llmModel =
        llmProvider == .ollama
        ? ""
        : LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
      return
    }
    if !models.contains(where: { $0.id == llmModel && $0.isAvailable }) {
      if let first = models.first(where: { $0.isAvailable }) {
        llmModel = first.id
        if provider == .ollama { ollamaModel = first.id }
      }
    }
  }
}
