import EnviousWisprCore
import Testing

@Suite("DictationSessionConfig — per-recording snapshot")
struct DictationSessionConfigTests {

  @Test("per-field overrides survive construction intact")
  func testFieldOverridesHonored() {
    let config = DictationSessionConfig.testDefault(
      autoCopyToClipboard: false,
      autoPasteToActiveApp: true,
      smartInsertion: true,
      vadAutoStop: true,
      vadSilenceTimeout: 3.0,
      vadSensitivity: 0.8,
      languageMode: .locked("es"),
      useStreamingASR: false,
      llmProvider: .appleIntelligence,
      llmModel: "apple-intelligence",
      selectedInputDeviceUID: "BuiltInMic",
      preferredInputDeviceIDOverride: "ExternalMic",
      s1Control: S1ControlSettings(styling: .casual, structure: .prose, context: .email)
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
    #expect(config.selectedInputDeviceUID == "BuiltInMic")
    #expect(config.preferredInputDeviceIDOverride == "ExternalMic")
    #expect(config.smartInsertion == true)
    #expect(
      config.s1Control == S1ControlSettings(styling: .casual, structure: .prose, context: .email))
  }

  @Test(
    "lockedLanguageCode: locked returns the code, auto returns nil (issue #2259 shared authority)"
  )
  func testLockedLanguageCode() {
    let locked = DictationSessionConfig.testDefault(languageMode: .locked("de"))
    #expect(locked.lockedLanguageCode == "de")
    let auto = DictationSessionConfig.testDefault(languageMode: .auto)
    #expect(auto.lockedLanguageCode == nil)
  }
}
