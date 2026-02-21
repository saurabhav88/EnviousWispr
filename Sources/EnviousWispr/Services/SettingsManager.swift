import AppKit

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
        case hasCompletedOnboarding
        case cancelKeyCode
        case cancelModifiers
        case toggleKeyCode
        case toggleModifiers
        case pushToTalkModifier
        case pushToTalkModifierKeyCode
        case modelUnloadPolicy
        case restoreClipboardAfterPaste
        case customSystemPrompt
        case wordCorrectionEnabled
        case isDebugModeEnabled
        case debugLogLevel
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

    var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
            onChange?(.hasCompletedOnboarding)
        }
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

    var pushToTalkModifier: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(pushToTalkModifier.rawValue, forKey: "pushToTalkModifierRaw")
            onChange?(.pushToTalkModifier)
        }
    }

    var pushToTalkModifierKeyCode: UInt16? {
        didSet {
            if let kc = pushToTalkModifierKeyCode {
                UserDefaults.standard.set(Int(kc), forKey: "pushToTalkModifierKeyCode")
            } else {
                UserDefaults.standard.removeObject(forKey: "pushToTalkModifierKeyCode")
            }
            onChange?(.pushToTalkModifierKeyCode)
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

    var activePolishInstructions: PolishInstructions {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .default
            : .custom(systemPrompt: customSystemPrompt)
    }

    init() {
        let defaults = UserDefaults.standard
        selectedBackend = ASRBackendType(rawValue: defaults.string(forKey: "selectedBackend") ?? "") ?? .parakeet
        whisperKitModel = defaults.string(forKey: "whisperKitModel") ?? "large-v3"
        recordingMode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .pushToTalk
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .none
        llmModel = defaults.string(forKey: "llmModel") ?? "gpt-4o-mini"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        autoCopyToClipboard = defaults.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        vadAutoStop = defaults.object(forKey: "vadAutoStop") as? Bool ?? false
        vadSilenceTimeout = defaults.object(forKey: "vadSilenceTimeout") as? Double ?? 1.5
        vadSensitivity = defaults.object(forKey: "vadSensitivity") as? Float ?? 0.5
        vadEnergyGate = defaults.object(forKey: "vadEnergyGate") as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false

        let savedCancelKeyCode = defaults.object(forKey: "cancelKeyCode") as? Int
        cancelKeyCode = UInt16(savedCancelKeyCode ?? 53)

        let savedCancelModRaw = defaults.object(forKey: "cancelModifiersRaw") as? UInt
        cancelModifiers = NSEvent.ModifierFlags(rawValue: savedCancelModRaw ?? 0)

        let savedToggleKeyCode = defaults.object(forKey: "toggleKeyCode") as? Int
        toggleKeyCode = UInt16(savedToggleKeyCode ?? 49)

        let savedToggleModRaw = defaults.object(forKey: "toggleModifiersRaw") as? UInt
        toggleModifiers = NSEvent.ModifierFlags(rawValue: savedToggleModRaw ?? NSEvent.ModifierFlags.control.rawValue)

        let savedPTTModRaw = defaults.object(forKey: "pushToTalkModifierRaw") as? UInt
        pushToTalkModifier = NSEvent.ModifierFlags(rawValue: savedPTTModRaw ?? NSEvent.ModifierFlags.option.rawValue)

        let savedPTTKeyCode = defaults.object(forKey: "pushToTalkModifierKeyCode") as? Int
        pushToTalkModifierKeyCode = savedPTTKeyCode.map { UInt16($0) }

        modelUnloadPolicy = ModelUnloadPolicy(
            rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
        ) ?? .never
        restoreClipboardAfterPaste = defaults.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? false
        customSystemPrompt = defaults.string(forKey: "customSystemPrompt") ?? ""
        wordCorrectionEnabled = defaults.object(forKey: "wordCorrectionEnabled") as? Bool ?? true
        isDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled") as? Bool ?? false
        debugLogLevel = DebugLogLevel(
            rawValue: defaults.string(forKey: "debugLogLevel") ?? ""
        ) ?? .info
    }
}
