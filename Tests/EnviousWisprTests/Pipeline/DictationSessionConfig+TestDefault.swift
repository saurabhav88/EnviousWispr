import EnviousWisprCore

extension DictationSessionConfig {
  /// Default snapshot for tests that don't care about specific settings values.
  /// Mirrors the `SettingsManager` defaults at construction time.
  static func testDefault(
    autoCopyToClipboard: Bool = true,
    inputMode: RecordingMode = .pushToTalk,
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
