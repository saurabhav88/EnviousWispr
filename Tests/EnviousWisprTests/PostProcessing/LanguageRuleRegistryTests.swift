import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Rule-set identity and registry construction (#1677, chunk 2)
//
// A drift guard on the one small immutable table the language route consults: keys are
// canonical through `LanguageNormalizer.baseCode`, English and rejected values are refused at
// construction, a conflicting alias pair is refused rather than silently resolved, and a missing
// entry is simply absent (the route then falls back to the neutral subset).

@Suite("LanguageRuleRegistry (#1677)", .tags(.driftGuard))
struct LanguageRuleRegistryTests {

  @Test("a rule set's key is the canonical base code, whatever spelling it was given")
  func canonicalKeys() {
    #expect(LanguageRuleSet(language: "de")?.baseCode == "de")
    #expect(LanguageRuleSet(language: "DE")?.baseCode == "de")
    #expect(LanguageRuleSet(language: "de-DE")?.baseCode == "de")
    #expect(LanguageRuleSet(language: "pt_BR")?.baseCode == "pt")
    #expect(LanguageRuleSet(language: "nb")?.baseCode == "no")
    #expect(LanguageRuleSet(language: "nn")?.baseCode == "no")
    #expect(LanguageRuleSet(language: "cmn")?.baseCode == "zh")
    #expect(LanguageRuleSet(language: "yue")?.baseCode == "zh")
    #expect(LanguageRuleSet(language: "zh-Hans")?.baseCode == "zh")
  }

  @Test("English and values baseCode rejects can never be a rule set")
  func refusedKeys() {
    for refused in ["en", "EN", "en-US", "en_GB", "und", "", " ", "e", "english", "toolongcode"] {
      #expect(LanguageRuleSet(language: refused) == nil, "\(refused.debugDescription)")
    }
  }

  @Test("two spellings of one language conflict instead of one silently winning")
  func conflictingAliasesAreRefused() throws {
    let nb = try #require(LanguageRuleSet(language: "nb"))
    let no = try #require(LanguageRuleSet(language: "no"))
    #expect(throws: LanguageRuleRegistry.RegistryError.duplicate(baseCode: "no")) {
      _ = try LanguageRuleRegistry([nb, no])
    }
    let de1 = try #require(LanguageRuleSet(language: "de"))
    let de2 = try #require(LanguageRuleSet(language: "de-AT"))
    #expect(throws: LanguageRuleRegistry.RegistryError.duplicate(baseCode: "de")) {
      _ = try LanguageRuleRegistry([de1, de2])
    }
  }

  @Test("lookup canonicalises, and a missing or English or rejected value is absent")
  func lookup() throws {
    let registry = try LanguageRuleRegistry(
      ["de", "nb", "cmn"].compactMap { LanguageRuleSet(language: $0) })
    #expect(registry.count == 3)
    #expect(registry.ruleSet(forLanguage: "de-CH")?.baseCode == "de")
    #expect(registry.ruleSet(forLanguage: "nn")?.baseCode == "no")
    #expect(registry.ruleSet(forLanguage: "zh-Hant")?.baseCode == "zh")
    for absent: String? in ["es", "en", "en-US", "und", "", " ", nil, "abcd"] {
      #expect(registry.ruleSet(forLanguage: absent) == nil, "\(String(describing: absent))")
    }
  }

  @Test("the production registry lists exactly de, fr, es, it, pt, nl, pl, sv and uk")
  func productionMembers() {
    #expect(LanguageRuleRegistry.production.count == 9)
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "de-DE")?.baseCode == "de")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "fr")?.baseCode == "fr")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "pt_BR")?.baseCode == "pt")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "nl-NL")?.baseCode == "nl")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "pl")?.baseCode == "pl")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "sv-SE")?.baseCode == "sv")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "uk")?.baseCode == "uk")
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "fi") == nil)
    #expect(LanguageRuleRegistry.production.ruleSet(forLanguage: "en") == nil)
  }
}
