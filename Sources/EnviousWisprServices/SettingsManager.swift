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
    case isDebugModeEnabled
    case debugLogLevel
    case useExtendedThinking
    case whisperKitLanguage
    case languageMode
    case selectedInputDeviceUID
    case noiseSuppression
    case preferredInputDeviceIDOverride
    case environmentPreset
    case useXPCAudioService
    case useStreamingASR
    case warmEnginePolicy
  }

  public var onChange: ((SettingKey) -> Void)?

  public var selectedBackend: ASRBackendType {
    didSet {
      UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selectedBackend")
      onChange?(.selectedBackend)
    }
  }

  public var recordingMode: RecordingMode {
    didSet {
      UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
      onChange?(.recordingMode)
    }
  }

  public var llmProvider: LLMProvider {
    didSet {
      if oldValue != llmProvider {
        TelemetryService.shared.providerChanged(from: oldValue.rawValue, to: llmProvider.rawValue)
      }
      UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
      // Canonicalize model for the new provider
      if llmProvider == .appleIntelligence {
        llmModel = "apple-intelligence"
      } else if llmModel == "apple-intelligence" || llmModel.isEmpty {
        llmModel = LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
      }
      onChange?(.llmProvider)
    }
  }

  public var llmModel: String {
    didSet {
      UserDefaults.standard.set(llmModel, forKey: "llmModel")
      onChange?(.llmModel)
    }
  }

  public var ollamaModel: String {
    didSet {
      UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
      onChange?(.ollamaModel)
    }
  }

  public var autoCopyToClipboard: Bool {
    didSet {
      UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
      onChange?(.autoCopyToClipboard)
    }
  }

  public var hotkeyEnabled: Bool {
    didSet {
      UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
      onChange?(.hotkeyEnabled)
    }
  }

  public var vadAutoStop: Bool {
    didSet {
      UserDefaults.standard.set(vadAutoStop, forKey: "vadAutoStop")
      onChange?(.vadAutoStop)
    }
  }

  public var vadSilenceTimeout: Double {
    didSet {
      UserDefaults.standard.set(vadSilenceTimeout, forKey: "vadSilenceTimeout")
      onChange?(.vadSilenceTimeout)
    }
  }

  public var vadSensitivity: Float {
    didSet {
      UserDefaults.standard.set(vadSensitivity, forKey: "vadSensitivity")
      onChange?(.vadSensitivity)
    }
  }

  public var vadEnergyGate: Bool {
    didSet {
      UserDefaults.standard.set(vadEnergyGate, forKey: "vadEnergyGate")
      onChange?(.vadEnergyGate)
    }
  }

  public var onboardingState: OnboardingState {
    didSet {
      UserDefaults.standard.set(onboardingState.rawValue, forKey: "onboardingState")
      // Keep legacy key in sync so any existing observers see the right value.
      UserDefaults.standard.set(onboardingState == .completed, forKey: "hasCompletedOnboarding")
      onChange?(.onboardingState)
    }
  }

  /// Backward-compat computed property — true when onboarding is fully complete.
  public var hasCompletedOnboarding: Bool {
    get { onboardingState == .completed }
    set { onboardingState = newValue ? .completed : .notStarted }
  }

  public var cancelKeyCode: UInt16 {
    didSet {
      UserDefaults.standard.set(Int(cancelKeyCode), forKey: "cancelKeyCode")
      onChange?(.cancelKeyCode)
    }
  }

  public var cancelModifiers: NSEvent.ModifierFlags {
    didSet {
      UserDefaults.standard.set(cancelModifiers.rawValue, forKey: "cancelModifiersRaw")
      onChange?(.cancelModifiers)
    }
  }

  public var toggleKeyCode: UInt16 {
    didSet {
      UserDefaults.standard.set(Int(toggleKeyCode), forKey: "toggleKeyCode")
      onChange?(.toggleKeyCode)
    }
  }

  public var toggleModifiers: NSEvent.ModifierFlags {
    didSet {
      UserDefaults.standard.set(toggleModifiers.rawValue, forKey: "toggleModifiersRaw")
      onChange?(.toggleModifiers)
    }
  }

  public var pushToTalkKeyCode: UInt16 {
    didSet {
      UserDefaults.standard.set(Int(pushToTalkKeyCode), forKey: "pushToTalkKeyCode")
      onChange?(.pushToTalkKeyCode)
    }
  }

  public var pushToTalkModifiers: NSEvent.ModifierFlags {
    didSet {
      UserDefaults.standard.set(pushToTalkModifiers.rawValue, forKey: "pushToTalkModifiersRaw")
      onChange?(.pushToTalkModifiers)
    }
  }

  public var modelUnloadPolicy: ModelUnloadPolicy {
    didSet {
      UserDefaults.standard.set(modelUnloadPolicy.rawValue, forKey: "modelUnloadPolicy")
      onChange?(.modelUnloadPolicy)
    }
  }

  public var restoreClipboardAfterPaste: Bool {
    didSet {
      UserDefaults.standard.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste")
      onChange?(.restoreClipboardAfterPaste)
    }
  }

  public var wordCorrectionEnabled: Bool {
    didSet {
      UserDefaults.standard.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
      onChange?(.wordCorrectionEnabled)
    }
  }

  public var fillerRemovalEnabled: Bool {
    didSet {
      UserDefaults.standard.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled")
      onChange?(.fillerRemovalEnabled)
    }
  }

  public var useStreamingASR: Bool {
    didSet {
      UserDefaults.standard.set(useStreamingASR, forKey: "useStreamingASR")
      onChange?(.useStreamingASR)
    }
  }

  public var warmEnginePolicy: WarmEnginePolicy {
    didSet {
      UserDefaults.standard.set(warmEnginePolicy.rawValue, forKey: "warmEnginePolicy")
      onChange?(.warmEnginePolicy)
    }
  }

  public var isDebugModeEnabled: Bool {
    didSet {
      UserDefaults.standard.set(isDebugModeEnabled, forKey: "isDebugModeEnabled")
      onChange?(.isDebugModeEnabled)
    }
  }

  public var debugLogLevel: DebugLogLevel {
    didSet {
      UserDefaults.standard.set(debugLogLevel.rawValue, forKey: "debugLogLevel")
      onChange?(.debugLogLevel)
    }
  }

  public var useExtendedThinking: Bool {
    didSet {
      UserDefaults.standard.set(useExtendedThinking, forKey: "useExtendedThinking")
      onChange?(.useExtendedThinking)
    }
  }

  /// WhisperKit language code (ISO 639-1). Manual selection, not auto-detect.
  /// EN, DE, TA supported. "en" is default.
  /// Deprecated: superseded by `languageMode` (Multilingual v1). Retained for
  /// one-time migration and will be removed in a later stream.
  public var whisperKitLanguage: String {
    didSet {
      UserDefaults.standard.set(whisperKitLanguage, forKey: "whisperKitLanguage")
      onChange?(.whisperKitLanguage)
    }
  }

  /// Language detection mode (Multilingual v1).
  /// `.auto` is the default. `.locked("xx")` pins to an ISO 639-1 code and
  /// short-circuits the `LanguageDetector`.
  public var languageMode: LanguageMode {
    didSet {
      if let data = try? JSONEncoder().encode(languageMode) {
        UserDefaults.standard.set(data, forKey: "languageMode")
      }
      onChange?(.languageMode)
    }
  }

  public var selectedInputDeviceUID: String {
    didSet {
      UserDefaults.standard.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID")
      onChange?(.selectedInputDeviceUID)
    }
  }

  public var noiseSuppression: Bool {
    didSet {
      UserDefaults.standard.set(noiseSuppression, forKey: "noiseSuppression")
      onChange?(.noiseSuppression)
    }
  }

  /// User override for input device. Empty string means "Auto" (smart selection).
  public var preferredInputDeviceIDOverride: String {
    didSet {
      UserDefaults.standard.set(
        preferredInputDeviceIDOverride, forKey: "preferredInputDeviceIDOverride")
      onChange?(.preferredInputDeviceIDOverride)
    }
  }

  public var environmentPreset: EnvironmentPreset {
    didSet {
      UserDefaults.standard.set(environmentPreset.rawValue, forKey: "environmentPreset")
      onChange?(.environmentPreset)
    }
  }

  /// Use XPC audio service instead of in-process AudioCaptureManager.
  /// Default: true (Step 7 — XPC is the standard path).
  /// Cold flag — read at launch only. Changing requires app restart.
  /// Escape hatch: defaults write com.enviouswispr.app.dev useXPCAudioService -bool false
  /// Does NOT fire onChange — this is not a live-switchable setting.
  public var useXPCAudioService: Bool {
    didSet {
      UserDefaults.standard.set(useXPCAudioService, forKey: "useXPCAudioService")
    }
  }

  // MARK: - What's New

  public var lastSeenWhatsNewVersion: String {
    didSet {
      UserDefaults.standard.set(
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

  public var isPushToTalk: Bool {
    get { recordingMode == .pushToTalk }
    set { recordingMode = newValue ? .pushToTalk : .toggle }
  }

  public init() {
    let defaults = UserDefaults.standard
    selectedBackend =
      ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
    recordingMode =
      RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
    llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
    llmModel = defaults.string(forKey: "llmModel") ?? LLMProvider.defaultModel(for: .openAI)
    ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
    autoCopyToClipboard = defaults.object(forKey: "autoCopyToClipboard") as? Bool ?? true
    hotkeyEnabled = true  // toggle removed; always enabled
    vadAutoStop = defaults.object(forKey: "vadAutoStop") as? Bool ?? false
    vadSilenceTimeout = defaults.object(forKey: "vadSilenceTimeout") as? Double ?? 1.5
    vadSensitivity = defaults.object(forKey: "vadSensitivity") as? Float ?? 0.5
    vadEnergyGate = defaults.object(forKey: "vadEnergyGate") as? Bool ?? true
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
    cancelKeyCode = UInt16(savedCancelKeyCode ?? 53)

    let savedCancelModRaw = defaults.object(forKey: "cancelModifiersRaw") as? UInt
    cancelModifiers = NSEvent.ModifierFlags(rawValue: savedCancelModRaw ?? 0)

    let savedToggleKeyCode = defaults.object(forKey: "toggleKeyCode") as? Int
    toggleKeyCode = UInt16(savedToggleKeyCode ?? Int(ModifierKeyCodes.rightOption))

    let savedToggleModRaw = defaults.object(forKey: "toggleModifiersRaw") as? UInt
    toggleModifiers = NSEvent.ModifierFlags(rawValue: savedToggleModRaw ?? 0)

    // PTT migration: old modifier-only → new key+modifier format
    let legacyPTTModRaw = defaults.object(forKey: "pushToTalkModifierRaw") as? UInt
    if let legacyMod = legacyPTTModRaw, defaults.object(forKey: "pushToTalkKeyCode") == nil {
      // Migrate old-style modifier-only PTT to modifier+Space
      pushToTalkKeyCode = 49  // Space
      pushToTalkModifiers = NSEvent.ModifierFlags(rawValue: legacyMod)
      defaults.set(49, forKey: "pushToTalkKeyCode")
      defaults.set(legacyMod, forKey: "pushToTalkModifiersRaw")
      defaults.removeObject(forKey: "pushToTalkModifierRaw")
      defaults.removeObject(forKey: "pushToTalkModifierKeyCode")
    } else {
      let savedPTTKeyCode = defaults.object(forKey: "pushToTalkKeyCode") as? Int
      pushToTalkKeyCode = UInt16(savedPTTKeyCode ?? 49)
      let savedPTTModRaw = defaults.object(forKey: "pushToTalkModifiersRaw") as? UInt
      pushToTalkModifiers = NSEvent.ModifierFlags(
        rawValue: savedPTTModRaw ?? NSEvent.ModifierFlags.option.rawValue)
    }

    modelUnloadPolicy =
      ModelUnloadPolicy(
        rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
      ) ?? .never
    restoreClipboardAfterPaste =
      defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? true
    wordCorrectionEnabled = defaults.object(forKey: "wordCorrectionEnabled") as? Bool ?? true
    fillerRemovalEnabled = defaults.object(forKey: "fillerRemovalEnabled") as? Bool ?? true
    isDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled") as? Bool ?? false
    debugLogLevel =
      DebugLogLevel(
        rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
      ) ?? .info
    useExtendedThinking = defaults.object(forKey: "useExtendedThinking") as? Bool ?? false
    whisperKitLanguage = defaults.string(forKey: "whisperKitLanguage") ?? "en"
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
    selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID") ?? ""
    noiseSuppression = false
    preferredInputDeviceIDOverride = defaults.string(forKey: "preferredInputDeviceIDOverride") ?? ""
    environmentPreset =
      EnvironmentPreset(rawValue: defaults.string(forKey: "environmentPreset") ?? "") ?? .normal
    useXPCAudioService = defaults.object(forKey: "useXPCAudioService") as? Bool ?? true

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
    useStreamingASR = defaults.object(forKey: "useStreamingASR") as? Bool ?? false
    warmEnginePolicy =
      WarmEnginePolicy(
        rawValue: defaults.string(forKey: "warmEnginePolicy") ?? ""
      ) ?? .seconds30

    // What's New: fresh install (nil) defaults to current version so new users aren't badged.
    let storedWhatsNew =
      defaults.string(forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
      ?? WhatsNewConstants.currentContentVersion
    lastSeenWhatsNewVersion = storedWhatsNew
    hasUnreadWhatsNew = (storedWhatsNew != WhatsNewConstants.currentContentVersion)

    // Canonicalize provider-coupled model names after all properties are loaded.
    if llmProvider == .appleIntelligence {
      llmModel = "apple-intelligence"
    } else if llmModel == "apple-intelligence" || llmModel.isEmpty {
      llmModel = LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
    }
  }

  /// Apply discovered models from async discovery. SettingsManager decides whether to update.
  /// - Parameters:
  ///   - models: Models returned by the provider's API.
  ///   - provider: The provider these models belong to. Stale results (user already switched) are dropped.
  public func applyDiscoveredModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
    guard provider == llmProvider else { return }
    if models.isEmpty {
      llmModel = LLMProvider.defaultModel(for: llmProvider, ollamaModel: ollamaModel)
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
