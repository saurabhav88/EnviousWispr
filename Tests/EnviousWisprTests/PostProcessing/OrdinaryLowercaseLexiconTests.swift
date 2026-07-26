import Testing

@testable import EnviousWisprPostProcessing

// The shipped ordinary-lowercase lexicon and its failure modes (#1785 Chunk 2).
//
// Two properties matter more than coverage here:
//
// 1. Every word in the exclusion class is ABSENT. Each of those is an ordinary
//    English word that is also a name, brand, language, place, weekday, month,
//    or the first-person pronoun, so lowercasing a capitalised occurrence would
//    render somebody's name in lowercase. Checked one word at a time, not in
//    aggregate, so a failure names the offending word.
// 2. Bad resource data disables leading-case repair ONLY. Spacing and
//    terminal-period repair must survive, because those never depend on the
//    lexicon and silently losing them would be a regression nobody notices.
@Suite("OrdinaryLowercaseLexicon")
struct OrdinaryLowercaseLexiconTests {

  // MARK: - The real bundled resource

  @Test("The production resource resolves through Bundle.module and is available")
  func bundledResourceLoads() {
    #expect(OrdinaryLowercaseLexicon.bundled.isAvailable)
  }

  @Test("The production resource parses to exactly 800 unique entries")
  func bundledEntryCount() {
    #expect(
      OrdinaryLowercaseLexicon.bundled.words.count == 800,
      "The provenance record and the measured 92.7% recall both describe an 800-entry lexicon. A different count means the resource and its provenance have drifted apart."
    )
  }

  @Test("Every bundled entry satisfies the committed normalisation grammar")
  func bundledEntriesAreWellFormed() {
    let offenders = OrdinaryLowercaseLexicon.bundled.words
      .filter { OrdinaryLowercaseLexicon.isWellFormedEntry($0) == false }
      .sorted()
    #expect(offenders.isEmpty, "malformed entries: \(offenders.prefix(10))")
  }

  @Test("No bundled entry carries an uppercase character or a digit")
  func bundledEntriesAreLowercaseAndDigitFree() {
    let offenders = OrdinaryLowercaseLexicon.bundled.words
      .filter { $0.contains(where: { $0.isUppercase || $0.isNumber }) }
      .sorted()
    #expect(offenders.isEmpty, "offending entries: \(offenders.prefix(10))")
  }

  @Test("No bundled entry contains the Unicode right single quote")
  func bundledEntriesUseAsciiApostrophes() {
    let offenders = OrdinaryLowercaseLexicon.bundled.words
      .filter { $0.contains("\u{2019}") }
      .sorted()
    #expect(offenders.isEmpty, "offending entries: \(offenders.prefix(10))")
  }

  // MARK: - The exclusion class, one word at a time

  @Test("The exclusion class holds exactly 456 words across seven axes")
  func exclusionClassCount() {
    #expect(OrdinaryLowercaseExclusionClass.words.count == 456)
  }

  @Test(
    "No excluded word appears in the shipped lexicon",
    arguments: OrdinaryLowercaseExclusionClass.words.sorted())
  func excludedWordIsAbsent(_ word: String) {
    #expect(
      OrdinaryLowercaseLexicon.bundled.words.contains(word) == false,
      "'\(word)' is also a name, brand, language, place, weekday, month, or the pronoun I. Lowercasing a capitalised occurrence of it would render that in lowercase."
    )
  }

  // MARK: - Known production openers must still be permitted

  @Test(
    "Known ordinary opener is present in the shipped lexicon",
    arguments: ["testing", "yesterday", "so", "okay", "the", "actually", "because"])
  func knownOpenerIsPresent(_ word: String) {
    #expect(
      OrdinaryLowercaseLexicon.bundled.contains(word),
      "'\(word)' is a measured real dictation opener; dropping it silently reduces coverage.")
  }

  @Test(
    "The bundled lexicon makes known openers lowercase in continuation context",
    arguments: [
      ("Testing now.", "testing now. "),
      ("Yesterday was fine.", "yesterday was fine. "),
      ("So", "so "),
      ("Okay", "okay "),
      ("The", "the "),
      ("Actually", "actually "),
      ("Because", "because "),
    ])
  func bundledKnownOpenerActuallyLowercases(_ testCase: (input: String, expected: String)) {
    // Membership alone would pass even if production never consulted the
    // bundled resource. This drives the PRODUCTION `repair(text:context:
    // protectedWords:language:)` overload, so it fails if that path stops
    // loading it.
    let payloads = CursorInsertionRepair.repair(
      text: testCase.input,
      context: CursorInsertionRepair.CaretText(left: "We were ", right: ""),
      protectedWords: [],
      language: "en")

    #expect(payloads.repairedText == testCase.expected)
    #expect(payloads.candidateRules.contains(.lowercasedFirst))
  }

  @Test(
    "Lookup trims surrounding punctuation and quotation marks",
    arguments: [
      ("\"The\"", true),
      ("(Because),", true),
      ("\u{201C}Let\u{2019}s\u{201D}", true),
      ("[Zorbitrax]", false),
    ])
  func lookupTrimsSurroundingPunctuation(_ testCase: (token: String, expected: Bool)) {
    // The committed provenance record promises this trim; without it the
    // shipped resource and its own documentation disagree.
    #expect(
      OrdinaryLowercaseLexicon.bundled.contains(testCase.token) == testCase.expected,
      "\(testCase.token)")
  }

  @Test("Trimming does not strip an internal apostrophe")
  func trimmingKeepsInternalApostrophe() {
    #expect(OrdinaryLowercaseLexicon.normalizeLookupToken("\"let's\"") == "let's")
    #expect(OrdinaryLowercaseLexicon.normalizeLookupToken("Don\u{2019}t,") == "don't")
  }

  @Test(
    "A word the lexicon deliberately omits stays omitted",
    arguments: ["store", "pricing", "dude", "codex", "hola"])
  func deliberatelyOmittedWordStaysOmitted(_ word: String) {
    // `store` and `pricing` came from the prototype's toy set and were withdrawn
    // as production examples; the rest are speaker-specific or brand names. The
    // lexicon must not have been padded to rescue an illustration.
    #expect(OrdinaryLowercaseLexicon.bundled.contains(word) == false, "\(word)")
  }

  // MARK: - Lookup normalisation

  @Test(
    "Lookup folds the Unicode right single quote to ASCII",
    arguments: ["let\u{2019}s", "it\u{2019}s", "don\u{2019}t", "we\u{2019}re", "that\u{2019}s"])
  func lookupFoldsCurlyApostrophe(_ word: String) {
    // Cloud polish emits U+2019; the resource stores U+0027. Without folding,
    // every contraction would silently miss.
    #expect(OrdinaryLowercaseLexicon.bundled.contains(word), "\(word)")
  }

  @Test(
    "Lookup is case-insensitive on the caller's side",
    arguments: ["The", "THE", "tHe", "Because", "BECAUSE"])
  func lookupIsCaseInsensitive(_ word: String) {
    #expect(OrdinaryLowercaseLexicon.bundled.contains(word), "\(word)")
  }

  @Test("Lookup does not lowercase using the current locale")
  func lookupIsLocaleIndependent() {
    // Turkish dotless-i is the classic locale trap: a locale-aware lowercase of
    // "I" yields "ı", which would never match an ASCII entry.
    #expect(OrdinaryLowercaseLexicon.bundled.contains("If"))
    #expect(OrdinaryLowercaseLexicon.bundled.contains("It"))
  }

  @Test("An unavailable lexicon contains nothing, even a valid word")
  func unavailableLexiconContainsNothing() {
    #expect(OrdinaryLowercaseLexicon.unavailable.contains("the") == false)
    #expect(OrdinaryLowercaseLexicon.unavailable.isAvailable == false)
  }

  // MARK: - Grammar validation

  @Test(
    "Well-formed entry is accepted",
    arguments: ["the", "a", "let's", "don't", "yesterday", "additionally"])
  func wellFormedEntryAccepted(_ entry: String) {
    #expect(OrdinaryLowercaseLexicon.isWellFormedEntry(entry), "\(entry)")
  }

  @Test(
    "Malformed entry is rejected",
    arguments: [
      "", "The", "NASA", "v2", "s3", "'tis", "cant'", "two words", "co-op",
      "caf\u{00E9}", "let''s", "it's's", "a'b'c", "\u{2019}", "0",
    ])
  func malformedEntryRejected(_ entry: String) {
    #expect(OrdinaryLowercaseLexicon.isWellFormedEntry(entry) == false, "\(entry)")
  }

  // MARK: - Parse failure modes, all of which must fail CLOSED

  @Test("A well-formed document parses")
  func parsesWellFormedDocument() {
    let lexicon = OrdinaryLowercaseLexicon.parse(
      """
      # a comment

      the
      because
      let's
      """)
    #expect(lexicon.isAvailable)
    #expect(lexicon.words == ["the", "because", "let's"])
  }

  @Test("Comments and blank lines are ignored, including indented ones")
  func ignoresCommentsAndBlankLines() {
    let lexicon = OrdinaryLowercaseLexicon.parse(
      """
      # header

         # indented comment
      the

      """)
    #expect(lexicon.words == ["the"])
  }

  @Test(
    "A malformed line invalidates the whole resource rather than being skipped",
    arguments: ["The", "NASA", "v2", "two words", "caf\u{00E9}", "'tis", "cant'"])
  func malformedLineInvalidatesResource(_ badLine: String) {
    // Skipping bad lines would make coverage unreproducible and let a corrupted
    // resource silently under-fire. Fail closed instead.
    let lexicon = OrdinaryLowercaseLexicon.parse("the\n\(badLine)\nbecause")
    #expect(lexicon.isAvailable == false, "\(badLine)")
    #expect(lexicon.words.isEmpty, "\(badLine)")
  }

  @Test("A duplicate entry invalidates the whole resource")
  func duplicateInvalidatesResource() {
    let lexicon = OrdinaryLowercaseLexicon.parse("the\nbecause\nthe")
    #expect(lexicon.isAvailable == false)
  }

  @Test("A duplicate that differs only by apostrophe form is still a duplicate")
  func apostropheFormDuplicateIsDetected() {
    let lexicon = OrdinaryLowercaseLexicon.parse("let's\nlet\u{2019}s")
    #expect(
      lexicon.isAvailable == false,
      "Both spellings normalise to the same entry, so this is a duplicate.")
  }

  @Test("An empty document is unavailable, not an empty success")
  func emptyDocumentIsUnavailable() {
    #expect(OrdinaryLowercaseLexicon.parse("").isAvailable == false)
    #expect(OrdinaryLowercaseLexicon.parse("# only a comment\n\n").isAvailable == false)
  }

  @Test("Trailing whitespace on a line does not invalidate it")
  func trailingWhitespaceTolerated() {
    let lexicon = OrdinaryLowercaseLexicon.parse("the   \n  because\t\n")
    #expect(lexicon.isAvailable)
    #expect(lexicon.words == ["the", "because"])
  }

  // MARK: - A broken lexicon degrades case repair only

  @Test("Missing lexicon leaves spacing and terminal-period repair working")
  func missingLexiconDegradesCaseOnly() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      // Comma to the left, letter to the right: spacing and period rules fire
      // and the caret is not inside a word.
      context: CursorInsertionRepair.CaretText(left: "I went home,", right: "yesterday"),
      protectedWords: [],
      lexicon: .unavailable)

    #expect(payloads.candidateRules.contains(.caseSkipped(.lexiconUnavailable)))
    #expect(payloads.candidateRules.contains(.leadingSpace))
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod))
    #expect(payloads.candidateRules.contains(.trailingSpace))
    #expect(payloads.repairedText == " Store today ")
  }

  @Test("Malformed lexicon data degrades case repair only")
  func malformedLexiconDegradesCaseOnly() {
    let broken = OrdinaryLowercaseLexicon.parse("the\nNASA")
    #expect(broken.isAvailable == false)

    let payloads = CursorInsertionRepair.repair(
      text: "The report is ready.",
      context: CursorInsertionRepair.CaretText(left: "I said ", right: "yesterday"),
      protectedWords: [],
      lexicon: broken)

    #expect(payloads.candidateRules.contains(.caseSkipped(.lexiconUnavailable)))
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod))
    #expect(payloads.repairedText?.hasPrefix("The") == true, "case left alone")
  }

  @Test("An unavailable lexicon never changes legacyText")
  func unavailableLexiconLeavesLegacyIntact() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [],
      lexicon: .unavailable)
    #expect(payloads.legacyText == "Store today. ")
  }
}
