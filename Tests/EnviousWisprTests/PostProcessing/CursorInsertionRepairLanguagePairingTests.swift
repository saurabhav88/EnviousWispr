import Testing

@testable import EnviousWisprPostProcessing

// #1921 obligation 8: the paired replay.
//
// Every other measurement for #1921 stops at the resolver — it asks whether a
// usable language came back, never what the repair then DID with it. A defect
// created after the language reaches the consumer is invisible to all of them.
//
// #1921 changes the resolver so it answers where it used to abstain. The safety
// argument for that is a closed-set claim about `LanguageRules`: it has exactly
// two policy fields; `knowsCasing` differs from `.unknown` only for English, and
// `usesWordSpacing` differs only for the six effective unsegmented values
// (`yue` normalises to `zh`). This suite is that claim executed against the real
// `CursorInsertionRepair.repair` rather than asserted in a document.
//
// The oracle is injected and fixed, so these cases never touch the system
// dictionary and stay deterministic on every machine and CI image — the same
// discipline `CursorInsertionRepairTests` uses.
@Suite("CursorInsertionRepair language pairing")
struct CursorInsertionRepairLanguagePairingTests {

  /// Permits lowering any word it knows, so the casing rule is free to fire.
  /// A refusing oracle would make every case identical and the suite vacuous.
  static let oracle = EnglishWordOracle(
    unavailableReason: nil,
    dictionaryVerdict: { _ in .ordinary },
    isLearnedWord: { _ in false },
    isRecognizedName: { _, _ in false })

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

  // MARK: - Segmented non-English: resolving must change NOTHING

  @Test(
    "A segmented non-English language is byte-identical to no language at all",
    arguments: [
      ("Gift ist gefährlich.", "de", "Ich sagte dass das "),
      ("Merci beaucoup vraiment.", "fr", "Je voulais dire que "),
      ("Muchas gracias de verdad.", "es", "Queria decir que "),
      ("Tot straks dan maar.", "nl", "Ik wilde zeggen dat "),
      ("Dziekuje bardzo za to.", "pl", "Chcialem powiedziec ze "),
      ("Grazie mille davvero.", "it", "Volevo dire che "),
    ])
  func segmentedNonEnglishIsIdenticalToNil(_ payload: String, _ language: String, _ left: String) {
    // This is the load-bearing half of the closed-set proof. Before #1921 these
    // insertions resolved to nil; after it they resolve to their own language.
    // If ANY field differs, returning a confident language is not the no-op the
    // plan claims and the change is unsafe.
    let withNil = Self.repaired(payload, nil, left: left, right: "")
    let withLanguage = Self.repaired(payload, language, left: left, right: "")

    #expect(withNil.legacyText == withLanguage.legacyText, "\(language): legacy payload")
    #expect(withNil.repairedText == withLanguage.repairedText, "\(language): candidate")
    #expect(
      withNil.candidateRules.map(\.telemetryName)
        == withLanguage.candidateRules.map(\.telemetryName),
      "\(language): applied rules")
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
    // Derived from the rules: `left` already ends in a space so rule 1 adds
    // none, German `knowsCasing` is false so rule 2 cannot fire, and rule 3
    // appends the trailing space because German IS word-spaced.
    #expect(
      asGerman.repairedText == "Gift ist gefährlich. ",
      "the German noun must keep its capital, and nothing else may move")
    #expect(
      asEnglish.repairedText == "gift ist gefährlich. ",
      "and English rules WOULD have lowered it, which is what makes this test meaningful")
  }
}
