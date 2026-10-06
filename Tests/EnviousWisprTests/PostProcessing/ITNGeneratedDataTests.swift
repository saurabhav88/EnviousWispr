import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Generated German number data (#1677, PR 2 chunk 1)
//
// `GermanNumberData` is emitted by `scripts/itn/generate.py` from pinned CLDR and NeMo files. These
// checks pin what the compiled table must look like and prove nothing reaches it at runtime.
//
// EVIDENCE BOUNDARY: they prove generation integrity (finite invariants, known atom values from an
// independent literal list, clean literals, and that exactly one adapter reads the data). They
// prove NOTHING about whether any German sentence converts correctly: the table is candidate
// lexical data, not a vetted rule set, and the production `LanguageRuleRegistry` stays empty.
//
// Chunk 3 deliberately moves the data from "read by nothing" to "read by one grammar adapter,
// whose output no runtime caller uses yet": `LanguageNumberGrammar.swift` is the only allowed
// reader, and the reachability test below still fails on any other one.

@Suite("Generated German number data (#1677)", .tags(.driftGuard))
struct ITNGeneratedDataTests {

  private typealias Data = GermanNumberData

  /// Independent literal expectations, written from German number words and not read back from
  /// the generated table.
  private static let knownAtoms: [(spoken: String, value: Int, role: Data.Role)] = [
    ("null", 0, .zero),
    ("eins", 1, .unit),
    ("ein", 1, .unit),
    ("eine", 1, .unit),
    ("zwei", 2, .unit),
    ("sieben", 7, .unit),
    ("neun", 9, .unit),
    ("zehn", 10, .teen),
    ("elf", 11, .teen),
    ("zwölf", 12, .teen),
    ("dreizehn", 13, .teen),
    ("sechzehn", 16, .teen),
    ("siebzehn", 17, .teen),
    ("neunzehn", 19, .teen),
    ("zwanzig", 20, .tens),
    ("dreißig", 30, .tens),
    ("vierzig", 40, .tens),
    ("neunzig", 90, .tens),
  ]

  @Test("representative atoms carry the independently known value and role")
  func knownAtomValues() {
    for known in Self.knownAtoms {
      let matches = Data.atoms.filter {
        $0.spoken.unicodeScalars.elementsEqual(known.spoken.unicodeScalars)
      }
      #expect(matches.count == 1, "\(known.spoken): one atom expected, found \(matches.count)")
      #expect(matches.first?.value == known.value, "\(known.spoken)")
      #expect(matches.first?.role == known.role, "\(known.spoken)")
    }
  }

  @Test("each role covers its whole finite value range")
  func rolesCoverTheirRanges() {
    func values(_ role: Data.Role) -> Set<Int> {
      Set(Data.atoms.filter { $0.role == role }.map(\.value))
    }
    #expect(values(.zero) == [0])
    #expect(values(.unit) == Set(1...9))
    #expect(values(.teen) == Set(10...19))
    #expect(values(.tens) == Set(stride(from: 20, through: 90, by: 10)))
  }

  @Test("one spoken form never means two values in one role, and every atom is traceable")
  func noConflictAndProvenance() {
    var seen: [String: Int] = [:]
    for atom in Data.atoms {
      let key = "\(atom.role.rawValue):\(atom.spoken)"
      if let value = seen[key] {
        #expect(value == atom.value, "\(key) means \(value) and \(atom.value)")
      }
      seen[key] = atom.value
      #expect(atom.sources.isEmpty == false, "\(key) has no provenance")
      for source in atom.sources {
        let id = source.split(separator: "#", maxSplits: 1).first.map(String.init) ?? source
        #expect(Data.sourceIDs.contains(id), "\(key) names unknown source \(source)")
      }
    }
    #expect(Data.atoms.count == 30)
  }

  @Test("spoken forms are precomposed lower-case text with no hidden characters")
  func spokenFormsAreClean() {
    let words = Data.atoms.map(\.spoken) + Data.quantityWords.map(\.spoken)
    #expect(words.isEmpty == false)
    for word in words {
      #expect(word.isEmpty == false)
      let scalars = Array(word.unicodeScalars)
      #expect(
        scalars == Array(word.precomposedStringWithCanonicalMapping.unicodeScalars),
        "\(word) is not NFC")
      #expect(scalars == Array(word.lowercased().unicodeScalars), "\(word) is not lower-case")
      #expect(scalars.contains { $0.value == 0x00AD } == false, "\(word) holds a soft hyphen")
      #expect(word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, "\(word)")
    }
  }

  @Test("the quantity words are the NeMo scale words, once each")
  func quantityWords() {
    let spoken = Data.quantityWords.map(\.spoken)
    #expect(Set(spoken).count == spoken.count)
    for word in ["million", "millionen", "milliarde", "milliarden", "billion", "billionen"] {
      #expect(spoken.contains(word), "\(word)")
    }
    for quantity in Data.quantityWords {
      #expect(quantity.sources == ["nemo-de-quantities"])
    }
  }

  @Test("composition rules are instructions: well-formed, no substitution syntax in a literal")
  func rulesAreInstructionsNotWords() {
    #expect(Data.rules.count == 51)
    let rulesets = Set(Data.rules.map(\.ruleset))
    #expect(
      rulesets == [
        "%spellout-numbering", "%spellout-cardinal-masculine", "%spellout-cardinal-feminine",
      ])
    for rule in Data.rules {
      var depth = 0
      for token in rule.tokens {
        switch token {
        case .optionalOpen: depth += 1
        case .optionalClose: depth -= 1
        case .literal(let text):
          #expect(text.isEmpty == false)
          #expect(
            text.rangeOfCharacter(from: CharacterSet(charactersIn: "<>=[]$\u{00AD}")) == nil,
            "\(rule.ruleset) \(rule.selector): substitution syntax leaked into a literal")
        case .quotientRule(let name), .remainderRule(let name), .redirect(let name):
          #expect(rulesets.contains(name), "\(rule.ruleset) \(rule.selector) points at \(name)")
        default: break
        }
        #expect(depth >= 0 && depth <= 1)
      }
      #expect(depth == 0, "\(rule.ruleset) \(rule.selector): unbalanced optional brackets")
    }
  }

  @Test("each CLDR tens rule ends in the tens word the NeMo data gives for that value")
  func tensRulesAgreeWithTensAtoms() {
    let expected: [(selector: String, word: String)] = [
      ("20", "zwanzig"), ("30", "dreißig"), ("40", "vierzig"), ("50", "fünfzig"),
      ("60", "sechzig"), ("70", "siebzig"), ("80", "achtzig"), ("90", "neunzig"),
    ]
    for item in expected {
      let rule = Data.rules.first {
        $0.ruleset == "%spellout-numbering" && $0.selector == item.selector
      }
      guard case .literal(let last)? = rule?.tokens.last else {
        Issue.record("rule \(item.selector) does not end in a literal")
        continue
      }
      #expect(last.unicodeScalars.elementsEqual(item.word.unicodeScalars), "\(item.selector)")
    }
  }

  @Test("the bounded ordinal extraction carries independently known forms and provenance")
  func ordinalExtraction() {
    let known: [(spoken: String, value: Int)] = [
      ("erste", 1), ("zweite", 2), ("dritte", 3), ("vierte", 4), ("fünfte", 5), ("sechste", 6),
      ("siebte", 7), ("achte", 8),
    ]
    for item in known {
      let matches = Data.ordinalAtoms.filter {
        $0.spoken.unicodeScalars.elementsEqual(item.spoken.unicodeScalars)
      }
      #expect(matches.count == 1, "\(item.spoken)")
      #expect(matches.first?.value == item.value, "\(item.spoken)")
    }
    #expect(Data.ordinalAtoms.map(\.value) == Array(0...8))
    #expect(Data.ordinalSuffixRules.map(\.fromValue) == [9, 20])
    #expect(Data.ordinalSuffixRules.map(\.suffix) == ["te", "ste"])
    #expect(Data.ordinalSuffixRules.allSatisfy { $0.cardinalRuleset == "%spellout-numbering" })
    #expect(Data.ordinalInflections.map(\.suffix) == ["n", "r"])
    for source in Data.ordinalAtoms.flatMap(\.sources)
      + Data.ordinalSuffixRules.map(\.source) + Data.ordinalInflections.map(\.source)
    {
      let id = source.split(separator: "#", maxSplits: 1).first.map(String.init) ?? source
      #expect(Data.sourceIDs.contains(id), "unknown ordinal source \(source)")
    }
    // The -s and -m inflections are deliberately outside the extraction.
    #expect(Data.ordinalInflections.contains { $0.suffix == "s" || $0.suffix == "m" } == false)
  }

  @Test("the generated reviewed phone refusals carry their identity and exactly four shapes")
  func phonePrefixData() {
    typealias Phone = GermanPhonePrefixData
    #expect(Phone.replacement == "+")
    #expect(Phone.triggerTokens == ["plus"])
    #expect(Phone.refusals.map(\.id) == ["ref-phone-001", "ref-phone-002", "ref-phone-003", "ref-phone-004"])
    #expect(Phone.refusals.map(\.version) == [2, 1, 2, 1])
    #expect(
      Phone.refusals.map(\.contextShape) == [
        "plus_between_operands", "plus_joining_nouns", "plus_before_temperature_or_percent",
        "plus_not_followed_by_digit",
      ])
    for refusal in Phone.refusals {
      #expect(refusal.reviewRef == "refusal-ledger:\(refusal.id):v\(refusal.version)")
      #expect(refusal.contentSHA256.count == 64)
      #expect(refusal.contentSHA256.allSatisfy { "0123456789abcdef".contains($0) })
    }
  }

  @Test("the generated reviewed ordinal refusals carry their identity, kinds and tokens")
  func ordinalRefusalData() {
    typealias Ordinal = GermanOrdinalData
    #expect(Ordinal.writtenSuffix == ".")
    #expect(
      Ordinal.refusals.map(\.id) == [
        "ref-ordinal-001", "ref-ordinal-002", "ref-ordinal-003", "ref-ordinal-004",
        "ref-ordinal-005", "ref-ordinal-006",
      ])
    #expect(Ordinal.refusals.map(\.version) == [1, 1, 2, 2, 1, 2])
    #expect(
      Ordinal.refusals.map(\.contextShape) == [
        "ordinal_adverb", "ordinal_word_in_date_phrase", "ordinal_word_in_fixed_phrase", nil,
        "ordinal_word_without_following_noun", "ordinal_word_in_proper_name",
      ])
    #expect(Ordinal.refusals.filter { $0.kind == .literalPhrase }.map(\.id) == ["ref-ordinal-004"])
    for refusal in Ordinal.refusals {
      #expect(refusal.reviewRef == "refusal-ledger:\(refusal.id):v\(refusal.version)")
      #expect(refusal.contentSHA256.count == 64)
      #expect(refusal.tokens.isEmpty == false)
    }
  }

  @Test("the generated clock syntax data and reviewed refusals carry their identity and provenance")
  func clockIdiomData() {
    typealias Clock = GermanClockIdiomData
    #expect(
      Clock.templates.map(\.id) == [
        "half", "quarterAfter", "quarterTo", "minutesAfter", "minutesBefore", "minutesAfterHalf",
        "minutesBeforeHalf",
      ])
    #expect(
      Clock.templates.map(\.tokens) == [
        ["halb"], ["viertel", "nach"], ["viertel", "vor"], ["nach"], ["vor"], ["nach", "halb"],
        ["vor", "halb"],
      ])
    #expect(Clock.templates.map(\.hourOffset) == [-1, 0, -1, 0, -1, -1, -1])
    #expect(Clock.templates.map(\.minute) == [30, 15, 45, 0, 60, 30, 30])
    #expect(Clock.templates.map(\.inputHourLow) == [2, 1, 2, 1, 2, 2, 2])
    #expect(Clock.templates.map(\.inputHourHigh) == [12, 11, 12, 11, 12, 12, 12])
    #expect(Clock.templates.map(\.minuteSign) == [0, 0, 0, 1, -1, 1, -1])
    #expect(Clock.templates.map(\.minuteMax) == [0, 0, 0, 29, 29, 14, 14])
    #expect(Clock.anchors == ["um", "gegen", "bis", "ab", "für"])
    #expect(Clock.trailingMarker == "uhr")
    #expect(Clock.outputSeparator == ":")
    #expect(Clock.syntaxProvenance.contains("not a reviewed refusal"))
    #expect(Clock.refusals.map(\.id) == ["ref-clock-002", "ref-clock-003", "ref-clock-004"])
    #expect(Clock.refusals.map(\.version) == [3, 2, 2])
    for refusal in Clock.refusals {
      #expect(refusal.reviewRef == "refusal-ledger:\(refusal.id):v\(refusal.version)")
      #expect(refusal.contentSHA256.count == 64)
      #expect(refusal.phrases.isEmpty == false)
    }
  }

  @Test("only the named grammar adapter reads the generated data; the registry lists five languages")
  func notReachableFromRuntime() throws {
    #expect(LanguageRuleRegistry.production.count == 5)
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PostProcessing
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      Issue.record("Sources/ not found beside the tests; the reachability scan could not run")
      return
    }
    let enumerator = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var scanned = 0
    var readers: [String] = []
    for case let file as URL in enumerator where file.pathExtension == "swift" {
      scanned += 1
      let text = try String(contentsOf: file, encoding: .utf8)
      if text.contains("GermanNumberData"), file.lastPathComponent != "GermanNumberData.swift" {
        readers.append(file.path)
      }
    }
    #expect(scanned > 100, "the scan must actually read the source tree (read \(scanned))")
    let names = readers.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
    #expect(
      names == ["LanguageNumberGrammar.swift"],
      "the only reader must be the grammar adapter; found: \(readers)")

    // The reviewed phone refusals have exactly one reader too: the phone-prefix rules adapter.
    var phoneReaders: [String] = []
    let second = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    for case let file as URL in second where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      if text.contains("GermanPhonePrefixData"), file.lastPathComponent != "GermanPhonePrefixData.swift" {
        phoneReaders.append(file.lastPathComponent)
      }
    }
    #expect(
      phoneReaders.sorted() == ["LanguagePhonePrefixRules.swift"],
      "the only reader of the phone data must be the rules adapter; found: \(phoneReaders)")

    // And the reviewed ordinal refusals have exactly one reader: the ordinal rules adapter.
    var ordinalReaders: [String] = []
    let third = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    for case let file as URL in third where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      if text.contains("GermanOrdinalData"), file.lastPathComponent != "GermanOrdinalData.swift" {
        ordinalReaders.append(file.lastPathComponent)
      }
    }
    #expect(
      ordinalReaders.sorted() == ["LanguageOrdinalRules.swift"],
      "the only reader of the ordinal data must be the rules adapter; found: \(ordinalReaders)")

    // And the clock syntax and refusal data have exactly one reader: the clock rules adapter.
    var clockReaders: [String] = []
    let fourth = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    for case let file as URL in fourth where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      if text.contains("GermanClockIdiomData"), file.lastPathComponent != "GermanClockIdiomData.swift" {
        clockReaders.append(file.lastPathComponent)
      }
    }
    #expect(
      clockReaders.sorted() == ["LanguageClockIdiomRules.swift"],
      "the only reader of the clock data must be the rules adapter; found: \(clockReaders)")
  }
}
