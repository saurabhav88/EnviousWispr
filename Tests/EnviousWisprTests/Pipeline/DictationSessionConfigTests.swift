import EnviousWisprCore
import Testing

@Suite("DictationSessionConfig — per-recording snapshot")
struct DictationSessionConfigTests {

  @Test("testDefault factory returns SettingsManager-default-shaped values")
  func testDefaultIsShapedLikeSettingsDefaults() {
    let config = DictationSessionConfig.testDefault()

    #expect(config.autoCopyToClipboard == true)
    #expect(config.autoPasteToActiveApp == false)
    #expect(config.restoreClipboardAfterPaste == false)
    #expect(config.vadAutoStop == false)
    #expect(config.vadSilenceTimeout == 1.5)
    #expect(config.vadSensitivity == 0.5)
    #expect(config.vadEnergyGate == false)
    #expect(config.languageMode == .auto)
    #expect(config.useStreamingASR == true)
    #expect(config.modelUnloadPolicy == .never)
    #expect(config.llmProvider == .none)
    #expect(config.llmModel == "")
    #expect(config.polishInstructions.systemPrompt == PolishInstructions.default.systemPrompt)
    #expect(config.useExtendedThinking == false)
    #expect(config.selectedInputDeviceUID == "")
    #expect(config.preferredInputDeviceIDOverride == "")
  }

  @Test("per-field overrides survive construction intact")
  func testFieldOverridesHonored() {
    let config = DictationSessionConfig.testDefault(
      autoCopyToClipboard: false,
      autoPasteToActiveApp: true,
      vadAutoStop: true,
      vadSilenceTimeout: 3.0,
      vadSensitivity: 0.8,
      languageMode: .locked("es"),
      useStreamingASR: false,
      llmProvider: .appleIntelligence,
      llmModel: "apple-intelligence",
      useExtendedThinking: true,
      selectedInputDeviceUID: "BuiltInMic",
      preferredInputDeviceIDOverride: "ExternalMic"
    )

    #expect(config.autoCopyToClipboard == false)
    #expect(config.autoPasteToActiveApp == true)
    #expect(config.vadAutoStop == true)
    #expect(config.vadSilenceTimeout == 3.0)
    #expect(config.vadSensitivity == 0.8)
    #expect(config.languageMode == LanguageMode.locked("es"))
    #expect(config.useStreamingASR == false)
    #expect(config.llmProvider == LLMProvider.appleIntelligence)
    #expect(config.llmModel == "apple-intelligence")
    #expect(config.useExtendedThinking == true)
    #expect(config.selectedInputDeviceUID == "BuiltInMic")
    #expect(config.preferredInputDeviceIDOverride == "ExternalMic")
  }

  @Test("Sendable value semantics — modifying a copy's source does not mutate the snapshot")
  func testValueSemantics() {
    var sourceFlag = true
    let config = DictationSessionConfig.testDefault(autoCopyToClipboard: sourceFlag)
    sourceFlag = false
    #expect(config.autoCopyToClipboard == true)
  }
}
