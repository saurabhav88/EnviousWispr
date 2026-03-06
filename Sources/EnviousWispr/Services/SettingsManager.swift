import AppKit

/// Tracks which onboarding step the user has reached.
/// Raw values are legacy UserDefaults strings — do NOT change them.
enum OnboardingState: String, Codable, Sendable {
    case notStarted       = "needsMicPermission"
    case settingUp        = "needsModelDownload"
    case needsPermissions = "needsCompletion"
    case completed        = "completed"
}

enum EnvironmentPreset: String, CaseIterable, Codable, Sendable {
    case quiet = "quiet"
    case normal = "normal"
    case noisy = "noisy"

    var vadSensitivity: Float {
        switch self {
        case .quiet: return 0.8
        case .normal: return 0.5
        case .noisy: return 0.2
        }
    }
}

enum WritingStylePreset: String, CaseIterable, Codable, Sendable {
    case formal = "formal"
    case standard = "standard"
    case friendly = "friendly"
    case custom = "custom"
}

@MainActor
@Observable
final class SettingsManager {
    enum SettingKey {
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
        case whisperKitLanguageAutoDetect
        case selectedInputDeviceUID
        case noiseSuppression
        case preferredInputDeviceIDOverride
        case environmentPreset
        case writingStylePreset
    }

    var onChange: ((SettingKey) -> Void)?

    var selectedBackend: ASRBackendType {
        didSet {
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "selectedBackend")
            onChange?(.selectedBackend)
        }
    }

    var whisperKitModel: String {
        didSet {
            UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
            onChange?(.whisperKitModel)
        }
    }

    var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode")
            onChange?(.recordingMode)
        }
    }

    var llmProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider")
            onChange?(.llmProvider)
        }
    }

    var llmModel: String {
        didSet {
            UserDefaults.standard.set(llmModel, forKey: "llmModel")
            onChange?(.llmModel)
        }
    }

    var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
            onChange?(.ollamaModel)
        }
    }

    var autoCopyToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
            onChange?(.autoCopyToClipboard)
        }
    }

    var hotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
            onChange?(.hotkeyEnabled)
        }
    }

    var vadAutoStop: Bool {
        didSet {
            UserDefaults.standard.set(vadAutoStop, forKey: "vadAutoStop")
            onChange?(.vadAutoStop)
        }
    }

    var vadSilenceTimeout: Double {
        didSet {
            UserDefaults.standard.set(vadSilenceTimeout, forKey: "vadSilenceTimeout")
            onChange?(.vadSilenceTimeout)
        }
    }

    var vadSensitivity: Float {
        didSet {
            UserDefaults.standard.set(vadSensitivity, forKey: "vadSensitivity")
            onChange?(.vadSensitivity)
        }
    }

    var vadEnergyGate: Bool {
        didSet {
            UserDefaults.standard.set(vadEnergyGate, forKey: "vadEnergyGate")
            onChange?(.vadEnergyGate)
        }
    }

    var onboardingState: OnboardingState {
        didSet {
            UserDefaults.standard.set(onboardingState.rawValue, forKey: "onboardingState")
            // Keep legacy key in sync so any existing observers see the right value.
            UserDefaults.standard.set(onboardingState == .completed, forKey: "hasCompletedOnboarding")
            onChange?(.onboardingState)
        }
    }

    /// Backward-compat computed property — true when onboarding is fully complete.
    var hasCompletedOnboarding: Bool {
        get { onboardingState == .completed }
        set { onboardingState = newValue ? .completed : .notStarted }
    }

    var cancelKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(cancelKeyCode), forKey: "cancelKeyCode")
            onChange?(.cancelKeyCode)
        }
    }

    var cancelModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(cancelModifiers.rawValue, forKey: "cancelModifiersRaw")
            onChange?(.cancelModifiers)
        }
    }

    var toggleKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(toggleKeyCode), forKey: "toggleKeyCode")
            onChange?(.toggleKeyCode)
        }
    }

    var toggleModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(toggleModifiers.rawValue, forKey: "toggleModifiersRaw")
            onChange?(.toggleModifiers)
        }
    }

    var pushToTalkKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(pushToTalkKeyCode), forKey: "pushToTalkKeyCode")
            onChange?(.pushToTalkKeyCode)
        }
    }

    var pushToTalkModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(pushToTalkModifiers.rawValue, forKey: "pushToTalkModifiersRaw")
            onChange?(.pushToTalkModifiers)
        }
    }

    var modelUnloadPolicy: ModelUnloadPolicy {
        didSet {
            UserDefaults.standard.set(modelUnloadPolicy.rawValue, forKey: "modelUnloadPolicy")
            onChange?(.modelUnloadPolicy)
        }
    }

    var restoreClipboardAfterPaste: Bool {
        didSet {
            UserDefaults.standard.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste")
            onChange?(.restoreClipboardAfterPaste)
        }
    }

    var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: "customSystemPrompt")
            onChange?(.customSystemPrompt)
        }
    }

    var wordCorrectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
            onChange?(.wordCorrectionEnabled)
        }
    }

    var fillerRemovalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled")
            onChange?(.fillerRemovalEnabled)
        }
    }

    var isDebugModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDebugModeEnabled, forKey: "isDebugModeEnabled")
            onChange?(.isDebugModeEnabled)
        }
    }

    var debugLogLevel: DebugLogLevel {
        didSet {
            UserDefaults.standard.set(debugLogLevel.rawValue, forKey: "debugLogLevel")
            onChange?(.debugLogLevel)
        }
    }

    var useExtendedThinking: Bool {
        didSet {
            UserDefaults.standard.set(useExtendedThinking, forKey: "useExtendedThinking")
            onChange?(.useExtendedThinking)
        }
    }

    var whisperKitLanguageAutoDetect: Bool {
        didSet {
            UserDefaults.standard.set(whisperKitLanguageAutoDetect, forKey: "whisperKitLanguageAutoDetect")
            onChange?(.whisperKitLanguageAutoDetect)
        }
    }

    var selectedInputDeviceUID: String {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID")
            onChange?(.selectedInputDeviceUID)
        }
    }

    var noiseSuppression: Bool {
        didSet {
            UserDefaults.standard.set(noiseSuppression, forKey: "noiseSuppression")
            onChange?(.noiseSuppression)
        }
    }

    /// User override for input device. Empty string means "Auto" (smart selection).
    var preferredInputDeviceIDOverride: String {
        didSet {
            UserDefaults.standard.set(preferredInputDeviceIDOverride, forKey: "preferredInputDeviceIDOverride")
            onChange?(.preferredInputDeviceIDOverride)
        }
    }

    var environmentPreset: EnvironmentPreset {
        didSet {
            UserDefaults.standard.set(environmentPreset.rawValue, forKey: "environmentPreset")
            onChange?(.environmentPreset)
        }
    }

    var writingStylePreset: WritingStylePreset {
        didSet {
            UserDefaults.standard.set(writingStylePreset.rawValue, forKey: "writingStylePreset")
            onChange?(.writingStylePreset)
        }
    }

    var activePolishInstructions: PolishInstructions {
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

    var isPushToTalk: Bool {
        get { recordingMode == .pushToTalk }
        set { recordingMode = newValue ? .pushToTalk : .toggle }
    }

    init() {
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        whisperKitModel = defaults.string(forKey: "whisperKitModel") ?? "large-v3-turbo"
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
        whisperKitLanguageAutoDetect = defaults.object(forKey: "whisperKitLanguageAutoDetect") as? Bool ?? false
        selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID") ?? ""
        noiseSuppression = defaults.object(forKey: "noiseSuppression") as? Bool ?? false
        preferredInputDeviceIDOverride = defaults.string(forKey: "preferredInputDeviceIDOverride") ?? ""
        environmentPreset = EnvironmentPreset(rawValue: defaults.string(forKey: "environmentPreset") ?? "") ?? .normal
        writingStylePreset = WritingStylePreset(rawValue: defaults.string(forKey: "writingStylePreset") ?? "") ?? .standard
    }
}
