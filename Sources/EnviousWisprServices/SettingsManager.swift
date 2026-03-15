import AppKit
import EnviousWisprCore

@MainActor
@Observable
public final class SettingsManager {
    public enum SettingKey {
        case selectedBackend
        case whisperKitModel
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
        case hasCompletedOnboarding   // Legacy — kept for backward-compat writes only
        case cancelKeyCode
        case cancelModifiers
        case toggleKeyCode
        case toggleModifiers
        case pushToTalkKeyCode
        case pushToTalkModifiers
        case modelUnloadPolicy
        case restoreClipboardAfterPaste
        case customSystemPrompt
        case wordCorrectionEnabled
        case fillerRemovalEnabled
        case isDebugModeEnabled
        case debugLogLevel
        case useExtendedThinking
        case whisperKitLanguage
        case selectedInputDeviceUID
        case noiseSuppression
        case preferredInputDeviceIDOverride
        case environmentPreset
        case writingStylePreset
        case useXPCAudioService
    }

    public var onChange: ((SettingKey) -> Void)?

    public var selectedBackend: ASRBackendType {
        didSet {
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selectedBackend")
            onChange?(.selectedBackend)
        }
    }

    public var whisperKitModel: String {
        didSet {
            UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
            onChange?(.whisperKitModel)
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
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
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

    public var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
            onChange?(.customSystemPrompt)
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
    public var whisperKitLanguage: String {
        didSet {
            UserDefaults.standard.set(whisperKitLanguage, forKey: "whisperKitLanguage")
            onChange?(.whisperKitLanguage)
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
            UserDefaults.standard.set(preferredInputDeviceIDOverride, forKey: "preferredInputDeviceIDOverride")
            onChange?(.preferredInputDeviceIDOverride)
        }
    }

    public var environmentPreset: EnvironmentPreset {
        didSet {
            UserDefaults.standard.set(environmentPreset.rawValue, forKey: "environmentPreset")
            onChange?(.environmentPreset)
        }
    }

    public var writingStylePreset: WritingStylePreset {
        didSet {
            UserDefaults.standard.set(writingStylePreset.rawValue, forKey: "writingStylePreset")
            onChange?(.writingStylePreset)
        }
    }

    /// Use XPC audio service instead of in-process AudioCaptureManager.
    /// Cold flag — read at launch only. Changing requires app restart.
    /// Toggle via: defaults write com.enviouswispr.app.dev useXPCAudioService -bool true
    /// Does NOT fire onChange — this is not a live-switchable setting.
    public var useXPCAudioService: Bool {
        didSet {
            UserDefaults.standard.set(useXPCAudioService, forKey: "useXPCAudioService")
        }
    }

    public var activePolishInstructions: PolishInstructions {
        switch writingStylePreset {
        case .formal:
            return PolishInstructions(systemPrompt: PromptPreset.formal.systemPrompt)
        case .standard:
            return .default
        case .friendly:
            return PolishInstructions(systemPrompt: PromptPreset.casual.systemPrompt)
        case .custom:
            // Legacy: if someone had a custom prompt saved, honor it
            let trimmed = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .default : .custom(systemPrompt: customSystemPrompt)
        }
    }

    public var isPushToTalk: Bool {
        get { recordingMode == .pushToTalk }
        set { recordingMode = newValue ? .pushToTalk : .toggle }
    }

    public init() {
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        whisperKitModel = defaults.string(forKey: "whisperKitModel") ?? "openai_whisper-large-v3_turbo"
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
        llmModel = defaults.string(forKey: "llmModel") ?? "gpt-4o-mini"
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
           let state = OnboardingState(rawValue: rawState) {
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
        toggleKeyCode = UInt16(savedToggleKeyCode ?? 49)

        let savedToggleModRaw = defaults.object(forKey: "toggleModifiersRaw") as? UInt
        toggleModifiers = NSEvent.ModifierFlags(rawValue: savedToggleModRaw ?? NSEvent.ModifierFlags.control.rawValue)

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
            pushToTalkModifiers = NSEvent.ModifierFlags(rawValue: savedPTTModRaw ?? NSEvent.ModifierFlags.option.rawValue)
        }

        modelUnloadPolicy = ModelUnloadPolicy(
            rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
        ) ?? .never
        restoreClipboardAfterPaste = defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? false
        customSystemPrompt = defaults.string(forKey: "customSystemPrompt") ?? ""
        wordCorrectionEnabled = defaults.object(forKey: "wordCorrectionEnabled") as? Bool ?? true
        fillerRemovalEnabled = defaults.object(forKey: "fillerRemovalEnabled") as? Bool ?? true
        isDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled") as? Bool ?? false
        debugLogLevel = DebugLogLevel(
            rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
        ) ?? .info
        useExtendedThinking = defaults.object(forKey: "useExtendedThinking") as? Bool ?? false
        whisperKitLanguage = defaults.string(forKey: "whisperKitLanguage") ?? "en"
        selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID") ?? ""
        noiseSuppression = defaults.object(forKey: "noiseSuppression") as? Bool ?? false
        preferredInputDeviceIDOverride = defaults.string(forKey: "preferredInputDeviceIDOverride") ?? ""
        environmentPreset = EnvironmentPreset(rawValue: defaults.string(forKey: "environmentPreset") ?? "") ?? .normal
        writingStylePreset = WritingStylePreset(rawValue: defaults.string(forKey: "writingStylePreset") ?? "") ?? .standard
        useXPCAudioService = defaults.object(forKey: "useXPCAudioService") as? Bool ?? false
    }
}
