import Testing

@testable import EnviousWisprPostProcessing

// #1921 obligation 8: the paired replay.
//
// Every other measurement for #1921 stops at the resolver — it asks whether a
// usable language came back, never what the repair then DID with it. A defect
// created after the language reaches the consumer is invisible to all of them.
//
// #1921 changes the resolver so it answers where it used to abstain. The safety
// argument for that is a closed-set claim about `LanguageRules`, executed here
// against the real `CursorInsertionRepair.repair` rather than asserted in a
// document.
//
// #1922 MOVED that claim, and this suite moved with it. `knowsCasing: Bool`
// became `casingPolicy: CasingPolicy?`, and eleven more languages now have one,
// so "every non-English language is byte-identical to nil" — what this suite
// used to freeze — is no longer the contract and asserting it would freeze the
// bug. The contract now has two halves and both are below: a language WITHOUT a
// policy is still byte-identical to nil, and a language WITH one differs on the
// casing axis and on nothing else.
//
// The oracle is injected and fixed, so these cases never touch the system
// dictionary and stay deterministic on every machine and CI image — the same
// discipline `CursorInsertionRepairTests` uses.
@Suite("CursorInsertionRepair language pairing")
struct CursorInsertionRepairLanguagePairingTests {

  /// Permits lowering any word it knows, so the casing rule is free to fire.
  /// A refusing oracle would make every case identical and the suite vacuous.
  ///
  /// `isNoun` mirrors what `NLTagger`'s `.lexicalClass` actually answers for the
  /// German words this suite dictates, rather than a constant. A double thinner
  /// than the guard it stands in for cannot demonstrate the guard: `false`
  /// everywhere would make the German case fail for the right reason by the
  /// wrong route, and `true` everywhere would make it pass without the veto
  /// being what passed it.
  static let oracle = SeamCasingOracle(
    unavailableReason: nil,
    dictionaryVerdict: { _ in .ordinary },
    isLearnedWord: { _ in false },
    isRecognizedName: { _, _ in false },
    isNoun: { payload in
      let first = payload.split(separator: " ").first.map(String.init) ?? payload
      return ["Gift", "Brot", "Haus"].contains(first)
    })

  static let protectedWords: Set<String> = []

  static func caret(left: String, right: String) -> CursorInsertionRepair.CaretText {
    CursorInsertionRepair.CaretText(
      left: left, right: right, leftReachesDocumentStart: true, isScreenDerived: false)
  }

  static func repaired(_ text: String, _ language: String?, left: String, right: String)
    -> CursorInsertionRepair.PreparedPayloads
  {
    CursorInsertionRepair.repair(
      text: text,
      context: caret(left: left, right: right),
      protectedWords: protectedWords,
      language: language,
      oracle: oracle)
  }

  // MARK: - A language WITHOUT a policy: resolving must still change NOTHING

  @Test(
    "A segmented language with no casing policy is byte-identical to no language at all",
    arguments: [
      ("Dziekuje bardzo za to.", "pl", "Chcialem powiedziec ze "),
      ("Dekuji moc za to.", "cs", "Chtel jsem rici ze "),
      ("Nagyon szepen koszonom.", "hu", "Azt akartam mondani hogy "),
      ("Multumesc mult pentru asta.", "ro", "Voiam sa spun ca "),
      ("Efcharisto poly gia afto.", "el", "Ithela na po oti "),
      ("Duzhe dyakuyu za tse.", "uk", "Ya khotiv skazaty shcho "),
    ])
  func unsupportedSegmentedLanguageIsIdenticalToNil(
    _ payload: String, _ language: String, _ left: String
  ) {
    // The abstain half of the contract, and the control that makes the other
    // half meaningful. #1922 gave eleven languages a policy; these six deliberately
    // have none, so a confident resolution must still be a complete no-op for
    // them. If any field moves here, the policy table is reaching languages it
    // was never measured on.
    //
    // Six rather than one because "the table is keyed correctly" is a claim about
    // absence, and one row cannot carry it — a prefix or fallback bug that
    // admitted, say, every Slavic code would pass on Polish alone.
    let withNil = Self.repaired(payload, nil, left: left, right: "")
    let withLanguage = Self.repaired(payload, language, left: left, right: "")

    #expect(withNil.legacyText == withLanguage.legacyText, "\(language): legacy payload")
    #expect(withNil.repairedText == withLanguage.repairedText, "\(language): candidate")
    #expect(
      withNil.candidateRules.map(\.telemetryName)
        == withLanguage.candidateRules.map(\.telemetryName),
      "\(language): applied rules")
    #expect(
      withLanguage.candidateRules.map(\.telemetryName)
        .contains("case_skipped:language_not_supported"),
      "\(language): and it must say WHY it abstained, not merely produce the same bytes")
  }

  // MARK: - A language WITH a policy: exactly one axis may change

  @Test(
    "A supported non-English language differs from nil ONLY by the casing rule",
    arguments: [
      ("Merci beaucoup vraiment.", "fr", "Je voulais dire que ", "merci beaucoup vraiment. "),
      ("Muchas gracias de verdad.", "es", "Queria decir que ", "muchas gracias de verdad. "),
      ("Tot straks dan maar.", "nl", "Ik wilde zeggen dat ", "tot straks dan maar. "),
      ("Grazie mille davvero.", "it", "Volevo dire che ", "grazie mille davvero. "),
      ("Tack sa mycket verkligen.", "sv", "Jag ville saga att ", "tack sa mycket verkligen. "),
      ("Tusind tak for det.", "da", "Jeg ville sige at ", "tusind tak for det. "),
      ("Kiitos oikein paljon.", "fi", "Halusin sanoa etta ", "kiitos oikein paljon. "),
      ("Cok tesekkur ederim.", "tr", "Sunu soylemek istedim ", "cok tesekkur ederim. "),
      ("Obrigado mesmo por isso.", "pt", "Eu queria dizer que ", "obrigado mesmo por isso. "),
      ("Spasibo bolshoe za eto.", "ru", "Ya khotel skazat chto ", "spasibo bolshoe za eto. "),
    ])
  func supportedLanguageDiffersOnlyByCasing(
    _ payload: String, _ language: String, _ left: String, _ expected: String
  ) {
    // The half #1922 adds. Before it, every one of these was byte-identical to
    // nil and the seam kept a capital the user never asked for — wrong 92.9% of
    // the time on held-out published text.
    //
    // EXACT bytes, never `!=` plus a `contains`. The loose form passes alongside
    // unrelated text damage, which is precisely what "only one axis moved" is
    // supposed to rule out.
    let withNil = Self.repaired(payload, nil, left: left, right: "")
    let withLanguage = Self.repaired(payload, language, left: left, right: "")

    #expect(withNil.legacyText == withLanguage.legacyText, "\(language): legacy must not move")
    #expect(
      withLanguage.repairedText == expected,
      "\(language): must produce exactly the lowered payload plus today's trailing space")
    #expect(
      withNil.repairedText == payload + " ",
      "\(language): and the nil arm must produce exactly the payload unchanged")

    // Every rule other than the casing decision must be identical. This is what
    // would catch a spacing or duplicate-word change riding along.
    let casingRules: Set<String> = ["lowercased_first", "case_skipped:language_not_supported"]
    let nilOther = withNil.candidateRules.map(\.telemetryName).filter { !casingRules.contains($0) }
    let langOther = withLanguage.candidateRules.map(\.telemetryName).filter {
      !casingRules.contains($0)
    }
    #expect(
      nilOther == langOther,
      "\(language): only the casing rule may differ, got \(nilOther) vs \(langOther)")
  }

  // MARK: - English: exactly one axis may change

  @Test(
    "English differs from nil ONLY by the casing rule",
    arguments: [
      ("Warmer and summer starts.", "I can't wait till the weather is "),
      ("Store is closed today.", "I went past and the "),
      ("Coming back tomorrow.", "He said he was "),
    ])
  func englishDiffersOnlyByCasing(_ payload: String, _ left: String) {
    let withNil = Self.repaired(payload, nil, left: left, right: "")
    let withEnglish = Self.repaired(payload, "en", left: left, right: "")

    // The legacy payload is what ships when no candidate is offered, and this
    // change must never touch it.
    #expect(withNil.legacyText == withEnglish.legacyText, "legacy payload must not move")

    // EXACT payloads, not "different" plus a `contains`. Integration review was
    // right that the loose form passes alongside unrelated text damage: any
    // change anywhere in the string satisfies `!=`, and `contains` of a single
    // lowercase letter is satisfied by most of the sentence.
    //
    // Derived from the rules rather than copied from a run: `left` already ends
    // in a space so rule 1 adds none, rule 2 lowercases the first character, and
    // rule 3 appends the trailing space.
    let expectedLowered = payload.prefix(1).lowercased() + payload.dropFirst() + " "
    #expect(
      withEnglish.repairedText == expectedLowered,
      "English must produce exactly the lowercased payload plus today's trailing space")
    #expect(
      withNil.repairedText == payload + " ",
      "and the nil arm must produce exactly the payload unchanged plus that space")

    // Every rule other than the casing decision must be identical. This is the
    // assertion that would catch a spacing or duplicate-word change sneaking in
    // alongside the intended one.
    let casingRules: Set<String> = ["lowercased_first", "case_skipped:language_not_supported"]
    let nilOther = withNil.candidateRules.map(\.telemetryName).filter { !casingRules.contains($0) }
    let enOther = withEnglish.candidateRules.map(\.telemetryName).filter {
      !casingRules.contains($0)
    }
    #expect(nilOther == enOther, "only the casing rule may differ, got \(nilOther) vs \(enOther)")
  }

  // MARK: - Unsegmented: the one intended non-casing change, frozen

  @Test(
    "Every effective unsegmented language suppresses spacing where nil would add it",
    arguments: [
      ("これは日本語のテストです。", "ja", "昨日の会議について"),
      ("这是一个中文测试。", "zh", "关于昨天的会议"),
      ("นี่คือการทดสอบภาษาไทย", "th", "เกี่ยวกับการประชุมเมื่อวาน"),
      ("ນີ້ແມ່ນການທົດສອບພາສາລາວ", "lo", "ກ່ຽວກັບກອງປະຊຸມມື້ວານນີ້"),
      ("ဤသည်မြန်မာဘာသာစကားစမ်းသပ်မှုဖြစ်သည်", "my", "မနေ့ကအစည်းအဝေးအကြောင်း"),
      ("នេះជាការសាកល្បងភាសាខ្មែរ", "km", "អំពីកិច្ចប្រជុំកាលពីម្សិលមិញ"),
    ])
  func unsegmentedSuppressesSpacing(_ payload: String, _ language: String, _ left: String) {
    // All SIX effective unsegmented values, not a sample of three. `yue` is
    // absent deliberately: `LanguageNormalizer.baseCode` maps it to `zh` before
    // policy is evaluated, so it can never reach `LanguageRules` as itself.
    //
    // This is the reason the recogniser is NOT constrained to the default
    // engine's language list. Constrained, these all came back nil, which is
    // `LanguageRules.unknown`, whose `usesWordSpacing` is true — so the repair
    // would have ADDED spaces they must not have, on BOTH sides, as the byte
    // assertions below show. Frozen here so a future constraint cannot
    // reintroduce that silently.
    let withNil = Self.repaired(payload, nil, left: left, right: "")
    let withLanguage = Self.repaired(payload, language, left: left, right: "")

    let nilRules = withNil.candidateRules.map(\.telemetryName)
    let languageRules = withLanguage.candidateRules.map(\.telemetryName)

    #expect(
      languageRules.contains("trailing_space_skipped:unsegmented_script"),
      "\(language) must suppress the trailing space, got \(languageRules)")
    #expect(
      nilRules.contains("trailing_space_skipped:unsegmented_script") == false,
      "and nil must NOT, or this case proves nothing (\(language))")

    // Rule names alone would pass alongside unrelated damage to the text, so
    // assert the BYTES.
    //
    // The delta is TWO spaces, not one, and I had this wrong until the assertion
    // failed. Without a resolved language, `usesWordSpacing` is true, so rule 1
    // adds a LEADING space at `:392` as well as rule 3 adding the trailing one.
    // Unsegmented text therefore arrives wrapped in spaces on both sides. The
    // plan's prose described only the trailing space; the five-site table was
    // right and the sentence under it was not.
    //
    // This is why the expectation is derived from the rules rather than copied
    // from a run: a copied value would have frozen the wrong description as if
    // it were intended.
    #expect(
      withLanguage.repairedText == payload,
      "\(language) must deliver the payload byte-identical, with no added spacing")
    #expect(
      withNil.repairedText == " " + payload + " ",
      "and the nil arm wraps it in spaces on BOTH sides (\(language))")
  }

  // MARK: - Code-switching, which is the case the German set exists for

  @Test("A German insertion in an English document is untouched when resolved German")
  func germanInEnglishDocumentIsUntouched() {
    // The document is overwhelmingly English. If the resolver had let the
    // document authorise English — the design withdrawn in rev 2 after measuring
    // 17 wrong lowerings of 24 — this is the payload that would have been
    // damaged. Resolved German, the repair must leave the capital alone.
    let payload = "Gift ist gefährlich."
    let left = "I have been writing this email in English all morning and I wanted to add that the "

    let asGerman = Self.repaired(payload, "de", left: left, right: "")
    let asEnglish = Self.repaired(payload, "en", left: left, right: "")

    // EXACT bytes, not `contains`. Integration review made this point about the
    // English case and it applies identically here: `contains("Gift")` is
    // satisfied by a payload that kept its capital and was damaged elsewhere.
    //
    // Derived from the rules, and the derivation CHANGED with #1922. It used to
    // read "German `knowsCasing` is false so rule 2 cannot fire" — German now has
    // a policy and rule 2 fires, reaches the oracle, is authorised to lower, and
    // is then withdrawn by the noun veto. Same bytes out, entirely different
    // route through, which is why the reason is asserted below: without it this
    // case would keep passing if the veto were deleted and German were simply
    // dropped from the table again.
    #expect(
      asGerman.repairedText == "Gift ist gefährlich. ",
      "the German noun must keep its capital, and nothing else may move")
    #expect(
      asGerman.candidateRules.map(\.telemetryName)
        .contains("case_skipped:noun_in_noun_capitalising_language"),
      "and the VETO must be what kept it, not an abstention")
    #expect(
      asEnglish.repairedText == "gift ist gefährlich. ",
      "and English rules WOULD have lowered it, which is what makes this test meaningful")
  }

  @Test("German lowers an ordinary non-noun continuation — the veto is not a blanket refusal")
  func germanNonNounStillLowers() {
    // The two-way control the case above cannot supply. A veto that answered
    // "noun" to everything would satisfy every German assertion in this suite
    // while disabling the feature for the whole language, and nothing would show
    // it. Measured on held-out German: 22.0% correct before, 89.0% after — that
    // gain is entirely made of continuations like this one.
    let lowered = Self.repaired(
      "Und dann sagte er nichts.", "de",
      left: "Ich habe den ganzen Morgen an dieser Mail geschrieben ", right: "")

    #expect(
      lowered.repairedText == "und dann sagte er nichts. ",
      "an ordinary German continuation must still lower")
    #expect(
      lowered.candidateRules.map(\.telemetryName).contains("lowercased_first"),
      "and it must be the casing rule that did it")
  }
}
