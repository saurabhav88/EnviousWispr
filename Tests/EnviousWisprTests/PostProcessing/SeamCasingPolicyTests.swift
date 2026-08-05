import Testing

@testable import EnviousWisprPostProcessing

// #1922: the eleven-language policy table, the German noun veto, the polite-form
// guards, and locale-aware lowering.
//
// Everything here is a pure function of an injected oracle, so no case touches a
// system dictionary or a part-of-speech tagger. What macOS can actually SERVE is
// a separate question owned by `SeamCasingOracleTests` and the runtime's
// capability profiles; conflating the two is how #1803's rejected design got its
// availability answer from a language code.
@Suite("Seam casing policy (#1922)")
struct SeamCasingPolicyTests {

  // MARK: - Fixtures

  /// Permits lowering anything, so a kept capital is always attributable to a
  /// policy rule rather than to the oracle declining.
  static func permissive(isNoun: Bool = false) -> SeamCasingOracle {
    SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in .ordinary },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in isNoun })
  }

  static func caret(_ left: String) -> CursorInsertionRepair.CaretText {
    CursorInsertionRepair.CaretText(
      left: left, right: "", leftReachesDocumentStart: true, isScreenDerived: false)
  }

  static func repaired(
    _ text: String,
    language: String?,
    left: String = "I was saying that ",
    protectedWords: Set<String> = [],
    oracle: SeamCasingOracle? = nil
  ) -> CursorInsertionRepair.PreparedPayloads {
    CursorInsertionRepair.repair(
      text: text,
      context: caret(left),
      protectedWords: protectedWords,
      language: language,
      oracle: oracle ?? permissive())
  }

  static func reasons(_ payloads: CursorInsertionRepair.PreparedPayloads) -> [String] {
    payloads.candidateRules.map(\.telemetryName)
  }

  // MARK: - The policy table

  @Test(
    "#1922 Every shipped policy resolves, and only the shipped ones do",
    arguments: [
      // The twelve that act. English was already here; the other eleven are the
      // change. Each row states the SHAPE it must resolve to, so a copy-paste
      // slip that gave, say, Turkish the German policy fails here rather than in
      // a Live UAT case nobody ran.
      ("en", true, false, 0),
      ("fr", true, false, 0),
      ("it", true, false, 0),
      ("ru", true, false, 0),
      ("nl", true, false, 0),
      ("es", true, false, 0),
      ("pt", true, false, 0),
      ("da", true, false, 0),
      ("fi", true, false, 0),
      ("tr", true, false, 0),
      ("de", true, true, 8),
      ("sv", true, false, 4),
      // The controls. Polish is the thirteenth European language by usage and is
      // deliberately absent; the rest stand for the 23 that must keep abstaining.
      ("pl", false, false, 0),
      ("cs", false, false, 0),
      ("hu", false, false, 0),
      ("el", false, false, 0),
      ("uk", false, false, 0),
    ])
  func policyTableResolves(
    _ code: String, _ hasPolicy: Bool, _ nounVeto: Bool, _ politeCount: Int
  ) {
    let rules = CursorInsertionRepair.LanguageRules.forLanguage(code)
    #expect(
      (rules.casingPolicy != nil) == hasPolicy,
      "\(code): policy presence")
    #expect(rules.casingPolicy?.nounVeto == (hasPolicy ? nounVeto : nil), "\(code): noun veto")
    #expect(
      (rules.casingPolicy?.politeForms.count ?? 0) == politeCount,
      "\(code): polite form count")
    #expect(rules.baseCode == code, "\(code): base code must be carried for locale lowering")
  }

  @Test(
    "#1922 A tag that normalises still reaches the right policy, and carries the NORMALISED base",
    arguments: [
      // `de_AT` and `de-DE` are the same grammar. Without normalisation each
      // spelling would be its own miss, and the language would silently abstain
      // on exactly the machines that set a region.
      ("de", "de", true),
      ("de-DE", "de", true),
      ("de_AT", "de", true),
      ("de-CH", "de", true),
      ("nl_BE", "nl", true),
      ("pt-BR", "pt", true),
      // `nb` is the case that makes the SECOND assertion worth having: Norwegian
      // Bokmål normalises to `no`, so `baseCode` is not simply the code passed
      // in. It still has no policy, which is the answer either way — but the
      // locale used for lowering is `no`, and a reader who assumed otherwise
      // would be wrong about which locale a future Norwegian entry would get.
      ("nb", "no", false),
    ])
  func normalisedTagsResolveToBasePolicy(
    _ raw: String, _ expectedBase: String, _ hasPolicy: Bool
  ) {
    let rules = CursorInsertionRepair.LanguageRules.forLanguage(raw)
    #expect(rules.baseCode == expectedBase, "\(raw) must normalise to \(expectedBase)")
    #expect((rules.casingPolicy != nil) == hasPolicy, "\(raw): policy presence after normalising")
  }

  @Test("#1922 An unknown or absent language abstains rather than guessing")
  func unknownLanguageAbstains() {
    #expect(CursorInsertionRepair.LanguageRules.forLanguage(nil).casingPolicy == nil)
    #expect(CursorInsertionRepair.LanguageRules.forLanguage(nil).baseCode == nil)
    #expect(CursorInsertionRepair.LanguageRules.forLanguage("zz").casingPolicy == nil)
  }

  // MARK: - English is frozen

  @Test(
    "#1922 English output is byte-identical to the shipped behaviour",
    arguments: [
      // The cross-persona guarantee. English shipped this rule in #1803 and
      // 100k users depend on it; the eleven new languages are worth nothing if
      // they cost a regression here.
      //
      // Each row is payload / expected repaired text / expected reason, taken
      // from the rules English already had, not from a run of the new code.
      ("The museum tonight.", "the museum tonight. ", "lowercased_first"),
      ("And then we left.", "and then we left. ", "lowercased_first"),
      // English-only guards must still be English-only AND still fire here.
      ("I went home.", "I went home. ", "case_skipped:pronoun_i"),
      ("Monday works for me.", "Monday works for me. ", "case_skipped:always_capitalized"),
      ("USA is far.", "USA is far. ", "case_skipped:mixed_case_or_acronym"),
      ("X5 arrives today.", "X5 arrives today. ", "case_skipped:contains_digit"),
    ])
  func englishIsFrozen(_ payload: String, _ expected: String, _ reason: String) {
    let out = Self.repaired(payload, language: "en")
    #expect(out.repairedText == expected, "English output must not move")
    #expect(Self.reasons(out).contains(reason), "and for the same stated reason")
  }

  @Test("#1922 The English-only guards do NOT leak into another language")
  func englishGuardsDoNotLeak() {
    // `isFirstPersonPronoun` is `["I", "I'm", …]` and `alwaysCapitalized` is the
    // English weekday and month set. Both were language-blind before this change,
    // which was harmless only while English was the only casing language.
    //
    // Dutch `Ik` is the first-person pronoun and is ordinarily LOWERCASE
    // mid-sentence, so leaking the English rule would keep a capital Dutch never
    // wanted. German `Mai` is a month and IS capitalised — but by the noun rule,
    // which is German's own, not by an English table.
    let dutch = Self.repaired("Ik ga naar huis.", language: "nl", left: "Ik zei dat ")
    #expect(dutch.repairedText == "ik ga naar huis. ", "Dutch `Ik` is not the English `I`")
    #expect(Self.reasons(dutch).contains("case_skipped:pronoun_i") == false)

    let german = Self.repaired(
      "Monday ist ein Tag.", language: "de", left: "Ich sagte dass ",
      oracle: Self.permissive(isNoun: false))
    #expect(
      Self.reasons(german).contains("case_skipped:always_capitalized") == false,
      "the English weekday table must not decide anything in German")
  }

  // MARK: - The German noun veto

  @Test("#1922 A German noun keeps its capital by veto")
  func germanNounIsVetoed() {
    let out = Self.repaired(
      "Brot ist teuer.", language: "de", left: "Ich sagte dass das ",
      oracle: Self.permissive(isNoun: true))

    #expect(out.repairedText == "Brot ist teuer. ")
    #expect(Self.reasons(out).contains("case_skipped:noun_in_noun_capitalising_language"))
  }

  @Test("#1922 A German non-noun lowers — the veto is not a blanket refusal")
  func germanNonNounLowers() {
    // The two-way control. A veto answering "noun" to everything would satisfy
    // every keep-the-capital assertion in this file while disabling German
    // entirely, and no test above would notice.
    let out = Self.repaired(
      "Gestern war es besser.", language: "de", left: "Ich sagte dass ",
      oracle: Self.permissive(isNoun: false))

    #expect(out.repairedText == "gestern war es besser. ")
    #expect(Self.reasons(out).contains("lowercased_first"))
  }

  @Test("#1922 The veto is absent in French and Italian even when the tagger says noun")
  func vetoDoesNotLeakToRomanceLanguages() {
    // Measured on held-out text: applying the veto to French and Italian costs a
    // third of the recall for one point of precision, because those languages
    // lowercase their common nouns. The tagger is deliberately not consulted, so
    // an oracle screaming "noun" must change nothing.
    for language in ["fr", "it", "es", "pt", "sv", "nl", "da", "fi", "tr", "ru", "en"] {
      let out = Self.repaired(
        "Merci beaucoup vraiment.", language: language, left: "Je voulais dire que ",
        oracle: Self.permissive(isNoun: true))
      #expect(
        out.repairedText == "merci beaucoup vraiment. ",
        "\(language) must lower regardless of the tagger")
      #expect(
        Self.reasons(out).contains("case_skipped:noun_in_noun_capitalising_language") == false,
        "\(language) must never reach the veto at all")
    }
  }

  // MARK: - Polite forms

  @Test(
    "#1922 A polite form keeps its capital, because the capital IS the meaning",
    arguments: [
      // German `Sie` is the polite you; `sie` is "she". No dictionary can see the
      // difference, because both spellings are ordinary words — which is exactly
      // why this guard runs before the oracle.
      ("Sie haben recht.", "de", "Sie haben recht. "),
      ("Ihnen gehört das.", "de", "Ihnen gehört das. "),
      ("Ihre Nachricht kam an.", "de", "Ihre Nachricht kam an. "),
      // Swedish `Ni`, the same shape without a noun rule.
      ("Ni har rätt.", "sv", "Ni har rätt. "),
      ("Er bok ligger där.", "sv", "Er bok ligger där. "),
    ])
  func politeFormsKeepTheirCapital(_ payload: String, _ language: String, _ expected: String) {
    let out = Self.repaired(payload, language: language, left: "Ich sagte dass ")
    #expect(out.repairedText == expected)
    #expect(Self.reasons(out).contains("case_skipped:polite_form"))
  }

  @Test("#1922 A polite set belongs to ONE language and does not travel")
  func politeSetsAreLanguageScoped() {
    // Swedish `Er` is a polite possessive; German `er` is "he" and is ordinary.
    // If the sets were merged, or if a lookup fell back to another language's,
    // German would keep a capital on an everyday pronoun.
    let german = Self.repaired(
      "Er kommt später.", language: "de", left: "Ich sagte dass ",
      oracle: Self.permissive(isNoun: false))
    #expect(german.repairedText == "er kommt später. ", "German `er` is not Swedish `Er`")
    #expect(Self.reasons(german).contains("case_skipped:polite_form") == false)

    // And a language with no polite set at all must not acquire one.
    let french = Self.repaired("Sie est un mot.", language: "fr", left: "Je disais que ")
    #expect(Self.reasons(french).contains("case_skipped:polite_form") == false)
  }

  @Test("#1922 Italian and Russian have NO polite set, and that was measured")
  func italianAndRussianHaveNoPoliteSet() {
    // Both were tried and reverted: the candidate lists contained ordinary
    // articles and possessives (`la`, `le`, `suo`, `sua`, `вы`), and each made
    // its language measurably WORSE. Frozen so the idea is not re-added on the
    // reasoning that "German and Swedish have one, so these should too".
    #expect(CursorInsertionRepair.LanguageRules.forLanguage("it").casingPolicy?.politeForms == [])
    #expect(CursorInsertionRepair.LanguageRules.forLanguage("ru").casingPolicy?.politeForms == [])
  }

  // MARK: - Locale-aware lowering

  @Test(
    "#1922 The leading unit lowers in the language's own locale",
    arguments: [
      // Turkish is the case that makes a locale mandatory rather than tidy:
      // dotted and dotless `I` are DIFFERENT LETTERS, and an invariant lowercase
      // maps both to `i`, silently misspelling one of them.
      ("Istanbul dır.", "tr", "ıstanbul dır. "),
      ("İyi günler.", "tr", "iyi günler. "),
      // German `ß` has no uppercase form in the leading position we touch; the
      // point is that lowering the first character must not disturb the rest.
      ("Straße ist voll.", "de", "straße ist voll. "),
      // And an ordinary Latin language must be unaffected by the locale work.
      ("Merci beaucoup.", "fr", "merci beaucoup. "),
    ])
  func loweringUsesTheLanguageLocale(_ payload: String, _ language: String, _ expected: String) {
    let out = Self.repaired(
      payload, language: language, left: "Ben dedim ki ",
      oracle: Self.permissive(isNoun: false))
    #expect(out.repairedText == expected)
  }

  @Test("#1922 Turkish lowering is NOT the invariant lowering")
  func turkishDiffersFromInvariant() {
    // The control that makes the row above mean something: if the locale were
    // ignored, `Istanbul` would come out `istanbul` and the assertion would still
    // look plausible to a reader who does not speak Turkish.
    #expect(
      CursorInsertionRepair.loweringLeadingUnit(of: "Istanbul", languageCode: "tr") == "ıstanbul")
    #expect(
      CursorInsertionRepair.loweringLeadingUnit(of: "Istanbul", languageCode: "en") == "istanbul")
    #expect(
      CursorInsertionRepair.loweringLeadingUnit(of: "İyi", languageCode: "tr") == "iyi")
  }

  // MARK: - Dutch IJ: both halves, because either alone is inert

  @Test("#1922 Dutch `IJ` is one casing unit and both characters lower together")
  func dutchDigraphLowersBothCharacters() {
    // TWO changes are required and each is inert without the other: the acronym
    // guard refused every `IJ`-initial word four checks before the lowering code
    // could run, so rev 2's "add a locale" fix would have done nothing at all.
    // Verified against the shipped guard, not reasoned about
    // (`2026-08-05-dutch-guard-probe.swift`).
    let out = Self.repaired("IJs is lekker.", language: "nl", left: "Ik zei dat ")
    #expect(out.repairedText == "ijs is lekker. ", "both characters, or the word is misspelled")
    #expect(Self.reasons(out).contains("lowercased_first"))
  }

  @Test("#1922 An ordinary Dutch word is unaffected by the digraph exemption")
  func dutchOrdinaryWordUnaffected() {
    let out = Self.repaired("Ik ga nu weg.", language: "nl", left: "Ik zei dat ")
    #expect(out.repairedText == "ik ga nu weg. ")
  }

  @Test("#1922 A Dutch acronym still refuses, and so does one that opens with IJ")
  func dutchAcronymsStillRefuse() {
    // `USA` proves ordinary acronym protection survives the exemption. It does
    // NOT prove the exemption is narrow, because its second character is not the
    // exempted position — so `IJUSA` is the case that carries that claim, and
    // grounded review r2 was right that its absence left a hole.
    let usa = Self.repaired("USA is ver weg.", language: "nl", left: "Ik zei dat ")
    #expect(usa.repairedText == "USA is ver weg. ")
    #expect(Self.reasons(usa).contains("case_skipped:mixed_case_or_acronym"))

    let ijusa = Self.repaired("IJUSA is iets.", language: "nl", left: "Ik zei dat ")
    #expect(ijusa.repairedText == "IJUSA is iets. ", "only the second J is forgiven")
    #expect(Self.reasons(ijusa).contains("case_skipped:mixed_case_or_acronym"))
  }

  @Test("#1922 The digraph exemption is Dutch-only")
  func digraphExemptionIsDutchOnly() {
    // Widening it to every language would forgive English `IT`, `IP`, `ID`.
    for language in ["en", "de", "fr", "sv"] {
      let out = Self.repaired("IJssel is ver.", language: language, left: "I said that ")
      #expect(
        Self.reasons(out).contains("case_skipped:mixed_case_or_acronym"),
        "\(language) must still read `IJ` as an acronym")
    }
    #expect(CursorInsertionRepair.isDutchIJDigraph("IJs", "nl"))
    #expect(CursorInsertionRepair.isDutchIJDigraph("IJs", "en") == false)
    #expect(CursorInsertionRepair.isDutchIJDigraph("IJUSA", "nl") == false)
    #expect(CursorInsertionRepair.isDutchIJDigraph("Ik", "nl") == false)
  }

  // MARK: - Priority: the user's own signals outrank every new one

  @Test("#1922 A protected word beats the new policies in every language")
  func protectedWordOutranksPolicy() {
    // Custom Words is the user's explicit instruction and the strongest signal
    // there is. A new language must not quietly overrule it — and unlike the
    // rules above, this one is per-user, so a regression here is invisible to
    // every corpus measurement.
    for language in ["en", "de", "sv", "nl", "tr", "fr"] {
      let out = Self.repaired(
        "Olive stuurde het bestand.", language: language, left: "Ik hoorde dat ",
        protectedWords: ["Olive"])
      #expect(
        out.repairedText == "Olive stuurde het bestand. ",
        "\(language): a protected spelling must survive")
      #expect(
        Self.reasons(out).contains("case_skipped:protected_word"),
        "\(language): and for the protected-word reason specifically")
    }
  }

  @Test("#1922 A learned word beats the new policies in every language")
  func learnedWordOutranksPolicy() {
    let learned = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { _ in .ordinary },
      isLearnedWord: { _ in true },
      isRecognizedName: { _, _ in false },
      isNoun: { _ in false })

    for language in ["en", "de", "sv", "nl", "tr", "fr"] {
      let out = Self.repaired(
        "Vercel deployt nu.", language: language, left: "Ik zei dat ", oracle: learned)
      #expect(
        Self.reasons(out).contains("case_skipped:learned_word"),
        "\(language): what the user taught macOS must outrank a language rule")
    }
  }

  @Test("#1922 An unavailable oracle keeps the capital in every policy language")
  func unavailableOracleKeepsCapitalEverywhere() {
    // The safety floor for the whole change: if word knowledge is missing for a
    // language, that language must behave exactly as the app did before this
    // feature existed. A policy entry alone must never be able to lower anything.
    for language in ["en", "de", "sv", "nl", "tr", "fr", "ru", "fi", "da", "es", "pt", "it"] {
      let out = Self.repaired(
        "Store is closed.", language: language, left: "I went past and the ",
        oracle: .unavailable(.dictionaryUnavailable))
      #expect(
        out.repairedText == "Store is closed. ",
        "\(language): no dictionary means no lowering")
      #expect(Self.reasons(out).contains("case_skipped:dictionary_unavailable"))
    }
  }

  // MARK: - The new reasons reach telemetry

  @Test("#1922 Both new skip reasons carry a stable telemetry name")
  func newReasonsHaveTelemetryNames() {
    // These two VALUES are the whole of the change's telemetry: they ride the
    // existing `paste.completed.repair_rules`, so no field or plumbing changes.
    // A renamed value would silently break the version floor recorded at ship.
    #expect(
      CursorInsertionRepair.CaseSkipReason.nounInNounCapitalisingLanguage.rawValue
        == "noun_in_noun_capitalising_language")
    #expect(CursorInsertionRepair.CaseSkipReason.politeForm.rawValue == "polite_form")
    #expect(
      CursorInsertionRepair.AppliedRule
        .caseSkipped(.nounInNounCapitalisingLanguage).telemetryName
        == "case_skipped:noun_in_noun_capitalising_language")
    #expect(
      CursorInsertionRepair.AppliedRule.caseSkipped(.politeForm).telemetryName
        == "case_skipped:polite_form")
  }
}
