#if DEBUG
  import AppKit
  import EnviousWisprAudio
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation

  /// #3765: the dev control door's table of every `SettingsManager.SettingKey`.
  ///
  /// Four switches over `SettingKey`, none with a `default`, so a new setting does not
  /// compile in a DEBUG build until it is placed in a kind, given an ordinary route, given a
  /// JSON reading, and given a typed forced assignment. `allKeys` is the list the door exposes; a test compares it
  /// with the enum's declaration in source, because an exhaustive switch cannot notice a
  /// case that is missing from a list.
  ///
  /// **Forced writes assign the typed property** (`settings.<property> = value`), so the
  /// property's own `didSet` still persists, notifies and canonicalizes exactly as a screen
  /// write does. Force skips only the screens' policy (ranges, offered choices, conflicts,
  /// coupled picks). The one check force keeps is crash prevention for a value a consumer
  /// converts unsafely (`vadSilenceTimeout`).
  @MainActor
  enum DevControlSettings {
    typealias Key = SettingsManager.SettingKey

    /// How a non-forced write reaches the setting (plan §3.4).
    enum Kind: String {
      /// The screen assigns the property directly.
      case direct
      /// The screen goes through an owner's helper with its preconditions.
      case viaOwner
      /// The screen's check, moved out of its view into a shared owner the door also calls.
      case extractedCheck
      /// No current screen operation writes it, or it is legacy; type checks only.
      case staging
    }

    struct Entry: Equatable {
      let key: Key
      let name: String
      let kind: Kind
      let legacy: Bool
    }

    enum WriteOutcome: Equatable {
      case written(forced: Bool)
      case badValue(String)
    }

    /// Every key, once, in declaration order.
    static let allKeys: [Key] = [
      .selectedBackend, .recordingMode, .llmProvider, .llmModel, .ollamaModel,
      .fileImportLLMProvider, .fileImportLLMModel, .fileImportOllamaModel,
      .meetingSummaryLLMProvider, .meetingSummaryLLMModel, .meetingSummaryOllamaModel,
      .s1MiniStyling, .s1MiniStructure, .s1MiniContext, .autoCopyToClipboard,
      .meetingCaptureCallSound, .meetingCallSoundExplained, .meetingWriteSummary, .meetingTurnsOffDictation, .meetingOnboardingComplete, .meetingUseCalendarForNames, .meetingCallDetection, .meetingCallAppsOff, .meetingCallNoCounts, .meetingCallFirstTipShown, .meetingLanguageMode, .meetingTranscriptEngine, .meetingLiveWordsEngine, .meetingLiveWordsLanguage, .hotkeyEnabled, .vadAutoStop, .vadSilenceTimeout, .vadSensitivity, .vadEnergyGate, .onboardingState,
      .hasCompletedOnboarding, .cancelKeyCode, .cancelModifiers, .quickAddKeyCode,
      .quickAddModifiers, .pasteLastKeyCode, .pasteLastModifiers, .copyLastKeyCode,
      .copyLastModifiers, .toggleKeyCode, .toggleModifiers, .pushToTalkKeyCode,
      .pushToTalkModifiers, .modelUnloadPolicy, .restoreClipboardAfterPaste,
      .keepDictationsOutOfClipboardHistory, .quickAddClipboardFallback, .smartInsertion,
      .escapeRecoveryEnabled, .wordCorrectionEnabled, .fillerRemovalEnabled,
      .emojiFormatterEnabled, .spokenPunctuation, .casualModeEnabled, .crashRecoveryEnabled,
      .shareUsageMetrics, .sendCrashReports, .contactsSyncOnLaunchEnabled, .isDebugModeEnabled,
      .isDictationAudioArchiveEnabled, .debugLogLevel, .whisperKitLanguage, .languageMode,
      .englishSpelling, .selectedInputDeviceUID, .preferredInputDeviceIDOverride,
      .inputChannelByDeviceUID, .useStreamingASR, .livePreviewEnabled, .livePreviewEngine,
      .warmEnginePolicy, .appearance, .overlayPillPosition, .recordingPillDesignWithoutWords,
      .recordingPillDesignWithWords, .showBluetoothTips, .showInDock, .showMenuBarUpdateAlert,
      .playRecordingSounds, .recordingSoundPairing, .otherAudioWhileDictating, .learnFromEdits,
    ]

    /// The wire name: the enum case's own name.
    static func name(_ key: Key) -> String { String(describing: key) }

    static func key(named name: String) -> Key? {
      allKeys.first { self.name($0) == name }
    }

    // MARK: - Membership

    static func entry(_ key: Key) -> Entry {
      func make(_ kind: Kind, legacy: Bool = false) -> Entry {
        Entry(key: key, name: name(key), kind: kind, legacy: legacy)
      }
      switch key {
      case .selectedBackend, .recordingMode, .llmProvider, .llmModel, .s1MiniStyling,
        .s1MiniStructure, .s1MiniContext, .autoCopyToClipboard, .meetingCaptureCallSound,
        .meetingCallSoundExplained, .meetingWriteSummary, .meetingTurnsOffDictation,
        .meetingOnboardingComplete,
        .meetingUseCalendarForNames, .meetingCallDetection, .meetingCallAppsOff,
        .meetingCallNoCounts, .meetingCallFirstTipShown, .meetingLanguageMode,
        .meetingTranscriptEngine, .meetingLiveWordsEngine, .meetingLiveWordsLanguage, .vadAutoStop, .modelUnloadPolicy,
        .restoreClipboardAfterPaste, .keepDictationsOutOfClipboardHistory,
        .quickAddClipboardFallback, .smartInsertion, .escapeRecoveryEnabled,
        .wordCorrectionEnabled, .fillerRemovalEnabled, .emojiFormatterEnabled,
        .casualModeEnabled, .shareUsageMetrics, .sendCrashReports, .contactsSyncOnLaunchEnabled,
        .isDebugModeEnabled, .isDictationAudioArchiveEnabled, .debugLogLevel, .useStreamingASR,
        .livePreviewEnabled, .livePreviewEngine, .warmEnginePolicy, .appearance,
        .overlayPillPosition, .showBluetoothTips, .showInDock, .showMenuBarUpdateAlert,
        .playRecordingSounds, .recordingSoundPairing, .otherAudioWhileDictating, .learnFromEdits:
        return make(.direct)
      case .selectedInputDeviceUID, .preferredInputDeviceIDOverride, .spokenPunctuation,
        .hasCompletedOnboarding, .recordingPillDesignWithoutWords, .recordingPillDesignWithWords,
        .languageMode, .englishSpelling:
        return make(.viaOwner)
      case .cancelKeyCode, .cancelModifiers, .quickAddKeyCode, .quickAddModifiers,
        .pasteLastKeyCode, .pasteLastModifiers, .copyLastKeyCode, .copyLastModifiers,
        .toggleKeyCode, .toggleModifiers, .vadSilenceTimeout, .fileImportLLMProvider,
        .fileImportLLMModel, .fileImportOllamaModel, .ollamaModel, .inputChannelByDeviceUID,
        .meetingSummaryLLMProvider, .meetingSummaryLLMModel, .meetingSummaryOllamaModel:
        return make(.extractedCheck)
      case .hotkeyEnabled, .vadSensitivity, .vadEnergyGate, .crashRecoveryEnabled,
        .onboardingState:
        return make(.staging)
      case .whisperKitLanguage, .pushToTalkKeyCode, .pushToTalkModifiers:
        return make(.staging, legacy: true)
      }
    }

    // MARK: - Reads

    /// The setting's current value as a JSON value (`NSNull` for an absent optional).
    static func read(_ key: Key, from settings: SettingsManager) -> Any {
      switch key {
      case .selectedBackend: return settings.selectedBackend.rawValue
      case .recordingMode: return settings.recordingMode.rawValue
      case .llmProvider: return settings.llmProvider.rawValue
      case .llmModel: return settings.llmModel
      case .ollamaModel: return settings.ollamaModel
      case .fileImportLLMProvider:
        return settings.fileImportLLMProvider.map { $0.rawValue as Any } ?? NSNull()
      case .fileImportLLMModel: return settings.fileImportLLMModel
      case .fileImportOllamaModel: return settings.fileImportOllamaModel
      case .meetingSummaryLLMProvider:
        return settings.meetingSummaryLLMProvider.map { $0.rawValue as Any } ?? NSNull()
      case .meetingSummaryLLMModel: return settings.meetingSummaryLLMModel
      case .meetingSummaryOllamaModel: return settings.meetingSummaryOllamaModel
      case .s1MiniStyling: return settings.s1MiniStyling.rawValue
      case .s1MiniStructure: return settings.s1MiniStructure.rawValue
      case .s1MiniContext: return settings.s1MiniContext.rawValue
      case .autoCopyToClipboard: return settings.autoCopyToClipboard
      case .meetingCaptureCallSound: return settings.meetingCaptureCallSound
      case .meetingCallSoundExplained: return settings.meetingCallSoundExplained
      case .meetingWriteSummary: return settings.meetingWriteSummary
      case .meetingTurnsOffDictation: return settings.meetingTurnsOffDictation
      case .meetingOnboardingComplete: return settings.meetingOnboardingComplete
      case .meetingUseCalendarForNames: return settings.meetingUseCalendarForNames
      case .meetingCallDetection: return settings.meetingCallDetection
      case .meetingCallAppsOff: return settings.meetingCallAppsOff
      case .meetingCallNoCounts: return settings.meetingCallNoCounts
      case .meetingCallFirstTipShown: return settings.meetingCallFirstTipShown
      case .hotkeyEnabled: return settings.hotkeyEnabled
      case .vadAutoStop: return settings.vadAutoStop
      case .vadSilenceTimeout: return settings.vadSilenceTimeout
      case .vadSensitivity: return Double(settings.vadSensitivity)
      case .vadEnergyGate: return settings.vadEnergyGate
      case .onboardingState: return settings.onboardingState.rawValue
      case .hasCompletedOnboarding: return settings.hasCompletedOnboarding
      case .cancelKeyCode: return Int(settings.cancelKeyCode)
      case .cancelModifiers: return settings.cancelModifiers.rawValue
      case .quickAddKeyCode: return Int(settings.quickAddKeyCode)
      case .quickAddModifiers: return settings.quickAddModifiers.rawValue
      case .pasteLastKeyCode: return Int(settings.pasteLastKeyCode)
      case .pasteLastModifiers: return settings.pasteLastModifiers.rawValue
      case .copyLastKeyCode: return Int(settings.copyLastKeyCode)
      case .copyLastModifiers: return settings.copyLastModifiers.rawValue
      case .toggleKeyCode: return Int(settings.toggleKeyCode)
      case .toggleModifiers: return settings.toggleModifiers.rawValue
      case .pushToTalkKeyCode: return Int(settings.pushToTalkKeyCode)
      case .pushToTalkModifiers: return settings.pushToTalkModifiers.rawValue
      case .modelUnloadPolicy: return settings.modelUnloadPolicy.rawValue
      case .restoreClipboardAfterPaste: return settings.restoreClipboardAfterPaste
      case .keepDictationsOutOfClipboardHistory: return settings.keepDictationsOutOfClipboardHistory
      case .quickAddClipboardFallback: return settings.quickAddClipboardFallback
      case .smartInsertion: return settings.smartInsertion
      case .escapeRecoveryEnabled: return settings.escapeRecoveryEnabled
      case .wordCorrectionEnabled: return settings.wordCorrectionEnabled
      case .fillerRemovalEnabled: return settings.fillerRemovalEnabled
      case .emojiFormatterEnabled: return settings.emojiFormatterEnabled
      case .spokenPunctuation: return Codec.encode(settings.spokenPunctuation)
      case .casualModeEnabled: return settings.casualModeEnabled
      case .crashRecoveryEnabled: return settings.crashRecoveryEnabled
      case .shareUsageMetrics: return settings.shareUsageMetrics
      case .sendCrashReports: return settings.sendCrashReports
      case .contactsSyncOnLaunchEnabled: return settings.contactsSyncOnLaunchEnabled
      case .isDebugModeEnabled: return settings.isDebugModeEnabled
      case .isDictationAudioArchiveEnabled: return settings.isDictationAudioArchiveEnabled
      case .debugLogLevel: return settings.debugLogLevel.rawValue
      case .whisperKitLanguage: return settings.whisperKitLanguage
      case .languageMode: return Codec.encode(settings.languageMode)
      case .meetingLanguageMode: return Codec.encode(settings.meetingLanguageMode)
      case .meetingTranscriptEngine: return settings.meetingTranscriptEngine.rawValue
      case .meetingLiveWordsEngine: return settings.meetingLiveWordsEngine?.rawValue ?? NSNull()
      case .meetingLiveWordsLanguage: return settings.meetingLiveWordsLanguage ?? NSNull()
      case .englishSpelling: return settings.englishSpelling.rawValue
      case .selectedInputDeviceUID: return settings.selectedInputDeviceUID
      case .preferredInputDeviceIDOverride: return settings.preferredInputDeviceIDOverride
      case .inputChannelByDeviceUID: return settings.inputChannelByDeviceUID
      case .useStreamingASR: return settings.useStreamingASR
      case .livePreviewEnabled: return settings.livePreviewEnabled
      case .livePreviewEngine: return settings.livePreviewEngine.rawValue
      case .warmEnginePolicy: return settings.warmEnginePolicy.rawValue
      case .appearance: return settings.appearancePreference.rawValue
      case .overlayPillPosition: return settings.overlayPillPosition.rawValue
      case .recordingPillDesignWithoutWords:
        return settings.recordingPillDesignWithoutWords.rawValue
      case .recordingPillDesignWithWords: return settings.recordingPillDesignWithWords.rawValue
      case .showBluetoothTips: return settings.showBluetoothTips
      case .showInDock: return settings.showInDock
      case .showMenuBarUpdateAlert: return settings.showMenuBarUpdateAlert
      case .playRecordingSounds: return settings.playRecordingSounds
      case .recordingSoundPairing: return settings.recordingSoundPairing.rawValue
      case .otherAudioWhileDictating: return settings.otherAudioWhileDictating.rawValue
      case .learnFromEdits: return settings.learnFromEdits
      }
    }

    /// One catalog row per key: name, current value and how it is written.
    static func catalog(_ settings: SettingsManager) -> [[String: Any]] {
      allKeys.map { key in
        let entry = entry(key)
        return [
          "key": entry.name,
          "value": read(key, from: settings),
          "kind": entry.kind.rawValue,
          "legacy": entry.legacy,
        ]
      }
    }

    // MARK: - Forced writes

    /// Decodes `value` to the property's type and assigns it, skipping the screens' policy.
    /// Nothing is assigned when decoding or the crash-prevention check fails.
    static func forceWrite(_ key: Key, value: Any, to settings: SettingsManager) -> WriteOutcome {
      attributed(settings) { assign(key, value: value, to: settings, forced: true) }
    }

    /// Runs `body` with `settings.isDevControlWrite` set, so every change notification the
    /// write causes (including a setter's synchronous consequences, such as the model a
    /// provider change canonicalizes) is attributed to the door. Restores the caller's prior
    /// value, so nested use keeps an enclosing scope open. Synchronous: never await inside.
    static func attributed<T>(_ settings: SettingsManager, _ body: () -> T) -> T {
      let prior = settings.isDevControlWrite
      settings.isDevControlWrite = true
      defer { settings.isDevControlWrite = prior }
      return body()
    }

    /// The one property mapping: decode to the property's type, keep the crash-prevention
    /// check, assign through the typed setter. `forced` only labels the outcome; ordinary
    /// writes reach this after their route's own checks.
    private static func assign(
      _ key: Key, value: Any, to settings: SettingsManager, forced: Bool
    ) -> WriteOutcome {
      func set<T>(_ decoded: T?, _ assign: (T) -> Void) -> WriteOutcome {
        guard let decoded else { return .badValue("wrong type or unknown value") }
        assign(decoded)
        return .written(forced: forced)
      }
      switch key {
      case .selectedBackend:
        return set(Codec.raw(value, ASRBackendType.self)) { settings.selectedBackend = $0 }
      case .recordingMode:
        return set(Codec.raw(value, RecordingMode.self)) { settings.recordingMode = $0 }
      case .llmProvider:
        return set(Codec.raw(value, LLMProvider.self)) { settings.llmProvider = $0 }
      case .llmModel:
        return set(Codec.string(value)) { settings.llmModel = $0 }
      case .ollamaModel:
        return set(Codec.string(value)) { settings.ollamaModel = $0 }
      case .fileImportLLMProvider:
        return set(Codec.optionalRaw(value, LLMProvider.self)) {
          settings.fileImportLLMProvider = $0
        }
      case .fileImportLLMModel:
        return set(Codec.string(value)) { settings.fileImportLLMModel = $0 }
      case .fileImportOllamaModel:
        return set(Codec.string(value)) { settings.fileImportOllamaModel = $0 }
      case .meetingSummaryLLMProvider:
        return set(Codec.optionalRaw(value, LLMProvider.self)) {
          settings.meetingSummaryLLMProvider = $0
        }
      case .meetingSummaryLLMModel:
        return set(Codec.string(value)) { settings.meetingSummaryLLMModel = $0 }
      case .meetingSummaryOllamaModel:
        return set(Codec.string(value)) { settings.meetingSummaryOllamaModel = $0 }
      case .s1MiniStyling:
        return set(Codec.raw(value, S1Styling.self)) { settings.s1MiniStyling = $0 }
      case .s1MiniStructure:
        return set(Codec.raw(value, S1Structure.self)) { settings.s1MiniStructure = $0 }
      case .s1MiniContext:
        return set(Codec.raw(value, S1Context.self)) { settings.s1MiniContext = $0 }
      case .autoCopyToClipboard:
        return set(Codec.bool(value)) { settings.autoCopyToClipboard = $0 }
      case .meetingCaptureCallSound:
        return set(Codec.bool(value)) { settings.meetingCaptureCallSound = $0 }
      case .meetingCallSoundExplained:
        return set(Codec.bool(value)) { settings.meetingCallSoundExplained = $0 }
      case .meetingWriteSummary:
        return set(Codec.bool(value)) { settings.meetingWriteSummary = $0 }
      case .meetingTurnsOffDictation:
        return set(Codec.bool(value)) { settings.meetingTurnsOffDictation = $0 }
      case .meetingOnboardingComplete:
        return set(Codec.bool(value)) { settings.meetingOnboardingComplete = $0 }
      case .meetingUseCalendarForNames:
        return set(Codec.bool(value)) { settings.meetingUseCalendarForNames = $0 }
      case .meetingCallDetection:
        return set(Codec.string(value)) { settings.meetingCallDetection = $0 }
      case .meetingCallAppsOff:
        return set(Codec.string(value)) { settings.meetingCallAppsOff = $0 }
      case .meetingCallNoCounts:
        return set(Codec.string(value)) { settings.meetingCallNoCounts = $0 }
      case .meetingCallFirstTipShown:
        return set(Codec.bool(value)) { settings.meetingCallFirstTipShown = $0 }
      case .hotkeyEnabled:
        return set(Codec.bool(value)) { settings.hotkeyEnabled = $0 }
      case .vadAutoStop:
        return set(Codec.bool(value)) { settings.vadAutoStop = $0 }
      case .vadSilenceTimeout:
        guard let seconds = Codec.double(value) else { return .badValue("wrong type") }
        guard Self.silenceTimeoutIsConvertible(seconds) else {
          return .badValue("silence timeout too large for the detector's chunk count")
        }
        settings.vadSilenceTimeout = seconds
        return .written(forced: forced)
      case .vadSensitivity:
        return set(Codec.float(value)) { settings.vadSensitivity = $0 }
      case .vadEnergyGate:
        return set(Codec.bool(value)) { settings.vadEnergyGate = $0 }
      case .onboardingState:
        return set(Codec.raw(value, OnboardingState.self)) { settings.onboardingState = $0 }
      case .hasCompletedOnboarding:
        return set(Codec.bool(value)) { settings.hasCompletedOnboarding = $0 }
      case .cancelKeyCode:
        return set(Codec.uint16(value)) { settings.cancelKeyCode = $0 }
      case .cancelModifiers:
        return set(Codec.modifiers(value)) { settings.cancelModifiers = $0 }
      case .quickAddKeyCode:
        return set(Codec.uint16(value)) { settings.quickAddKeyCode = $0 }
      case .quickAddModifiers:
        return set(Codec.modifiers(value)) { settings.quickAddModifiers = $0 }
      case .pasteLastKeyCode:
        return set(Codec.uint16(value)) { settings.pasteLastKeyCode = $0 }
      case .pasteLastModifiers:
        return set(Codec.modifiers(value)) { settings.pasteLastModifiers = $0 }
      case .copyLastKeyCode:
        return set(Codec.uint16(value)) { settings.copyLastKeyCode = $0 }
      case .copyLastModifiers:
        return set(Codec.modifiers(value)) { settings.copyLastModifiers = $0 }
      case .toggleKeyCode:
        return set(Codec.uint16(value)) { settings.toggleKeyCode = $0 }
      case .toggleModifiers:
        return set(Codec.modifiers(value)) { settings.toggleModifiers = $0 }
      case .pushToTalkKeyCode:
        return set(Codec.uint16(value)) { settings.pushToTalkKeyCode = $0 }
      case .pushToTalkModifiers:
        return set(Codec.modifiers(value)) { settings.pushToTalkModifiers = $0 }
      case .modelUnloadPolicy:
        return set(Codec.raw(value, ModelUnloadPolicy.self)) { settings.modelUnloadPolicy = $0 }
      case .restoreClipboardAfterPaste:
        return set(Codec.bool(value)) { settings.restoreClipboardAfterPaste = $0 }
      case .keepDictationsOutOfClipboardHistory:
        return set(Codec.bool(value)) { settings.keepDictationsOutOfClipboardHistory = $0 }
      case .quickAddClipboardFallback:
        return set(Codec.bool(value)) { settings.quickAddClipboardFallback = $0 }
      case .smartInsertion:
        return set(Codec.bool(value)) { settings.smartInsertion = $0 }
      case .escapeRecoveryEnabled:
        return set(Codec.bool(value)) { settings.escapeRecoveryEnabled = $0 }
      case .wordCorrectionEnabled:
        return set(Codec.bool(value)) { settings.wordCorrectionEnabled = $0 }
      case .fillerRemovalEnabled:
        return set(Codec.bool(value)) { settings.fillerRemovalEnabled = $0 }
      case .emojiFormatterEnabled:
        return set(Codec.bool(value)) { settings.emojiFormatterEnabled = $0 }
      case .spokenPunctuation:
        return set(Codec.spokenPunctuation(value)) { settings.spokenPunctuation = $0 }
      case .casualModeEnabled:
        return set(Codec.bool(value)) { settings.casualModeEnabled = $0 }
      case .crashRecoveryEnabled:
        return set(Codec.bool(value)) { settings.crashRecoveryEnabled = $0 }
      case .shareUsageMetrics:
        return set(Codec.bool(value)) { settings.shareUsageMetrics = $0 }
      case .sendCrashReports:
        return set(Codec.bool(value)) { settings.sendCrashReports = $0 }
      case .contactsSyncOnLaunchEnabled:
        return set(Codec.bool(value)) { settings.contactsSyncOnLaunchEnabled = $0 }
      case .isDebugModeEnabled:
        return set(Codec.bool(value)) { settings.isDebugModeEnabled = $0 }
      case .isDictationAudioArchiveEnabled:
        return set(Codec.bool(value)) { settings.isDictationAudioArchiveEnabled = $0 }
      case .debugLogLevel:
        return set(Codec.raw(value, DebugLogLevel.self)) { settings.debugLogLevel = $0 }
      case .whisperKitLanguage:
        return set(Codec.string(value)) { settings.whisperKitLanguage = $0 }
      case .languageMode:
        return set(Codec.languageMode(value)) { settings.languageMode = $0 }
      case .meetingLanguageMode:
        return set(Codec.languageMode(value)) { settings.meetingLanguageMode = $0 }
      case .meetingTranscriptEngine:
        return set(Codec.raw(value, MeetingEngineChoice.self)) {
          settings.meetingTranscriptEngine = $0
        }
      // #4105: null clears the choice back to unset.
      case .meetingLiveWordsEngine:
        if value is NSNull {
          settings.meetingLiveWordsEngine = nil
          return .written(forced: forced)
        }
        return set(Codec.raw(value, LivePreviewEngineChoice.self)) {
          settings.meetingLiveWordsEngine = $0
        }
      case .meetingLiveWordsLanguage:
        if value is NSNull {
          settings.meetingLiveWordsLanguage = nil
          return .written(forced: forced)
        }
        return set(Codec.string(value).flatMap { $0.isEmpty ? nil : $0 }) {
          settings.meetingLiveWordsLanguage = $0
        }
      case .englishSpelling:
        return set(Codec.raw(value, EnglishSpelling.self)) { settings.englishSpelling = $0 }
      case .selectedInputDeviceUID:
        return set(Codec.string(value)) { settings.selectedInputDeviceUID = $0 }
      case .preferredInputDeviceIDOverride:
        return set(Codec.string(value)) { settings.preferredInputDeviceIDOverride = $0 }
      case .inputChannelByDeviceUID:
        return set(Codec.channelMap(value)) { settings.inputChannelByDeviceUID = $0 }
      case .useStreamingASR:
        return set(Codec.bool(value)) { settings.useStreamingASR = $0 }
      case .livePreviewEnabled:
        return set(Codec.bool(value)) { settings.livePreviewEnabled = $0 }
      case .livePreviewEngine:
        return set(Codec.raw(value, LivePreviewEngineChoice.self)) {
          settings.livePreviewEngine = $0
        }
      case .warmEnginePolicy:
        return set(Codec.raw(value, WarmEnginePolicy.self)) { settings.warmEnginePolicy = $0 }
      case .appearance:
        return set(Codec.raw(value, AppearancePreference.self)) {
          settings.appearancePreference = $0
        }
      case .overlayPillPosition:
        return set(Codec.raw(value, OverlayPillPosition.self)) { settings.overlayPillPosition = $0 }
      case .recordingPillDesignWithoutWords:
        return set(Codec.raw(value, RecordingPillDesign.self)) {
          settings.recordingPillDesignWithoutWords = $0
        }
      case .recordingPillDesignWithWords:
        return set(Codec.raw(value, RecordingPillDesign.self)) {
          settings.recordingPillDesignWithWords = $0
        }
      case .showBluetoothTips:
        return set(Codec.bool(value)) { settings.showBluetoothTips = $0 }
      case .showInDock:
        return set(Codec.bool(value)) { settings.showInDock = $0 }
      case .showMenuBarUpdateAlert:
        return set(Codec.bool(value)) { settings.showMenuBarUpdateAlert = $0 }
      case .playRecordingSounds:
        return set(Codec.bool(value)) { settings.playRecordingSounds = $0 }
      case .recordingSoundPairing:
        return set(Codec.raw(value, RecordingSoundPairing.self)) {
          settings.recordingSoundPairing = $0
        }
      case .otherAudioWhileDictating:
        return set(Codec.raw(value, OtherAudioWhileDictating.self)) {
          settings.otherAudioWhileDictating = $0
        }
      case .learnFromEdits:
        return set(Codec.bool(value)) { settings.learnFromEdits = $0 }
      }
    }

    // MARK: - Ordinary writes

    /// What a non-forced write needs from the running app, injected so tests never read
    /// live discovery state or enumerate real audio hardware.
    struct WriteContext {
      /// The polish model catalog discovery currently holds, and the provider it is about.
      var modelCatalog: () -> ModelCatalog
      /// The screen's synchronous cached load, including ownership and surface repair
      /// (`LLMModelDiscoveryCoordinator.loadCachedModels`), so a model check after a provider
      /// change does not depend on a mounted screen.
      var loadCachedModelCatalog: (LLMProvider, ProviderSetupSurface) -> Void
      /// UIDs of the input devices the system lists right now.
      var connectedInputUIDs: () -> [String]
      /// Input count per connected input device UID, read at request time.
      var inputChannelCounts: () -> [String: Int]
      /// Whether the pill can show words right now, as the Appearance picker reads it
      /// (`PillAppearanceModel.wordsCapability`).
      var pillWordsCapability: () -> PillWordsCapability
    }

    struct ModelCatalog {
      let provider: LLMProvider?
      let models: [LLMModelInfo]
    }

    enum SetOutcome: Equatable {
      case written(forced: Bool)
      case refused(code: String, message: String)

      /// The refusal code, or nil for a write.
      var code: String? {
        if case .refused(let code, _) = self { return code }
        return nil
      }

      var message: String {
        if case .refused(_, let message) = self { return message }
        return ""
      }
    }

    /// Providers whose model is a fixed literal the provider setter pins; there is no model
    /// to choose, so an ordinary `llmModel` write is refused.
    static let fixedModelProviders: Set<LLMProvider> = [.appleIntelligence, .egOne, .s1Mini, .none]

    /// How an ordinary (non-forced) write is checked before the typed assignment.
    enum Route: Equatable {
      /// No check beyond decoding: the screen assigns the property directly.
      case typed
      /// The current provider's discovered catalog (`llmModel`).
      case modelCatalog
      /// `MicrophoneChoiceValidation`, then `SettingsManager.chooseInputDevice(uid:)`.
      case inputDevice
      /// The start-word owners on `SettingsManager`.
      case spokenPunctuation
      /// The Appearance pill picker: its group for the slot, `offersCoupled`, then
      /// `PillAppearanceModel.chooseCoupled`.
      case pillDesign
      /// The pause-duration slider's offered values (`SilenceTimeoutSlider`).
      case silenceTimeout
      /// Transcribe a File's provider picker (`PolishSettings.setProvider` on `.fileImport`);
      /// `null` is "Use dictation's polish settings".
      case importProvider
      /// Transcribe a File's model menu, through the same offered-model groups as llmModel.
      case importModel
      /// #4287: the Summaries tab's provider cards (`PolishSettings.setProvider` on
      /// `.meetingSummary`). `null` is refused: no screen can return a choice to unmigrated.
      case summaryProvider
      /// #4287: the Summaries tab's model menu, through the same offered-model groups.
      case summaryModel
      /// An Ollama model pick on the surface the field belongs to, allowed only while that
      /// surface's provider is Ollama; the pick goes through the model menu's own write.
      case ollamaModel
      /// The socket row picks one device's input at a time, against that device's inputs, so
      /// a whole-map write is refused toward `channel.set` (`setChannel`).
      case channelCommand
      /// The language picker sets the lock and the spelling together, so a single-field
      /// write is refused toward `language.set` (`setLanguage`).
      case languageCommand
      /// One half of a Keybinds shortcut: checked as the whole binding it makes with the other
      /// half as saved (`setShortcut`); `shortcut.set` changes both halves together.
      case shortcutField
    }

    /// One case per key and no `default`, so a new setting cannot compile without a route.
    /// The typed keys are the `direct` and `staging` rows plus `hasCompletedOnboarding`, whose
    /// owner is a plain assignment; `DevControlSettingsTests` checks this against `entry(_:)`.
    static func route(_ key: Key) -> Route {
      switch key {
      case .llmModel:
        return .modelCatalog
      case .selectedInputDeviceUID, .preferredInputDeviceIDOverride:
        return .inputDevice
      case .spokenPunctuation:
        return .spokenPunctuation
      case .recordingPillDesignWithoutWords, .recordingPillDesignWithWords:
        return .pillDesign
      case .languageMode, .englishSpelling:
        return .languageCommand
      case .vadSilenceTimeout:
        return .silenceTimeout
      case .fileImportLLMProvider:
        return .importProvider
      case .fileImportLLMModel:
        return .importModel
      case .meetingSummaryLLMProvider:
        return .summaryProvider
      case .meetingSummaryLLMModel:
        return .summaryModel
      case .ollamaModel, .fileImportOllamaModel, .meetingSummaryOllamaModel:
        return .ollamaModel
      case .inputChannelByDeviceUID:
        return .channelCommand
      case .cancelKeyCode, .cancelModifiers, .quickAddKeyCode, .quickAddModifiers,
        .pasteLastKeyCode, .pasteLastModifiers, .copyLastKeyCode, .copyLastModifiers,
        .toggleKeyCode, .toggleModifiers:
        return .shortcutField
      case .selectedBackend, .recordingMode, .llmProvider, .s1MiniStyling, .s1MiniStructure,
        .s1MiniContext, .autoCopyToClipboard, .meetingCaptureCallSound, .meetingCallSoundExplained,
        .meetingWriteSummary, .meetingTurnsOffDictation, .meetingOnboardingComplete,
        .meetingUseCalendarForNames,
        .meetingCallDetection, .meetingCallAppsOff, .meetingCallNoCounts, .meetingCallFirstTipShown,
        .meetingLanguageMode, .meetingTranscriptEngine, .meetingLiveWordsEngine, .meetingLiveWordsLanguage, .hotkeyEnabled,
        .vadAutoStop, .vadSensitivity,
        .vadEnergyGate, .onboardingState, .hasCompletedOnboarding, .pushToTalkKeyCode,
        .pushToTalkModifiers, .modelUnloadPolicy, .restoreClipboardAfterPaste,
        .keepDictationsOutOfClipboardHistory, .quickAddClipboardFallback, .smartInsertion,
        .escapeRecoveryEnabled, .wordCorrectionEnabled, .fillerRemovalEnabled,
        .emojiFormatterEnabled, .casualModeEnabled, .crashRecoveryEnabled, .shareUsageMetrics,
        .sendCrashReports, .contactsSyncOnLaunchEnabled, .isDebugModeEnabled,
        .isDictationAudioArchiveEnabled, .debugLogLevel, .whisperKitLanguage, .useStreamingASR,
        .livePreviewEnabled, .livePreviewEngine, .warmEnginePolicy, .appearance,
        .overlayPillPosition, .showBluetoothTips, .showInDock, .showMenuBarUpdateAlert,
        .playRecordingSounds, .recordingSoundPairing, .otherAudioWhileDictating, .learnFromEdits:
        return .typed
      }
    }

    /// A settings write as the door receives it: `force` assigns directly (any key); an
    /// ordinary write takes the key's route first. Every refusal happens before the first
    /// mutation, except that a model check may first load the cached catalog and run its
    /// surface repair, which stays applied even if the requested model is then refused.
    static func write(
      _ key: Key, value: Any, force: Bool, context: WriteContext, to settings: SettingsManager
    ) -> SetOutcome {
      attributed(settings) {
        checkedWrite(key, value: value, force: force, context: context, to: settings)
      }
    }

    private static func checkedWrite(
      _ key: Key, value: Any, force: Bool, context: WriteContext, to settings: SettingsManager
    ) -> SetOutcome {
      if force { return outcome(forceWrite(key, value: value, to: settings)) }
      switch route(key) {
      case .typed:
        return outcome(assign(key, value: value, to: settings, forced: false))
      case .modelCatalog:
        return writeModel(value, surface: .dictation, context: context, to: settings)
      case .importProvider:
        if value is NSNull {
          settings.followDictationForFileImportPolish()
          return .written(forced: false)
        }
        guard let provider = Codec.raw(value, LLMProvider.self) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        PolishSettings.setProvider(provider, on: .fileImport, in: settings)
        return .written(forced: false)
      case .importModel:
        return writeModel(value, surface: .fileImport, context: context, to: settings)
      case .summaryProvider:
        guard let provider = Codec.raw(value, LLMProvider.self) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        PolishSettings.setProvider(provider, on: .meetingSummary, in: settings)
        return .written(forced: false)
      case .summaryModel:
        return writeModel(value, surface: .meetingSummary, context: context, to: settings)
      case .ollamaModel:
        // `route(_:)` sends exactly these three keys here.
        let surface: ProviderSetupSurface =
          key == .ollamaModel
          ? .dictation : (key == .meetingSummaryOllamaModel ? .meetingSummary : .fileImport)
        guard PolishSettings.provider(on: surface, in: settings) == .ollama else {
          return .refused(
            code: "checkFailed",
            message: "that screen's provider is not Ollama; pick Ollama first, or use force to stage the field")
        }
        return writeModel(value, surface: surface, context: context, to: settings)
      case .inputDevice:
        guard let uid = Codec.string(value) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        guard
          MicrophoneChoiceValidation.isSelectable(uid: uid, connectedUIDs: context.connectedInputUIDs)
        else {
          return .refused(code: "checkFailed", message: "that input device is not connected")
        }
        settings.chooseInputDevice(uid: uid)
        return .written(forced: false)
      case .spokenPunctuation:
        return writeSpokenPunctuation(value, to: settings)
      case .pillDesign:
        return writePillDesign(
          value, holdingWords: key == .recordingPillDesignWithWords, context: context,
          to: settings)
      case .silenceTimeout:
        guard let seconds = Codec.double(value) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        guard Self.silenceTimeoutIsConvertible(seconds) else {
          return .refused(
            code: "badValue",
            message: "silence timeout too large for the detector's chunk count")
        }
        guard SilenceTimeoutSlider.offers(seconds) else {
          return .refused(
            code: "checkFailed",
            message: "the pause slider offers 0.5 to 3.0 seconds in 0.25 steps; use force to stage another value")
        }
        return outcome(assign(key, value: value, to: settings, forced: false))
      case .channelCommand:
        return .refused(
          code: "checkFailed",
          message: "the input-socket row sets one device's input at a time; use channel.set, "
            + "or force to stage the whole map")
      case .languageCommand:
        return .refused(
          code: "checkFailed",
          message: "the language picker sets the lock and the spelling together; use "
            + "language.set, or force to stage this field alone")
      case .shortcutField:
        return writeShortcutField(key, value: value, to: settings)
      }
    }

    /// The Keybinds role a shortcut field belongs to, and whether it is the key-code half.
    /// `DevControlSettingsTests` checks every answer against `ShortcutSettings`' field paths.
    static func shortcutField(_ key: Key) -> (role: ShortcutRole, isKeyCode: Bool)? {
      switch key {
      case .toggleKeyCode: return (.record, true)
      case .toggleModifiers: return (.record, false)
      case .cancelKeyCode: return (.cancel, true)
      case .cancelModifiers: return (.cancel, false)
      case .quickAddKeyCode: return (.quickAdd, true)
      case .quickAddModifiers: return (.quickAdd, false)
      case .pasteLastKeyCode: return (.pasteLast, true)
      case .pasteLastModifiers: return (.pasteLast, false)
      case .copyLastKeyCode: return (.copyLast, true)
      case .copyLastModifiers: return (.copyLast, false)
      default: return nil
      }
    }

    /// `shortcut.set`: a Keybinds row's whole shortcut, read the way the screen stores a key
    /// (`ShortcutSettings.binding(keyCode:modifiers:)`), then saved through the screen's own
    /// check and write (`ShortcutSettings.assign`). Never claims the Globe guidance, which only
    /// the screen that shows it may take.
    static func setShortcut(
      _ role: ShortcutRole, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
      to settings: SettingsManager
    ) -> SetOutcome {
      // #3807: ordinary dev-tool admission, not CGKeyCode's representation or an OS input limit.
      // Keep this on the complete candidate so individual-field writes share the same policy;
      // explicit forced writes retain the full UInt16 staging range.
      guard keyCode < 128 else {
        return .refused(
          code: "badValue",
          message: "keyCode must be 0 to 127; use settings.set with force to stage another UInt16 value")
      }
      let candidate = ShortcutSettings.binding(keyCode: keyCode, modifiers: modifiers)
      let refusal = attributed(settings) {
        ShortcutSettings.assign(candidate, to: role, in: settings)
      }
      guard let refusal else { return .written(forced: false) }
      return .refused(code: "checkFailed", message: message(for: refusal))
    }

    /// One half on its own: the other half stays as saved, and the pair is checked whole.
    private static func writeShortcutField(_ key: Key, value: Any, to settings: SettingsManager)
      -> SetOutcome
    {
      guard let field = shortcutField(key) else {
        return .refused(code: "badValue", message: "not a Keybinds shortcut field")
      }
      var keyCode = settings[keyPath: ShortcutSettings.keyCodeField(for: field.role)]
      var modifiers = settings[keyPath: ShortcutSettings.modifiersField(for: field.role)]
      if field.isKeyCode {
        guard let decoded = Codec.uint16(value) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        keyCode = decoded
      } else {
        guard let decoded = Codec.modifiers(value) else {
          return .refused(code: "badValue", message: "wrong type or unknown value")
        }
        modifiers = decoded
      }
      return setShortcut(field.role, keyCode: keyCode, modifiers: modifiers, to: settings)
    }

    private static func message(for refusal: ShortcutRefusal) -> String {
      switch refusal {
      case .systemShortcut:
        return "the Keybinds screen refuses a standard Mac shortcut"
      case .sameAs(let other):
        return "the \(other.rawValue) shortcut already uses those keys"
      case .modifierConflict(let other):
        return "clashes with the \(other.rawValue) shortcut: one needs a key the other uses on its own"
      }
    }

    /// The pill picker's own path. Each slot is one picker group
    /// (`PillCatalog.designs(holdingWords:)`), so a design from the other group is refused
    /// rather than letting `chooseCoupled` write the other slot. The picker greys out what
    /// `offersCoupled` refuses for the capability right now; an offered choice goes through
    /// `chooseCoupled`, which also sets Live Preview to what the design needs and leaves the
    /// other slot as it was. The model is built over the request's settings with the live
    /// capability: it holds no state of its own beyond an observation counter.
    private static func writePillDesign(
      _ value: Any, holdingWords: Bool, context: WriteContext, to settings: SettingsManager
    ) -> SetOutcome {
      guard let design = Codec.raw(value, RecordingPillDesign.self) else {
        return .refused(code: "badValue", message: "wrong type or unknown value")
      }
      guard PillCatalog.designs(holdingWords: holdingWords).contains(design) else {
        return .refused(
          code: "checkFailed",
          message: "that design belongs to the other pill slot; the picker never puts it here")
      }
      let model = PillAppearanceModel(settings: settings, capability: context.pillWordsCapability)
      let capability = model.wordsCapability
      guard model.offersCoupled(design, capability: capability) else {
        return .refused(
          code: "checkFailed",
          message: "the pill picker does not offer that design right now (\(capability))")
      }
      model.chooseCoupled(design)
      return .written(forced: false)
    }

    /// `channel.set`: the Audio screen's input-socket pick for one CONNECTED device, offered
    /// only when that device has a readable UID and more than one input
    /// (`InputChannelSettings`), and only an input it has. Other devices' saved inputs are
    /// untouched and no device is selected. The screen shows the row for the device in use;
    /// the door can stage any connected multi-input device.
    static func setChannel(
      _ channel: Int, for uid: String, context: WriteContext, to settings: SettingsManager
    ) -> SetOutcome {
      guard let count = context.inputChannelCounts()[uid] else {
        return .refused(code: "checkFailed", message: "no connected input device has that UID")
      }
      guard InputChannelSettings.offersChoice(uid: uid, inputChannelCount: count) else {
        return .refused(code: "checkFailed", message: "that device has one input; the row is not offered")
      }
      guard InputChannelSettings.offers(channel, inputChannelCount: count) else {
        return .refused(code: "checkFailed", message: "that device has inputs 0 to \(count - 1)")
      }
      attributed(settings) { InputChannelSettings.choose(channel, for: uid, in: settings) }
      return .written(forced: false)
    }

    /// `language.set`: the language picker's choice, `code` naming one of its rows
    /// (`LanguageCatalog.pickerEntries`, English (UK) included as `en-gb`) or `auto`. The
    /// row's lock code must be one the SELECTED engine's picker offers
    /// (`LanguageLockOptions.lockableCodes(for:)`, nil = no restriction). The choice then goes
    /// through `LanguageLockOptions.apply`, which writes the spelling before the lock and
    /// keeps the stored spelling for a non-English row or Auto.
    static func setLanguage(_ code: String, to settings: SettingsManager) -> SetOutcome {
      let entry: LanguageCatalog.Entry?
      if code == "auto" {
        entry = nil
      } else {
        // Never `LanguageCatalog.entry(for:)`: it invents a row for an unknown code.
        guard let found = LanguageCatalog.pickerEntries.first(where: { $0.code == code }) else {
          return .refused(code: "badValue", message: "no language picker row has that code")
        }
        if !LanguageLockOptions.isLockHonoured(found.lockCode, by: settings.selectedBackend) {
          return .refused(
            code: "checkFailed",
            message: "the \(settings.selectedBackend.rawValue) language picker does not offer that language")
        }
        entry = found
      }
      attributed(settings) { _ = LanguageLockOptions.apply(entry, to: settings) }
      return .written(forced: false)
    }

    private static func outcome(_ written: WriteOutcome) -> SetOutcome {
      switch written {
      case .written(let forced): return .written(forced: forced)
      case .badValue(let message): return .refused(code: "badValue", message: message)
      }
    }

    /// The screen's model menu offers the surface's provider's discovered models in the
    /// recommended, other and hosted groups and disables the locked ones
    /// (`OllamaModelPickerPresentation.groups`); the same groups decide here, and the pick
    /// is written the way the menu writes it (`PolishSettings.setCloudModel`).
    private static func writeModel(
      _ value: Any, surface: ProviderSetupSurface, context: WriteContext,
      to settings: SettingsManager
    ) -> SetOutcome {
      guard let id = Codec.string(value) else {
        return .refused(code: "badValue", message: "wrong type or unknown value")
      }
      let provider = PolishSettings.provider(on: surface, in: settings)
      guard !fixedModelProviders.contains(provider) else {
        return .refused(code: "badValue", message: "the current provider has a fixed model")
      }
      var catalog = context.modelCatalog()
      if catalog.provider != provider || catalog.models.isEmpty {
        context.loadCachedModelCatalog(provider, surface)
        catalog = context.modelCatalog()
      }
      guard catalog.provider == provider, !catalog.models.isEmpty else {
        return .refused(
          code: "catalogUnavailable",
          message:
            "no usable cached model catalog for the current provider; discover its models in the app first, then retry")
      }
      // #4287: the same offered list the surface's menu shows (the summary surface leaves
      // out the first-party Ollama models).
      let groups = OllamaModelPickerPresentation.groups(
        from: surface.offeredModels(catalog.models, provider: provider), provider: provider)
      let offered = (groups.recommended + groups.other + groups.hosted).map(\.id)
      guard offered.contains(id) else {
        let locked = groups.locked.contains { $0.id == id }
        return .refused(
          code: "badValue",
          message: locked ? "that model is not available with this key" : "no such model")
      }
      PolishSettings.setCloudModel(id, on: surface, in: settings)
      return .written(forced: false)
    }

    /// An ordinary spoken-punctuation write: `enabled` is assigned directly; the override
    /// map is the complete desired set of start words. Every entry is validated first by
    /// the same owner that validates stored overrides at launch
    /// (`SpokenPunctuationRules.validatedStartWords`, which drops what it refuses); if any
    /// entry would be dropped, nothing changes. Then each entry goes through
    /// `commitSpokenPunctuationStartWord` (normalization, sparse defaults) and each override
    /// absent from the request through `resetSpokenPunctuationStartWord`.
    private static func writeSpokenPunctuation(_ value: Any, to settings: SettingsManager)
      -> SetOutcome
    {
      guard let candidate = Codec.spokenPunctuation(value) else {
        return .refused(
          code: "badValue", message: "expected exactly \(Codec.spokenPunctuationShape)")
      }
      let requested = candidate.startWordOverrides
      let baseCodes = requested.keys.allSatisfy { LanguageNormalizer.baseCode($0) == $0 }
      let validated = SpokenPunctuationRules.validatedStartWords(requested, dropDefaults: false)
      guard baseCodes, Set(validated.keys) == Set(requested.keys) else {
        return .refused(
          code: "checkFailed", message: "a start word or language code was refused")
      }
      // A regional key can only have been staged by force; the reset owner normalizes the
      // language and cannot find it, so a "complete set" write could not remove it.
      guard
        settings.spokenPunctuation.startWordOverrides.keys.allSatisfy({
          LanguageNormalizer.baseCode($0) == $0
        })
      else {
        return .refused(
          code: "checkFailed",
          message:
            "stored start-word keys cannot be reset through the checked owner; use force to replace the staged map"
        )
      }
      if settings.spokenPunctuation.enabled != candidate.enabled {
        settings.spokenPunctuation.enabled = candidate.enabled
      }
      if settings.spokenPunctuation.englishPeriodWord != candidate.englishPeriodWord {
        settings.spokenPunctuation.englishPeriodWord = candidate.englishPeriodWord
      }
      for language in requested.keys.sorted() {
        settings.commitSpokenPunctuationStartWord(requested[language] ?? "", language: language)
      }
      for language in settings.spokenPunctuation.startWordOverrides.keys.sorted()
      where requested[language] == nil {
        settings.resetSpokenPunctuationStartWord(language: language)
      }
      return .written(forced: false)
    }

    /// The silence detector turns the timeout into a chunk count with
    /// `Int(ceil(timeout / chunkDuration))`, which traps when the quotient is not
    /// representable. A finite value whose count is representable is admitted even far
    /// outside the screen's 0.5-3.0 range.
    nonisolated static func silenceTimeoutIsConvertible(_ seconds: Double) -> Bool {
      guard seconds.isFinite else { return false }
      let chunkDuration = Double(SilenceDetector.chunkSize) / AudioConstants.sampleRate
      return Int(exactly: ceil(seconds / chunkDuration)) != nil
    }

    // MARK: - JSON codec

    /// Strict JSON-to-Swift decoding. Foundation's bridging casts are permissive
    /// (`true as? Int` and `1 as? Bool` both succeed on `NSNumber`), so every number is
    /// checked for its boolean-ness and float-ness first.
    enum Codec {
      static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
      }

      static func bool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
      }

      static func string(_ value: Any) -> String? { value as? String }

      static func double(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
      }

      static func float(_ value: Any) -> Float? {
        guard let double = double(value) else { return nil }
        let float = Float(double)
        return float.isFinite ? float : nil
      }

      /// The JSON number as exactly `T`, or nil when it is a boolean, has a fraction, or is
      /// out of `T`'s range. Decoding the number's own JSON text with `JSONDecoder` gives
      /// exact range checks: `int64Value` on an unsigned 64-bit number silently wraps.
      static func exactInteger<T: FixedWidthInteger & Decodable>(_ value: Any, _: T.Type) -> T? {
        guard let number = value as? NSNumber, !isBoolean(number),
          let data = try? JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
      }

      static func uint16(_ value: Any) -> UInt16? {
        exactInteger(value, UInt16.self)
      }

      static func modifiers(_ value: Any) -> NSEvent.ModifierFlags? {
        exactInteger(value, UInt.self).map { NSEvent.ModifierFlags(rawValue: $0) }
      }

      static func raw<E: RawRepresentable>(_ value: Any, _: E.Type) -> E?
      where E.RawValue == String {
        (value as? String).flatMap(E.init(rawValue:))
      }

      /// `null` clears; a string must name a case. Returned double-wrapped so `set` can
      /// tell "decoded to nil" from "did not decode".
      static func optionalRaw<E: RawRepresentable>(_ value: Any, _: E.Type) -> E??
      where E.RawValue == String {
        if value is NSNull { return .some(nil) }
        guard let decoded = raw(value, E.self) else { return nil }
        return .some(decoded)
      }

      /// `{"mode":"auto"}` or `{"mode":"locked","code":"<language code>"}`, the shape
      /// `LanguageMode` persists.
      static func languageMode(_ value: Any) -> LanguageMode? {
        guard let object = value as? [String: Any], let mode = object["mode"] as? String else {
          return nil
        }
        switch mode {
        case "auto":
          return object.count == 1 ? .auto : nil
        case "locked":
          guard object.count == 2, let code = object["code"] as? String else {
            return nil
          }
          return .locked(code)
        default:
          return nil
        }
      }

      static func encode(_ mode: LanguageMode) -> [String: Any] {
        switch mode {
        case .auto: return ["mode": "auto"]
        case .locked(let code): return ["mode": "locked", "code": code]
        }
      }

      /// `{"enabled": Bool, "startWordOverrides": {language: word}, "englishPeriodWord": Bool}`.
      /// All three keys are required (#4216), so a caller written for the old two-key shape is
      /// refused rather than silently resetting the period switch.
      static let spokenPunctuationShape =
        #"{"enabled": Bool, "startWordOverrides": {language: word}, "englishPeriodWord": Bool}"#

      static func spokenPunctuation(_ value: Any) -> SpokenPunctuationSettings? {
        guard let object = value as? [String: Any], object.count == 3,
          let enabledValue = object["enabled"], let enabled = bool(enabledValue),
          let overrides = object["startWordOverrides"] as? [String: Any],
          let periodValue = object["englishPeriodWord"], let periodWord = bool(periodValue)
        else { return nil }
        var words: [String: String] = [:]
        for (language, word) in overrides {
          guard let word = word as? String else { return nil }
          words[language] = word
        }
        return SpokenPunctuationSettings(
          enabled: enabled, startWordOverrides: words, englishPeriodWord: periodWord)
      }

      static func encode(_ settings: SpokenPunctuationSettings) -> [String: Any] {
        [
          "enabled": settings.enabled, "startWordOverrides": settings.startWordOverrides,
          "englishPeriodWord": settings.englishPeriodWord,
        ]
      }

      /// `{deviceUID: channel}` with integer channels.
      static func channelMap(_ value: Any) -> [String: Int]? {
        guard let object = value as? [String: Any] else { return nil }
        var map: [String: Int] = [:]
        for (uid, channel) in object {
          guard let channel = exactInteger(channel, Int.self) else { return nil }
          map[uid] = channel
        }
        return map
      }
    }
  }
#endif
