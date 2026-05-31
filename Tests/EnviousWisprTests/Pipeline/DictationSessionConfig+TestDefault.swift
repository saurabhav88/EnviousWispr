import EnviousWisprCore

extension DictationSessionConfig {
  /// Default snapshot for tests that don't care about specific settings values.
  /// A deterministic test baseline (polish OFF, no on-device-AI dependency in CI)
  /// — NOT a mirror of the production `SettingsManager` defaults, which default
  /// polish to Apple Intelligence and emoji on (#923, SettingsDefaultValues).
  static func testDefault(
    autoCopyToClipboard: Bool = true,
    inputMode: RecordingMode = .pushToTalk,
    triggerSource: TriggerSource = .programmatic,
    autoPasteToActiveApp: Bool = false,
    restoreClipboardAfterPaste: Bool = false,
    vadAutoStop: Bool = false,
    vadSilenceTimeout: Double = 1.5,
    vadSensitivity: Float = 0.5,
    vadEnergyGate: Bool = false,
    languageMode: LanguageMode = .auto,
    useStreamingASR: Bool = true,
    modelUnloadPolicy: ModelUnloadPolicy = .never,
    llmProvider: LLMProvider = .none,
    llmModel: String = "",
    polishInstructions: PolishInstructions = .default,
    useExtendedThinking: Bool = false,
    selectedInputDeviceUID: String = "",
    preferredInputDeviceIDOverride: String = ""
  ) -> DictationSessionConfig {
    DictationSessionConfig(
      autoCopyToClipboard: autoCopyToClipboard,
      inputMode: inputMode,
      triggerSource: triggerSource,
      autoPasteToActiveApp: autoPasteToActiveApp,
      restoreClipboardAfterPaste: restoreClipboardAfterPaste,
      vadAutoStop: vadAutoStop,
      vadSilenceTimeout: vadSilenceTimeout,
      vadSensitivity: vadSensitivity,
      vadEnergyGate: vadEnergyGate,
      languageMode: languageMode,
      useStreamingASR: useStreamingASR,
      modelUnloadPolicy: modelUnloadPolicy,
      llmProvider: llmProvider,
      llmModel: llmModel,
      polishInstructions: polishInstructions,
      useExtendedThinking: useExtendedThinking,
      selectedInputDeviceUID: selectedInputDeviceUID,
      preferredInputDeviceIDOverride: preferredInputDeviceIDOverride
    )
  }
}
