import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Complete-span number parsing (#1677, PR 2 chunk 3)
//
// These tests drive the PURE parser and the grammar value built from the generated data. Nothing
// here is wired into runtime normalization, and nothing here says a German sentence converts
// correctly: a parsed number is syntax recognition, never permission to convert.
//
// Expectations are independent literals written from German number words (plus the frozen
// development rows, read field by field), never read back from the grammar under test.
//
// When this fails, a later pass would read a wrong value, accept a prefix of a longer phrase, or
// treat an article or a fraction word as a number.

@Suite("German number parser (#1677)", .tags(.driftGuard))
struct LanguageNumberParserTests {

  let grammar: LanguageNumberGrammar
  let parser: LanguageNumberParser

  init() throws {
    grammar = try LanguageNumberGrammar.german()
    parser = LanguageNumberParser(grammar: grammar)
  }

  // MARK: Helpers

  private func parse(_ kind: LanguageNumberKind, _ text: String) -> LanguageNumberResult {
    let snapshot = LanguageTextSnapshot(text)
    return parser.parse(kind, in: snapshot, range: 0..<snapshot.utf16Count)
  }

  private func value(_ kind: LanguageNumberKind, _ text: String) -> Int? {
    if case .parsed(let number) = parse(kind, text) { return number.value }
    return nil
  }

  private func refusal(_ kind: LanguageNumberKind, _ text: String) -> LanguageNumberRefusal? {
    if case .refused(let reason) = parse(kind, text) { return reason }
    return nil
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let text: String
    let value: Int
    var testDescription: String { "\(text) = \(value)" }
  }

  // MARK: Grammar derivation

  @Test("the grammar derives its composition from the data: connector, one-form, article forms")
  func grammarFacts() {
    #expect(grammar.connector == "und")
    #expect(grammar.compoundUnits["ein"] == 1)
    #expect(grammar.compoundUnits["eins"] == nil)
    #expect(grammar.compoundUnits["eine"] == nil)
    #expect(grammar.compoundUnits.count == 9)
    #expect(grammar.standalone["eins"] == 1)
    #expect(grammar.standalone["ein"] == nil)
    #expect(grammar.standalone["eine"] == nil)
    #expect(grammar.nonStandalone == ["ein", "eine"])
    #expect(grammar.tens.count == 8)
    #expect(grammar.tens["dreißig"] == 30)
    #expect(grammar.limits == .supported)
    #expect(grammar.limits.cardinalMax == 99)
    #expect(grammar.limits.ordinalRange == 1...31)
    #expect(grammar.limits.clockHourRange == 1...12)
    #expect(grammar.limits.candidateUTF16Max == 128)
    #expect(grammar.limits.candidateTokenMax == 8)
    // 31 ordinals in three admitted spellings each (base, -n, -r), no collisions.
    #expect(grammar.ordinalForms.count == 93)
  }

  // MARK: Cardinals

  static let cardinals: [Case] = [
    Case(text: "null", value: 0), Case(text: "eins", value: 1), Case(text: "zwei", value: 2),
    Case(text: "drei", value: 3), Case(text: "vier", value: 4), Case(text: "fünf", value: 5),
    Case(text: "sechs", value: 6), Case(text: "sieben", value: 7), Case(text: "acht", value: 8),
    Case(text: "neun", value: 9), Case(text: "zehn", value: 10), Case(text: "elf", value: 11),
    Case(text: "zwölf", value: 12), Case(text: "dreizehn", value: 13),
    Case(text: "vierzehn", value: 14), Case(text: "fünfzehn", value: 15),
    Case(text: "sechzehn", value: 16), Case(text: "siebzehn", value: 17),
    Case(text: "achtzehn", value: 18), Case(text: "neunzehn", value: 19),
    Case(text: "zwanzig", value: 20), Case(text: "einundzwanzig", value: 21),
    Case(text: "zweiundzwanzig", value: 22), Case(text: "dreiundzwanzig", value: 23),
    Case(text: "fünfundvierzig", value: 45), Case(text: "dreißig", value: 30),
    Case(text: "einunddreißig", value: 31), Case(text: "sechsundsechzig", value: 66),
    Case(text: "siebenundsiebzig", value: 77), Case(text: "achtundachtzig", value: 88),
    Case(text: "neunzig", value: 90), Case(text: "neunundneunzig", value: 99),
    Case(text: "Dreiundzwanzig", value: 23), Case(text: "DREIUNDZWANZIG", value: 23),
    Case(text: "Dreißig", value: 30),
  ]

  @Test("cardinals 0 through 99 parse to the independently known value", arguments: cardinals)
  func cardinalValues(_ item: Case) {
    #expect(value(.cardinal, item.text) == item.value)
  }

  @Test("every value 21 through 99 that is not a multiple of ten parses in its glued form")
  func everyCompoundParses() {
    let units = [
      "ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun",
    ]
    let tens = [
      "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig",
    ]
    var checked = 0
    for (tensIndex, tensWord) in tens.enumerated() {
      for (unitIndex, unitWord) in units.enumerated() {
        let expected = (tensIndex + 2) * 10 + unitIndex + 1
        #expect(
          value(.cardinal, unitWord + "und" + tensWord) == expected, "\(unitWord)und\(tensWord)")
        checked += 1
      }
    }
    #expect(checked == 72)
  }

  @Test("a spaced tokenization is admitted only at the composition's two joints")
  func spacedComposition() {
    #expect(value(.cardinal, "drei und zwanzig") == 23)
    #expect(value(.cardinal, "dreiund zwanzig") == 23)
    #expect(value(.cardinal, "drei undzwanzig") == 23)
    #expect(value(.cardinal, "ein und zwanzig") == 21)
    #expect(value(.cardinal, "drei  und \t zwanzig") == 23)
    // Controls: a split inside a word is not a joint.
    #expect(refusal(.cardinal, "dr ei und zwanzig") == .notAdmitted)
    #expect(refusal(.cardinal, "drei un dzwanzig") == .notAdmitted)
    #expect(refusal(.cardinal, "dreiundzwan zig") == .notAdmitted)
    #expect(refusal(.cardinal, "drei und zwan zig") == .notAdmitted)
  }

  static let refusedCardinals: [String] = [
    "eineundzwanzig", "einsundzwanzig", "hundert", "einhundert", "zweihundert", "tausend",
    "eintausend", "minus drei", "drei komma fünf", "dreikommafünf", "drei halbe", "three", "3",
    "drei3", "3drei", "dreiundzwanzigste", "zwanzig drei", "drei zwanzig", "zwei drei",
    "und zwanzig", "dreiundundzwanzig", "dreiundzwanzig und", "halb eins", "eine million",
    "millionen", "null null", "hundertein", "dreihundert", "dreiunddreißigs", "dreiundzwanzig-",
    "drei-und-zwanzig", "dreiunddreissig", "zwei und", "und", "ein viertel", "dreiviertel",
    "zwoundzwanzig", "ten", "twenty three", "am", "abend", "pm",
  ]

  @Test("forms outside the grammar refuse as a whole", arguments: refusedCardinals)
  func cardinalRefusals(_ text: String) {
    #expect(value(.cardinal, text) == nil, "\(text.debugDescription)")
    #expect(refusal(.cardinal, text) != nil)
  }

  @Test("a bare article form is an article, not a number; a compound one-form is licensed")
  func articleForms() {
    #expect(refusal(.cardinal, "ein") == .articleForm)
    #expect(refusal(.cardinal, "eine") == .articleForm)
    #expect(refusal(.cardinal, "Ein") == .articleForm)
    #expect(refusal(.clockHour, "ein") == .articleForm)
    #expect(refusal(.ordinal, "ein") == .articleForm)
    #expect(value(.cardinal, "einundzwanzig") == 21)
    #expect(value(.cardinal, "eins") == 1)
  }

  @Test("unknown or rejected input never becomes zero")
  func nothingBecomesZero() {
    for text in ["nul", "nulll", "zero", "0", "", "  ", "null1", "nullnull"] {
      #expect(value(.cardinal, text) == nil, "\(text.debugDescription)")
    }
    #expect(value(.cardinal, "null") == 0)
    #expect(refusal(.cardinal, "") == .emptyCandidate)
  }

  // MARK: Candidate shape and limits

  @Test("tightness: leading or trailing whitespace refuses; so does a line break inside")
  func tightness() {
    #expect(refusal(.cardinal, " drei") == .notTight)
    #expect(refusal(.cardinal, "drei ") == .notTight)
    #expect(refusal(.cardinal, " ") == .notTight)
    #expect(refusal(.cardinal, "drei\nund zwanzig") == .crossesLineBreak)
    #expect(refusal(.cardinal, "drei\r\nund zwanzig") == .crossesLineBreak)
    #expect(refusal(.cardinal, "drei\u{2028}und zwanzig") == .crossesLineBreak)
    #expect(refusal(.cardinal, "drei\u{0085}und zwanzig") == .crossesLineBreak)
    #expect(value(.cardinal, "drei\u{00A0}und\u{00A0}zwanzig") == 23)
  }

  @Test("the UTF-16 limit is exact: 127 and 128 parse, 129 refuses before any word is read")
  func utf16Limit() {
    func padded(total: Int) -> String {
      let spaces = total - "dreiundzwanzig".utf16.count  // the two joints take the padding
      return "drei" + String(repeating: " ", count: 1) + "und"
        + String(repeating: " ", count: spaces - 1) + "zwanzig"
    }
    for total in [127, 128] {
      let text = padded(total: total)
      #expect(text.utf16.count == total)
      #expect(value(.cardinal, text) == 23, "\(total)")
    }
    let over = padded(total: 129)
    #expect(over.utf16.count == 129)
    #expect(refusal(.cardinal, over) == .exceedsUTF16Limit)
    // The limit counts UTF-16 units, not characters: 65 astral characters are 130 units.
    #expect(refusal(.cardinal, String(repeating: "𝟘", count: 65)) == .exceedsUTF16Limit)
  }

  @Test("the token limit is exact: 8 tokens reach the grammar, 9 refuse as too many")
  func tokenLimit() {
    let eight = Array(repeating: "eins", count: 8).joined(separator: " ")
    let nine = Array(repeating: "eins", count: 9).joined(separator: " ")
    #expect(refusal(.cardinal, eight) == .notAdmitted)
    #expect(refusal(.cardinal, nine) == .exceedsTokenLimit)
  }

  @Test("a valid number inside a longer sentence parses only the exact span asked for")
  func exactSpan() throws {
    let text = "Sie wohnt im dreiundzwanzigsten Stock und zahlt dreißig Euro."
    let snapshot = LanguageTextSnapshot(text)
    let word = try #require(ITNFixtureRanges.range(of: "dreißig", in: text))
    guard case .parsed(let number) = parser.parse(.cardinal, in: snapshot, range: word) else {
      Issue.record("dreißig did not parse")
      return
    }
    #expect(number.value == 30)
    #expect(number.range == word)
    #expect(number.tokenRanges == [word])
    #expect(number.source == "dreißig")
    // The same span widened by one character is not a number: no valid prefix is returned.
    let wider = word.lowerBound..<(word.upperBound + 1)
    #expect(parser.parse(.cardinal, in: snapshot, range: wider) == .refused(.notTight))
    let wideAgain = word.lowerBound..<(word.upperBound + 2)
    #expect(parser.parse(.cardinal, in: snapshot, range: wideAgain) == .refused(.notAdmitted))
    // Out-of-bounds and scalar-splitting ranges refuse.
    #expect(
      parser.parse(.cardinal, in: snapshot, range: 0..<(snapshot.utf16Count + 1))
        == .refused(.outOfBounds))
    let astral = LanguageTextSnapshot("𝟘 drei")
    #expect(parser.parse(.cardinal, in: astral, range: 1..<6) == .refused(.splitsCharacter))
  }

  // MARK: Ordinals

  static let ordinals: [Case] = [
    Case(text: "erste", value: 1), Case(text: "ersten", value: 1), Case(text: "erster", value: 1),
    Case(text: "zweite", value: 2), Case(text: "zweiten", value: 2),
    Case(text: "dritte", value: 3), Case(text: "dritten", value: 3),
    Case(text: "vierte", value: 4), Case(text: "fünften", value: 5),
    Case(text: "sechsten", value: 6), Case(text: "siebte", value: 7),
    Case(text: "siebten", value: 7), Case(text: "siebter", value: 7), Case(text: "achte", value: 8),
    Case(text: "achten", value: 8), Case(text: "neunte", value: 9),
    Case(text: "zehnten", value: 10),
    Case(text: "elfte", value: 11), Case(text: "elften", value: 11),
    Case(text: "zwölfte", value: 12), Case(text: "zwölften", value: 12),
    Case(text: "dreizehnte", value: 13), Case(text: "vierzehnten", value: 14),
    Case(text: "fünfzehnte", value: 15), Case(text: "sechzehnten", value: 16),
    Case(text: "siebzehnten", value: 17), Case(text: "achtzehnte", value: 18),
    Case(text: "neunzehnter", value: 19), Case(text: "zwanzigste", value: 20),
    Case(text: "einundzwanzigste", value: 21), Case(text: "einundzwanzigsten", value: 21),
    Case(text: "zweiundzwanzigster", value: 22), Case(text: "dreiundzwanzigste", value: 23),
    Case(text: "fünfundzwanzigsten", value: 25), Case(text: "dreißigste", value: 30),
    Case(text: "einunddreißigste", value: 31), Case(text: "Dritten", value: 3),
    Case(text: "ZWÖLFTE", value: 12),
  ]

  @Test("ordinals 1 through 31 parse in the base, -n and -r forms", arguments: ordinals)
  func ordinalValues(_ item: Case) {
    #expect(value(.ordinal, item.text) == item.value)
  }

  static let refusedOrdinals: [String] = [
    "nullte", "zweiunddreißigste", "dreiunddreißigsten", "fünfzigste", "hundertste", "erstes",
    "erstem", "dritte s", "erstens", "zweitens", "drittens", "viertens", "drittel", "viertel",
    "fünftel", "zwanzigstel", "dritt", "ein", "eine", "eins", "dritteln", "erst", "zweimal",
    "dritter-", "1.", "3te", "third", "second", "ersteres", "einzwanzigste", "zweite hilfe",
    "erste hilfe", "ein drittel", "dreißigstes", "einundzwanzigstes", "einundzwanzigstem",
  ]

  @Test(
    "ordinals outside the admitted scope refuse, including -s, -m and look-alikes",
    arguments: refusedOrdinals)
  func ordinalRefusals(_ text: String) {
    #expect(value(.ordinal, text) == nil, "\(text.debugDescription)")
  }

  @Test("a spaced ordinal is admitted only at the composition's joints")
  func spacedOrdinal() {
    #expect(value(.ordinal, "ein und zwanzigste") == 21)
    #expect(value(.ordinal, "einund zwanzigste") == 21)
    #expect(value(.ordinal, "ein undzwanzigste") == 21)
    #expect(refusal(.ordinal, "einundzwanzig ste") == .notAdmitted)
    #expect(refusal(.ordinal, "dri tte") == .notAdmitted)
    #expect(refusal(.ordinal, "zwan zigste") == .notAdmitted)
  }

  // MARK: Clock hours

  @Test("clock hours are eins through zwölf as one word; everything else refuses")
  func clockHours() {
    let hours: [(String, Int)] = [
      ("eins", 1), ("zwei", 2), ("drei", 3), ("vier", 4), ("fünf", 5), ("sechs", 6),
      ("sieben", 7), ("acht", 8), ("neun", 9), ("zehn", 10), ("elf", 11), ("zwölf", 12),
    ]
    for (word, expected) in hours {
      #expect(value(.clockHour, word) == expected, "\(word)")
    }
    for word in ["null", "dreizehn", "zwanzig", "einundzwanzig", "ein", "eine", "halb", "viertel"] {
      #expect(value(.clockHour, word) == nil, "\(word)")
    }
    #expect(refusal(.clockHour, "null") == .outOfRange)
    #expect(refusal(.clockHour, "dreizehn") == .outOfRange)
    #expect(refusal(.clockHour, "drei und zwanzig") == .notAdmitted)
    #expect(refusal(.clockHour, "halb eins") == .notAdmitted)
  }

  @Test("a clock hour may be one or two ASCII digits 1 to 12; digits are never a cardinal or ordinal")
  func digitClockHours() {
    for hour in 1...12 {
      #expect(value(.clockHour, "\(hour)") == hour, "\(hour)")
    }
    for (word, expected) in [("01", 1), ("08", 8), ("09", 9)] {
      #expect(value(.clockHour, word) == expected, "\(word)")
    }
    for word in ["0", "00", "13", "20", "99", "008", "123"] {
      #expect(value(.clockHour, word) == nil, "\(word)")
    }
    #expect(refusal(.clockHour, "13") == .outOfRange)
    #expect(refusal(.clockHour, "0") == .outOfRange)
    for word in ["8:30", "8.", "8%", "8er", "\u{FF18}", "\u{0668}", "8 9", "-8", "+8"] {
      #expect(value(.clockHour, word) == nil, "\(word.debugDescription)")
    }
    for word in ["8", "12", "08"] {
      #expect(value(.cardinal, word) == nil, "\(word)")
      #expect(value(.ordinal, word) == nil, "\(word)")
    }
  }

  // MARK: Unicode: lookup is folded, ranges are original

  @Test("NFC and NFD spellings mean the same number and keep their own original ranges")
  func nfcAndNfdKeepOriginalRanges() throws {
    let nfc = "Der zw\u{00F6}lfte Platz"
    let nfd = "Der zwo\u{0308}lfte Platz"
    #expect(nfc.utf16.count == 17)
    #expect(nfd.utf16.count == 18)
    for (text, wordText, length) in [(nfc, "zw\u{00F6}lfte", 7), (nfd, "zwo\u{0308}lfte", 8)] {
      let snapshot = LanguageTextSnapshot(text)
      let word = try #require(ITNFixtureRanges.range(of: wordText, in: text))
      #expect(word == 4..<(4 + length))
      guard case .parsed(let number) = parser.parse(.ordinal, in: snapshot, range: word) else {
        Issue.record("\(wordText.debugDescription) did not parse")
        continue
      }
      #expect(number.value == 12)
      #expect(number.range == word)
      #expect(number.tokenRanges == [word])
      #expect(Array(number.source.utf8) == Array(wordText.utf8))
      #expect(snapshot.substring(word).map { Array($0.utf8) } == Array(wordText.utf8))
    }
    // The same holds for a cardinal and for a decomposed compound.
    #expect(value(.cardinal, "fu\u{0308}nf") == 5)
    #expect(value(.cardinal, "fu\u{0308}nfundvierzig") == 45)
    #expect(value(.ordinal, "fu\u{0308}nften") == 5)
  }

  @Test("combining marks are part of the word: a split before one is a refusal")
  func combiningBoundaries() {
    let text = "zwo\u{0308}lf"
    let snapshot = LanguageTextSnapshot(text)
    #expect(snapshot.utf16Count == 6)
    #expect(parser.parse(.cardinal, in: snapshot, range: 0..<6).isParsed)
    // 0..<3 ends between the o and its diaeresis: it would split an original character.
    #expect(parser.parse(.cardinal, in: snapshot, range: 0..<3) == .refused(.splitsCharacter))
    // The same letters as a separate word are only an unknown word.
    #expect(refusal(.cardinal, "zwo") == .notAdmitted)
  }

  // MARK: Mixed language

  @Test("English number and time words inside German text are not numbers")
  func englishWordsAreNotNumbers() {
    for word in ["one", "two", "three", "ten", "twenty", "thirty", "am", "pm", "a.m."] {
      #expect(value(.cardinal, word) == nil, "\(word)")
      #expect(value(.ordinal, word) == nil, "\(word)")
      #expect(value(.clockHour, word) == nil, "\(word)")
    }
  }

  @Test("German prose am Abend is not a meridiem and holds no number")
  func amAbend() {
    #expect(value(.cardinal, "am Abend") == nil)
    #expect(value(.clockHour, "am") == nil)
    #expect(value(.clockHour, "Abend") == nil)
  }

  @Test("fraction, article and idiom phrases that contain a known atom are not numbers")
  func lookAlikes() {
    for text in [
      "halb eins", "ein Viertel", "ein Drittel", "eine Million", "Erste Hilfe", "zweimal",
      "einmal", "dreifach", "zweitens", "Dreiviertel", "einzeln", "Einerseits", "vierteln",
    ] {
      #expect(value(.cardinal, text) == nil, "\(text)")
      #expect(value(.ordinal, text) == nil, "\(text)")
    }
  }

  // MARK: Frozen development rows (independent oracles from the corpus fields)

  @Test("the frozen development rows load with pending rows excluded")
  func developmentMembership() throws {
    let loaded = try ITNDevelopmentFixtures.development()
    #expect(loaded.rows.count == 60)
    #expect(loaded.rows.allSatisfy { $0.expectedAction == "convert" && $0.split == "development" })
    #expect(Set(loaded.rows.map(\.category)) == ["clock_idiom", "ordinal", "phone_country_prefix"])
    for category in ["clock_idiom", "ordinal", "phone_country_prefix"] {
      #expect(loaded.rows.filter { $0.category == category }.count == 20, "\(category)")
    }
    #expect(loaded.pendingExcluded == loaded.totalInFile - 60)
    #expect(loaded.pendingExcluded > 0, "the pending clock rows must be present and excluded")
  }

  @Test("every development ordinal's spoken span parses to the value its written form states")
  func developmentOrdinals() throws {
    var asserted = 0
    for row in try ITNDevelopmentFixtures.development().rows where row.category == "ordinal" {
      let span = try #require(row.targetSpans.first, "\(row.id)")
      let written = try #require(span.writtenForms.first, "\(row.id)")
      let expected = try #require(Int(written.dropLast()), "\(row.id): \(written)")
      #expect(written.hasSuffix("."), "\(row.id)")
      let snapshot = LanguageTextSnapshot(row.spokenInput)
      let range = try #require(
        ITNFixtureRanges.range(of: span.spokenSpan, in: row.spokenInput), "\(row.id)")
      guard case .parsed(let number) = parser.parse(.ordinal, in: snapshot, range: range) else {
        Issue.record("\(row.id): \(span.spokenSpan) did not parse as an ordinal")
        continue
      }
      #expect(number.value == expected, "\(row.id)")
      #expect(number.range == range, "\(row.id)")
      asserted += 1
    }
    #expect(asserted == 20)
  }

  @Test("every development clock row's hour word parses to the hour its written form implies")
  func developmentClockHours() throws {
    var asserted = 0
    for row in try ITNDevelopmentFixtures.development().rows where row.category == "clock_idiom" {
      let span = try #require(row.targetSpans.first, "\(row.id)")
      let written = try #require(span.writtenForms.first, "\(row.id)")
      let writtenHour = try #require(
        Int(written.prefix { $0 != ":" && $0 != "." }), "\(row.id): \(written)")
      let words = span.spokenSpan.split(separator: " ").map(String.init)
      let hourWord = try #require(words.last, "\(row.id)")
      // "halb sieben" is 6:30; "viertel nach vier" is 4:15 (independent of the parser).
      let expectedHour: Int
      switch words.first {
      case "halb": expectedHour = writtenHour + 1
      case "viertel": expectedHour = writtenHour
      default:
        Issue.record("\(row.id): unexpected clock form \(span.spokenSpan)")
        continue
      }
      let spanRange = try #require(
        ITNFixtureRanges.range(of: span.spokenSpan, in: row.spokenInput), "\(row.id)")
      let hourRange = try #require(
        ITNFixtureRanges.range(
          of: hourWord, in: row.spokenInput, within: spanRange, backwards: true), "\(row.id)")
      let snapshot = LanguageTextSnapshot(row.spokenInput)
      guard case .parsed(let number) = parser.parse(.clockHour, in: snapshot, range: hourRange)
      else {
        Issue.record("\(row.id): \(hourWord) did not parse as a clock hour")
        continue
      }
      #expect(number.value == expectedHour, "\(row.id)")
      asserted += 1
    }
    #expect(asserted == 20)
  }

  // MARK: Frozen control rows: only the primitive property a row genuinely reaches

  @Test("control rows whose lexical trap is a fraction word or an adverb refuse as ordinals")
  func controlLexicalRefusals() throws {
    let loaded = try ITNDevelopmentFixtures.controls()
    #expect(loaded.rows.count == 177)
    #expect(
      loaded.pendingExcluded > 0, "the pending regional controls must be present and excluded")
    var visited = 0
    var asserted = 0
    let fractionRows = loaded.rows.filter { $0.category == "ordinal" && $0.refusalReason == "fraction_word" }
    let adverbRows = loaded.rows.filter { $0.category == "ordinal" && $0.refusalReason == "adverb_form" }
    #expect(fractionRows.count == 5)
    #expect(adverbRows.count == 4)
    for row in loaded.rows {
      visited += 1
      guard row.category == "ordinal" else { continue }
      let words = row.spokenInput.split(separator: " ").map {
        String($0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")))
      }
      switch row.refusalReason {
      case "fraction_word":
        // The fraction word ends in "tel" (Drittel, Viertel, Fünftel, ...); the article before it
        // is "ein"/"Ein". Neither is an ordinal, and the article is not a cardinal.
        let fractions = words.filter { $0.lowercased().hasSuffix("tel") }
        #expect(fractions.count == 1, "\(row.id): \(row.spokenInput)")
        for word in fractions {
          #expect(value(.ordinal, word) == nil, "\(row.id): \(word)")
          asserted += 1
        }
        let article = words.first { $0.lowercased() == "ein" }
        #expect(article != nil, "\(row.id)")
        if let article {
          #expect(refusal(.cardinal, article) == .articleForm, "\(row.id)")
          asserted += 1
        }
      case "adverb_form":
        let adverbs = words.filter { $0.lowercased().hasSuffix("ens") }
        #expect(adverbs.count == 1, "\(row.id): \(row.spokenInput)")
        for word in adverbs {
          #expect(value(.ordinal, word) == nil, "\(row.id): \(word)")
          asserted += 1
        }
      default:
        continue
      }
    }
    #expect(visited == 177)
    // Each fraction row asserts its fraction word and its article; each adverb row its adverb.
    #expect(asserted == 2 * fractionRows.count + adverbRows.count)
  }

  // MARK: Reachability guards

  @Test("only the language route uses the passes, the ordinal pass stays unwired, no corpus is named")
  func nothingCallsThePrimitives() throws {
    let root = RepoRoot.url
    let sources = root.appending(path: "Sources")
    let enumerator = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let own: Set<String> = [
      "LanguageNumberGrammar.swift", "LanguageNumberParser.swift", "LanguageProtectedSpans.swift",
      "LanguageTextEdit.swift", "LanguagePhonePrefixRules.swift", "LanguagePhonePrefixPass.swift",
      "LanguageOrdinalRules.swift", "LanguageOrdinalPass.swift", "LanguageClockIdiomRules.swift",
      "LanguageClockIdiomPass.swift", "LanguagePhoneMetadata.swift",
    ]
    let names = [
      "LanguageNumberGrammar", "LanguageNumberParser", "LanguageProtectedSpans",
      "LanguageTextEditor", "LanguageTextSnapshot", "LanguageTextEdit", "LanguagePhonePrefixPass",
      "LanguagePhonePrefixRules", "LanguageOrdinalPass", "LanguageOrdinalRules",
      "LanguageOrdinalContextEvidence", "LanguageClockIdiomPass", "LanguageClockIdiomRules",
      "LanguagePhoneMetadata",
    ]
    var scanned = 0
    var callers: [String] = []
    for case let file as URL in enumerator where file.pathExtension == "swift" {
      scanned += 1
      if own.contains(file.lastPathComponent) { continue }
      let text = try String(contentsOf: file, encoding: .utf8)
      if names.contains(where: { text.contains($0) }) { callers.append(file.lastPathComponent) }
    }
    #expect(scanned > 100, "the scan must read the source tree (read \(scanned))")
    #expect(
      callers == ["InverseTextNormalizer+Language.swift"],
      "runtime users of the language primitives must be the language route only: \(callers)")
    let route = try String(
      contentsOf: sources.appending(path: "EnviousWisprPostProcessing/InverseTextNormalizer+Language.swift"),
      encoding: .utf8)
    #expect(!route.contains("LanguageOrdinal"), "the ordinal pass is pending and must not run")

    // The acceptance corpus file is not opened by anything this chunk adds.
    let needle = ["hold", "out.jsonl"].joined()
    let newFiles =
      own.map { sources.appending(path: "EnviousWisprPostProcessing/\($0)") }
      + [
        "LanguageNumberParserTests.swift", "LanguageProtectedSpansTests.swift",
        "ITNDevelopmentFixtureSupport.swift", "LanguagePhonePrefixPassTests.swift",
        "LanguageOrdinalPassTests.swift", "LanguageClockIdiomPassTests.swift",
        "LanguagePhoneMetadataTests.swift",
      ].map { root.appending(path: "Tests/EnviousWisprTests/PostProcessing/\($0)") }
    for url in newFiles {
      let text = try String(contentsOf: url, encoding: .utf8)
      #expect(text.contains(needle) == false, "\(url.lastPathComponent) names the held-out corpus")
    }
  }
}

extension LanguageNumberResult {
  fileprivate var isParsed: Bool {
    if case .parsed = self { return true }
    return false
  }
}
