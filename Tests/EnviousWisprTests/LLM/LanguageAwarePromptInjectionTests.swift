import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Multilingual v1 (W3): confidence-tiered + language-aware prompt injection.
///
/// Exercises the `PromptVocabulary` filter, the `DefaultPromptPlanner` tier
/// policy, and the script-mismatch guardrail. The goal is to freeze the
/// spec-mandated behavior:
///
/// - Tier `.locked` or `.highAuto`: global + perLanguage[detected]
/// - Tier `.mediumAuto`: global only
/// - Tier `.lowAuto` or `.abstain`: nothing
/// - Non-Latin detected lang strips Latin-only perLanguage terms; global survives
/// - Migration of legacy `[CustomWord]` puts everything in `global`
/// - Detected lang without a perLanguage entry falls back to global-only
@Suite("Multilingual v1 W3 Prompt Injection")
struct LanguageAwarePromptInjectionTests {

  // MARK: - Helpers

  private func detection(
    lang: String?,
    tier: LanguageConfidenceTier
  ) -> LanguageDetectionResult {
    LanguageDetectionResult(
      lang: lang,
      confidence: tier == .highAuto ? 0.9 : (tier == .mediumAuto ? 0.7 : 0.3),
      margin: tier == .highAuto ? 0.3 : (tier == .mediumAuto ? 0.22 : 0.05),
      tier: tier,
      voicedDuration: 3.0,
      abstained: tier == .abstain,
      usedSessionPrior: false
    )
  }

  private func input(
    customWords: [CustomWord] = [],
    customVocabulary: PromptVocabulary? = nil,
    detection: LanguageDetectionResult?,
    backend: ASRBackendType? = nil,
    provider: LLMProvider = .openAI,
    modelID: String = "gpt-4o-mini",
    transcript: String =
      "This is a reasonably long transcript used to exercise the prompt planner filter."
  ) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: provider,
      modelID: modelID,
      appName: nil,
      language: nil,
      polishVocabulary: PolishVocabulary(terms: customWords, generation: 0),
      focusSnapshot: nil,
      customVocabulary: customVocabulary,
      languageDetection: detection,
      backend: backend
    )
  }

  // MARK: - Tier policy

  @Test("locked tier: global + perLanguage[detected] both injected")
  func lockedInjectsEverything() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr", "Claude"],
      perLanguage: ["ja": ["ビデオ", "日本語"]]
    )
    let result = DefaultPromptPlanner.filterCustomWords(
      [],
      tier: .locked,
      allowedStrings: Set(vocab.effectiveTerms(detectedLang: "ja", tier: .locked))
    )
    let canonicals = Set(result.map(\.canonical))
    #expect(canonicals.contains("EnviousWispr"))
    #expect(canonicals.contains("Claude"))
    #expect(canonicals.contains("ビデオ"))
    #expect(canonicals.contains("日本語"))
  }

  @Test("highAuto tier: global + perLanguage[detected] both injected")
  func highAutoInjectsEverything() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["de": ["Überlegung", "Schüssel"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "de", tier: .highAuto)
    #expect(Set(terms) == Set(["EnviousWispr", "Überlegung", "Schüssel"]))
  }

  @Test("mediumAuto tier: ONLY global, NO perLanguage lexicon")
  func mediumAutoInjectsGlobalOnly() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr", "Claude"],
      perLanguage: ["de": ["Überlegung"], "ja": ["日本語"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "de", tier: .mediumAuto)
    #expect(Set(terms) == Set(["EnviousWispr", "Claude"]))
  }

  @Test("lowAuto tier: NO lexical injection at all")
  func lowAutoInjectsNothing() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["de": ["Überlegung"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "de", tier: .lowAuto)
    #expect(terms.isEmpty)
  }

  @Test("abstain tier: NO lexical injection at all")
  func abstainInjectsNothing() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["ja": ["日本語"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: nil, tier: .abstain)
    #expect(terms.isEmpty)
  }

  // MARK: - Script guardrail

  @Test("script guardrail: strips Latin-only terms from non-Latin perLanguage list")
  func scriptGuardrailStripsLatinFromJapanese() {
    let vocab = PromptVocabulary(
      global: [],
      // Japanese perLanguage bucket with a stray Latin-only term
      // (shouldn't be there, but user config is untrusted).
      perLanguage: ["ja": ["ビデオ", "video", "日本語", "latinonly"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "ja", tier: .locked)
    #expect(terms.contains("ビデオ"))
    #expect(terms.contains("日本語"))
    #expect(!terms.contains("video"), "Latin-only term should be stripped for non-Latin lang")
    #expect(!terms.contains("latinonly"))
  }

  @Test("script guardrail: keeps global terms regardless of their script")
  func scriptGuardrailKeepsGlobalRegardless() {
    let vocab = PromptVocabulary(
      // Global is always safe: Latin product names + a Japanese term.
      global: ["EnviousWispr", "Claude", "ビデオ"],
      perLanguage: ["ja": ["日本語"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "ja", tier: .locked)
    // Every global entry survives.
    #expect(terms.contains("EnviousWispr"))
    #expect(terms.contains("Claude"))
    #expect(terms.contains("ビデオ"))
    #expect(terms.contains("日本語"))
  }

  @Test("script guardrail: does NOT strip Latin terms for Latin-script langs")
  func scriptGuardrailLatinLangKeepsLatin() {
    let vocab = PromptVocabulary(
      global: [],
      perLanguage: ["de": ["Kaffee", "coffee"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "de", tier: .locked)
    #expect(Set(terms) == Set(["Kaffee", "coffee"]))
  }

  @Test(
    "script guardrail: strips Latin-extended terms (ß, é, ñ, ế) from non-Latin perLanguage list")
  func scriptGuardrailStripsLatinExtendedFromJapanese() {
    // Codex audit (Major #4): the earlier isAllLatinAscii check missed
    // German ß, Spanish ñ, Vietnamese tone-marked letters, French
    // accented letters. Those SHOULD be classified as Latin and stripped
    // from non-Latin perLanguage lists. isAllLatinScript fixes this.
    let vocab = PromptVocabulary(
      global: [],
      perLanguage: [
        "ja": [
          "日本語",  // Japanese: keep
          "ビデオ",  // Katakana: keep
          "straße",  // German with ß: Latin, should strip
          "niño",  // Spanish with ñ: Latin, should strip
          "français",  // French with ç: Latin, should strip
          "Tiếng Việt",  // Vietnamese: Latin script, should strip
          "Türkçe",  // Turkish: Latin, should strip
        ]
      ]
    )
    let terms = vocab.effectiveTerms(detectedLang: "ja", tier: .locked)
    #expect(terms.contains("日本語"))
    #expect(terms.contains("ビデオ"))
    #expect(!terms.contains("straße"), "German ß is still Latin-script")
    #expect(!terms.contains("niño"), "Spanish ñ is still Latin-script")
    #expect(!terms.contains("français"), "French ç is still Latin-script")
    #expect(!terms.contains("Tiếng Việt"), "Vietnamese tone marks are Latin-extended")
    #expect(!terms.contains("Türkçe"), "Turkish dotted chars are Latin-extended")
  }

  // MARK: - Migration

  @Test("fromLegacy: all CustomWords go into global, perLanguage is empty")
  func migrationPutsAllInGlobal() {
    let words = [
      CustomWord(canonical: "EnviousWispr"),
      CustomWord(canonical: "Claude"),
      CustomWord(canonical: "WhisperKit"),
    ]
    let vocab = PromptVocabulary.fromLegacy(words)
    #expect(Set(vocab.global) == Set(["EnviousWispr", "Claude", "WhisperKit"]))
    #expect(vocab.perLanguage.isEmpty)
  }

  @Test("fromLegacy empty list produces empty vocabulary")
  func migrationEmptyIsEmpty() {
    let vocab = PromptVocabulary.fromLegacy([])
    #expect(vocab.isEmpty)
  }

  // MARK: - Fallbacks

  @Test("no perLanguage key for detected lang falls back to global-only")
  func missingPerLanguageFallsBackToGlobal() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["ja": ["日本語"]]
    )
    // Detected lang is German; no "de" key present.
    let terms = vocab.effectiveTerms(detectedLang: "de", tier: .locked)
    #expect(terms == ["EnviousWispr"])
  }

  @Test("unsupported perLanguage key is defensively skipped")
  func unsupportedLanguageSkipped() {
    // "xx" is not a Whisper-supported ISO code; should be silently ignored.
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["xx": ["bogus"]]
    )
    let terms = vocab.effectiveTerms(detectedLang: "xx", tier: .locked)
    // Only the global survives. The "xx" bucket is not treated as valid.
    #expect(terms == ["EnviousWispr"])
  }

  // MARK: - DefaultPromptPlanner integration

  @Test("planner nil detection preserves legacy customWords verbatim")
  func plannerLegacyPathPassesThrough() {
    // No languageDetection means "not wired yet". Planner should leave
    // customWords untouched so untouched callsites behave as before.
    let words = [CustomWord(canonical: "EnviousWispr", aliases: ["Envious Whisper"])]
    let built = input(customWords: words, detection: nil)
    let plan = DefaultPromptPlanner().plan(input: built)
    // Envelope system prompt should still contain the CUSTOM VOCABULARY
    // block with the alias hint preserved.
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("Envious Whisper"), "aliases preserved on legacy path")
  }

  @Test("planner lowAuto strips all vocab from system prompt")
  func plannerLowAutoSystemPromptHasNoVocab() {
    let words = [CustomWord(canonical: "EnviousWispr")]
    let built = input(
      customWords: words,
      customVocabulary: PromptVocabulary(global: ["EnviousWispr"]),
      detection: detection(lang: "en", tier: .lowAuto)
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(!system.contains("EnviousWispr"))
    #expect(!system.contains("CUSTOM VOCABULARY"))
  }

  @Test("planner highAuto keeps vocab in system prompt")
  func plannerHighAutoSystemPromptKeepsVocab() {
    let words = [CustomWord(canonical: "EnviousWispr")]
    let built = input(
      customWords: words,
      customVocabulary: PromptVocabulary(global: ["EnviousWispr"]),
      detection: detection(lang: "en", tier: .highAuto)
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("CUSTOM VOCABULARY"))
  }

  @Test("planner mediumAuto keeps global but not perLanguage in system prompt")
  func plannerMediumAutoKeepsGlobalOnly() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["de": ["Überlegung"]]
    )
    let built = input(
      customWords: [],
      customVocabulary: vocab,
      detection: detection(lang: "de", tier: .mediumAuto)
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(!system.contains("Überlegung"))
  }

  @Test("planner locked + non-Latin detected lang strips Latin perLanguage terms")
  func plannerScriptGuardrailIntegrates() {
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["ja": ["ビデオ", "stray"]]
    )
    let built = input(
      customWords: [],
      customVocabulary: vocab,
      detection: detection(lang: "ja", tier: .locked)
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("ビデオ"))
    #expect(!system.contains("stray"), "Latin-only ja term should be stripped by script guardrail")
  }

  // MARK: - Explicit ASR backend dispatch (W3 follow-up)

  @Test("backend .parakeet forces legacy path even when detection is populated")
  func parakeetForcesLegacyDespiteDetection() {
    // Populating languageDetection with a non-English high-confidence
    // result should be IGNORED when backend is explicitly Parakeet.
    // Parakeet is English-only and any detection on that path is bogus.
    let words = [CustomWord(canonical: "EnviousWispr", aliases: ["Envious Whisper"])]
    let built = input(
      customWords: words,
      customVocabulary: PromptVocabulary(
        global: ["EnviousWispr"],
        perLanguage: ["ja": ["日本語"]]
      ),
      detection: detection(lang: "ja", tier: .highAuto),
      backend: .parakeet
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    // Legacy path preserves the full CustomWord list verbatim — aliases
    // survive, and perLanguage terms that would leak via the W3 tier
    // policy never enter the prompt.
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("Envious Whisper"), "aliases preserved on Parakeet legacy path")
    #expect(!system.contains("日本語"), "perLanguage terms must not leak on Parakeet path")
  }

  @Test("backend .whisperKit with nil detection uses formatting-only path")
  func whisperKitNilDetectionIsFormattingOnly() {
    // Defensive: a future WhisperKit codepath that bypasses the detector
    // must NOT fall through to the English-centric legacy prompt. The
    // planner treats this as low-confidence and strips all lexical
    // injection.
    let words = [CustomWord(canonical: "EnviousWispr")]
    let built = input(
      customWords: words,
      customVocabulary: PromptVocabulary(global: ["EnviousWispr"]),
      detection: nil,
      backend: .whisperKit
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(
      !system.contains("EnviousWispr"),
      "no lexical injection when detection is absent on WhisperKit")
    #expect(!system.contains("CUSTOM VOCABULARY"))
  }

  @Test("backend .whisperKit with populated detection uses tier-gated W3 path")
  func whisperKitWithDetectionUsesTierPolicy() {
    // Explicit WhisperKit + populated high-confidence detection should
    // behave identically to the W3 tier-gated path: global + perLanguage
    // for the detected language are injected.
    let vocab = PromptVocabulary(
      global: ["EnviousWispr"],
      perLanguage: ["de": ["Überlegung"]]
    )
    let built = input(
      customWords: [CustomWord(canonical: "EnviousWispr")],
      customVocabulary: vocab,
      detection: detection(lang: "de", tier: .highAuto),
      backend: .whisperKit
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("Überlegung"))
    #expect(system.contains("CUSTOM VOCABULARY"))
  }

  @Test("backend nil falls through to legacy passthrough (safety net)")
  func nilBackendFallsThroughToLegacy() {
    // Untouched callsites (no explicit backend, no detection wired) must
    // preserve the legacy verbatim customWords behavior.
    let words = [CustomWord(canonical: "EnviousWispr", aliases: ["Envious Whisper"])]
    let built = input(
      customWords: words,
      detection: nil,
      backend: nil
    )
    let plan = DefaultPromptPlanner().plan(input: built)
    let system = plan.envelope.messages.first(where: { $0.role == .system })?.content ?? ""
    #expect(system.contains("EnviousWispr"))
    #expect(system.contains("Envious Whisper"), "aliases preserved on nil-backend legacy path")
  }

  // MARK: - Parakeet byte-identical characterization

  @Test("Parakeet prompt output is byte-identical to legacy nil-backend output")
  func parakeetByteIdenticalToLegacy() {
    let words = [CustomWord(canonical: "EnviousWispr", aliases: ["Envious Whisper"])]
    let legacyInput = input(
      customWords: words,
      detection: nil,
      backend: nil
    )
    let parakeetInput = input(
      customWords: words,
      detection: nil,
      backend: .parakeet
    )

    let legacyPlan = DefaultPromptPlanner().plan(input: legacyInput)
    let parakeetPlan = DefaultPromptPlanner().plan(input: parakeetInput)

    #expect(
      legacyPlan.envelope.messages.map(\.role.rawValue)
        == parakeetPlan.envelope.messages.map(\.role.rawValue),
      "Explicit Parakeet must match legacy nil-backend prompt roles exactly")
    #expect(
      legacyPlan.envelope.messages.map(\.content) == parakeetPlan.envelope.messages.map(\.content),
      "Explicit Parakeet must match legacy nil-backend prompt text byte-for-byte")
  }
}
