import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

// MARK: - LanguageNormalizer

@Suite("Apple Intelligence: LanguageNormalizer")
struct LanguageNormalizerTests {

  @Test("base codes stable for common ISO 639-1 inputs")
  func baseCodesStable() {
    #expect(LanguageNormalizer.baseCode("en") == "en")
    #expect(LanguageNormalizer.baseCode("de") == "de")
    #expect(LanguageNormalizer.baseCode("fr") == "fr")
    #expect(LanguageNormalizer.baseCode("it") == "it")
    #expect(LanguageNormalizer.baseCode("ja") == "ja")
    #expect(LanguageNormalizer.baseCode("ko") == "ko")
  }

  @Test("BCP-47 region tags strip to base")
  func regionTagsStrip() {
    #expect(LanguageNormalizer.baseCode("de-DE") == "de")
    #expect(LanguageNormalizer.baseCode("de_DE") == "de")
    #expect(LanguageNormalizer.baseCode("ko-KR") == "ko")
    #expect(LanguageNormalizer.baseCode("pt-BR") == "pt")
    #expect(LanguageNormalizer.baseCode("en-US") == "en")
    #expect(LanguageNormalizer.baseCode("en-GB") == "en")
  }

  @Test("Chinese variants collapse to zh")
  func chineseCollapses() {
    #expect(LanguageNormalizer.baseCode("cmn-CN") == "zh")
    #expect(LanguageNormalizer.baseCode("zh-Hans") == "zh")
    #expect(LanguageNormalizer.baseCode("zh-Hant") == "zh")
    #expect(LanguageNormalizer.baseCode("zh-Hans-CN") == "zh")
    #expect(LanguageNormalizer.baseCode("yue") == "zh")
    #expect(LanguageNormalizer.baseCode("cmn") == "zh")
  }

  @Test("Norwegian variants collapse to no")
  func norwegianCollapses() {
    #expect(LanguageNormalizer.baseCode("nb") == "no")
    #expect(LanguageNormalizer.baseCode("nn") == "no")
    #expect(LanguageNormalizer.baseCode("nb-NO") == "no")
  }

  @Test("invalid and empty inputs return nil")
  func invalidInputsReturnNil() {
    #expect(LanguageNormalizer.baseCode(nil) == nil)
    #expect(LanguageNormalizer.baseCode("") == nil)
    #expect(LanguageNormalizer.baseCode("   ") == nil)
    #expect(LanguageNormalizer.baseCode("und") == nil)
    #expect(LanguageNormalizer.baseCode("1") == nil)  // single char
    #expect(LanguageNormalizer.baseCode("abcd") == nil)  // too long
  }

  @Test("case-insensitive normalization")
  func caseInsensitive() {
    #expect(LanguageNormalizer.baseCode("DE") == "de")
    #expect(LanguageNormalizer.baseCode("En-Gb") == "en")
    #expect(LanguageNormalizer.baseCode("ZH-HANS") == "zh")
  }

  @Test("unknown 2-char code passes through")
  func unknownCodePassesThrough() {
    // Accepted by the normalizer; will fail the supportedLanguages allowlist.
    #expect(LanguageNormalizer.baseCode("xx") == "xx")
  }
}

// MARK: - AppleIntelligenceCapabilities

@Suite("Apple Intelligence: documented allowlist")
struct AppleIntelligenceCapabilitiesTests {

  @Test("allowlist covers Apple's documented 2026 languages")
  func coversDocumentedLanguages() {
    let expected: Set<String> = [
      "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh",
      "nl", "sv", "tr", "da", "no", "vi",
    ]
    #expect(AppleIntelligenceCapabilities.documentedSupportedLanguages == expected)
  }

  @Test("allowlist excludes known-unsupported languages")
  func excludesUnsupported() {
    let known = AppleIntelligenceCapabilities.documentedSupportedLanguages
    for lang in ["ar", "he", "ru", "uk", "pl", "th", "ta", "hi"] {
      #expect(!known.contains(lang), "documented fallback must NOT include \(lang)")
    }
  }
}

// MARK: - LLMProviderConfig threading

@Suite("LLMProviderConfig: detectedLanguage")
struct LLMProviderConfigDetectedLanguageTests {

  @Test("default init leaves detectedLanguage nil")
  func defaultsToNil() {
    let config = LLMProviderConfig(
      model: "x",
      apiKeyKeychainId: nil,
      maxTokens: 100,
      temperature: 0,
      thinkingBudget: nil,
      reasoningEffort: nil
    )
    #expect(config.detectedLanguage == nil)
  }

  @Test("explicit value round-trips through init")
  func explicitValueRoundTrips() {
    let config = LLMProviderConfig(
      model: "x",
      apiKeyKeychainId: nil,
      maxTokens: 100,
      temperature: 0,
      thinkingBudget: nil,
      reasoningEffort: nil,
      detectedLanguage: "de"
    )
    #expect(config.detectedLanguage == "de")
  }

  @Test("Codable auto-synthesis decodes legacy JSON without detectedLanguage")
  func codableBackwardCompat() throws {
    let legacyJSON = """
      {
          "model": "gpt-4o-mini",
          "apiKeyKeychainId": null,
          "maxTokens": 500,
          "temperature": 0.0,
          "thinkingBudget": null,
          "reasoningEffort": null
      }
      """
    let data = Data(legacyJSON.utf8)
    let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
    #expect(decoded.detectedLanguage == nil)
    #expect(decoded.model == "gpt-4o-mini")
  }

  @Test("Codable round-trip preserves detectedLanguage")
  func codableRoundTrip() throws {
    let original = LLMProviderConfig(
      model: "x",
      apiKeyKeychainId: nil,
      maxTokens: 100,
      temperature: 0,
      thinkingBudget: nil,
      reasoningEffort: nil,
      detectedLanguage: "ja"
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: encoded)
    #expect(decoded.detectedLanguage == "ja")
  }
}

// MARK: - OutputLanguageValidator

@Suite("Apple Intelligence: output language validation")
struct OutputLanguageValidatorTests {

  @Test("fails open on short output (<24 letters)")
  func failsOpenOnShort() throws {
    // 10-letter English string with expected=de should NOT throw.
    try OutputLanguageValidator.validate(polished: "Hi there!", expectedBase: "de")
  }

  @Test("fails closed on strong language drift (de expected, English long output)")
  func failsClosedOnDrift() {
    let longEnglish =
      "So for the trip I need my passport and my charger and my headphones and also my sunglasses."
    do {
      try OutputLanguageValidator.validate(polished: longEnglish, expectedBase: "de")
      Issue.record("expected LLMError.outputLanguageDrift, got no throw")
    } catch let LLMError.outputLanguageDrift(expected, actual) {
      #expect(expected == "de")
      #expect(actual == "en")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test("passes when output matches expected language")
  func passesOnMatch() throws {
    // Long German sentence where NL recognizer should identify German.
    let germanText =
      "Also für die Reise brauche ich meinen Pass und mein Ladegerät und meine Kopfhörer und ach ja meine Sonnenbrille."
    try OutputLanguageValidator.validate(polished: germanText, expectedBase: "de")
  }

  @Test("Chinese dominance normalizes to zh")
  func chineseNormalizes() throws {
    // Chinese paragraph. The recognizer may emit zh-Hans or similar; the
    // validator must normalize both sides to base `zh` before comparing.
    let chinese = "我今天早上去咖啡店买了一杯拿铁然后就回家了准备开始工作。"
    try OutputLanguageValidator.validate(polished: chinese, expectedBase: "zh")
  }
}

// MARK: - Preflight gate (FoundationModels-conditional)

#if canImport(FoundationModels)
  import FoundationModels

  @Suite(.serialized)
  struct AppleIntelligencePreflightGateTests {

    /// Scoped override with defer-based restoration. All tests that tweak the
    /// provider MUST use this helper to prevent state leak across parallel
    /// runs or between tests. Callable only under a macOS 26 availability
    /// guard because `supportedLanguageProvider` is `@available(macOS 26.0, *)`.
    @available(macOS 26.0, *)
    private func withSupportedLanguages<T>(
      _ langs: Set<String>,
      perform: () async throws -> T
    ) async rethrows -> T {
      let previous = AppleIntelligenceConnector.supportedLanguageProvider
      AppleIntelligenceConnector.supportedLanguageProvider = { langs }
      defer { AppleIntelligenceConnector.supportedLanguageProvider = previous }
      return try await perform()
    }

    private func makeConfig(detectedLanguage: String?) -> LLMProviderConfig {
      LLMProviderConfig(
        model: "apple-intelligence",
        apiKeyKeychainId: nil,
        maxTokens: 500,
        temperature: 0,
        thinkingBudget: nil,
        reasoningEffort: nil,
        detectedLanguage: detectedLanguage
      )
    }

    @Test("preflight gate throws unsupportedInputLanguage for language not in allowlist")
    func preflightRejectsUnsupported() async throws {
      guard #available(macOS 26.0, *) else { return }
      guard SystemLanguageModel.default.availability == .available else { return }
      try await withSupportedLanguages(["en", "fr"]) {
        let connector = AppleIntelligenceConnector()
        let config = makeConfig(detectedLanguage: "ar")
        do {
          _ = try await connector.polish(
            text: "Testing Arabic input.",
            instructions: .default,
            config: config,
            onToken: nil
          )
          Issue.record("expected unsupportedInputLanguage throw, got success")
        } catch LLMError.unsupportedInputLanguage(let code) {
          #expect(code == "ar")
        } catch {
          Issue.record("unexpected error: \(error)")
        }
      }
    }

    @Test("preflight gate normalizes BCP-47 before allowlist lookup")
    func preflightNormalizesBCP47() async throws {
      guard #available(macOS 26.0, *) else { return }
      guard SystemLanguageModel.default.availability == .available else { return }
      try await withSupportedLanguages(["en", "de"]) {
        let connector = AppleIntelligenceConnector()
        let config = makeConfig(detectedLanguage: "ar-SA")
        do {
          _ = try await connector.polish(
            text: "Testing.",
            instructions: .default,
            config: config,
            onToken: nil
          )
          Issue.record("expected throw for ar-SA, got success")
        } catch LLMError.unsupportedInputLanguage(let code) {
          #expect(code == "ar")
        } catch {
          Issue.record("preflight should have fired for ar, got \(error)")
        }
      }
    }

    @Test("preflight gate allows nil detectedLanguage (Parakeet path)")
    func preflightAllowsNil() async throws {
      guard #available(macOS 26.0, *) else { return }
      // #881 TO-2: honest skip on hosts without the on-device model. Without
      // this guard the `frameworkUnavailable` throw fires first and the broad
      // `catch {}` below swallows it — a silent false-green that never actually
      // exercised the nil short-circuit. Mirrors the two sibling preflight
      // tests (preflightRejectsUnsupported, preflightNormalizesBCP47).
      guard SystemLanguageModel.default.availability == .available else { return }
      try await withSupportedLanguages(["en"]) {
        let connector = AppleIntelligenceConnector()
        let config = makeConfig(detectedLanguage: nil)
        do {
          _ = try await connector.polish(
            text: "Hello world testing one two three.",
            instructions: .default,
            config: config,
            onToken: nil
          )
        } catch LLMError.unsupportedInputLanguage {
          Issue.record("preflight must not fire for nil detectedLanguage")
        } catch {
          // Any other failure (framework unavailable, empty, etc.) is
          // outside this gate's concern. The preflight is the only
          // behavior under test here.
        }
      }
    }
  }
#endif
