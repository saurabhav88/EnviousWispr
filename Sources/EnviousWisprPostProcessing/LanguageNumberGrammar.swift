import Foundation

// MARK: - The number grammar a language pass reads (#1677, PR 2 chunk 3)
//
// An immutable VALUE built once from generated lexical data (the pinned CLDR and NeMo files the
// offline generator compiles). Shared parsing code takes this value as a parameter: it never
// switches on a language code and never reads a registry. This file is the ONLY reader of the
// generated data; a freeze test pins that.
//
// WHAT THE GRAMMAR ADMITS (supported syntax limits for this slice, not performance promises):
//  - cardinals 0 through 99: the generated unit, teen and tens atoms, plus the source-defined
//    unit-before-tens composition (`<unit><connector><tens>`), glued or split at its two joints;
//  - ordinals 1 through 31 in the base, `-n` and `-r` forms, composed from the source's irregular
//    forms below 9 and its regular suffix rules; the `-s` and `-m` forms are NOT admitted;
//  - clock hours 1 through 12, a range check on a single cardinal word or on one or two ASCII
//    digits (`8`, `08`); digits are read only as a clock hour.
// Telephone numbers are not grammar: `LanguagePhoneMetadata` validates them.
// The Dutch grammar (`dutch()`) is CARDINAL-ONLY: 0 through 99 from the generated Dutch lexicon,
// a compound being `<prefix><tens>` where the prefix carries its own joint (`vijfen`, `tweeën`), so
// its connector is empty; it admits no ordinal. Its article forms (`een`) are BOTH standalone (a clock
// hour, `kwart over een`) and non-standalone (alone they are not evidence of a longer number).
// Anything else (negative, decimal, fraction, scale words, values above 99, article forms such as
// bare `ein`) is outside the grammar, and the parser refuses it as a whole.
//
// Every composition constraint (connector, order, which unit form joins a compound) is DERIVED
// from the generated rules and atom provenance, never from a second hand-written word table. If
// the data stops having the shape this adapter relies on, building the grammar throws and no
// pass gets a grammar at all.

struct LanguageNumberGrammar: Sendable, Equatable {

  /// The supported syntax limits.
  struct Limits: Sendable, Equatable {
    let cardinalMax: Int
    let ordinalRange: ClosedRange<Int>
    let clockHourRange: ClosedRange<Int>
    let candidateUTF16Max: Int
    let candidateTokenMax: Int

    static let supported = Limits(
      cardinalMax: 99, ordinalRange: 1...31, clockHourRange: 1...12, candidateUTF16Max: 128,
      candidateTokenMax: 8)
  }

  /// One admitted ordinal spelling: its value and, for a compound, the scalar offsets of the two
  /// joints where a spaced tokenization may split it.
  struct OrdinalForm: Sendable, Equatable {
    let value: Int
    let joints: [Int]
  }

  let limits: Limits
  /// Folded spoken form to value, for the forms that may stand alone (never `ein` or `eine`).
  let standalone: [String: Int]
  /// Spoken forms that are number words only inside a licensed compound (the article forms).
  let nonStandalone: Set<String>
  /// Folded unit forms that may precede the connector, to their value 1 through 9.
  let compoundUnits: [String: Int]
  let connector: String
  /// Folded tens forms to their value 20 through 90.
  let tens: [String: Int]
  /// Folded ordinal spelling to its form.
  let ordinalForms: [String: OrdinalForm]

  enum BuildError: Error, Equatable {
    case missingData(String)
    case inconsistentData(String)
  }

  /// The folding every lookup uses: lower-case, precomposed. The returned text is only a lookup
  /// key; ranges always stay on the original text.
  static func fold(_ text: String) -> String {
    text.lowercased().precomposedStringWithCanonicalMapping
  }
}

extension LanguageNumberGrammar {

  /// The number grammar of one language, or nil when the language has none. Throws when its
  /// generated data has not the shape the adapter relies on.
  static func forLanguage(_ code: String) throws -> LanguageNumberGrammar? {
    switch code {
    case "de": return try german()
    case "nl": return try dutch()
    default: return nil
    }
  }

  /// Builds the Dutch cardinal-only grammar from the generated lexicon, or throws.
  static func dutch() throws -> LanguageNumberGrammar {
    typealias Data = DutchNumberData
    var standalone: [String: Int] = [:]
    for word in Data.standalone {
      let key = fold(word.spoken)
      guard !key.isEmpty, standalone[key] == nil, (0...99).contains(word.value) else {
        throw BuildError.inconsistentData("standalone \(word.spoken)")
      }
      standalone[key] = word.value
    }
    var tens: [String: Int] = [:]
    for word in Data.tens {
      let key = fold(word.spoken)
      guard (20...90).contains(word.value), word.value % 10 == 0, tens[key] == nil,
        standalone[key] == word.value
      else { throw BuildError.inconsistentData("tens \(word.spoken)") }
      tens[key] = word.value
    }
    var prefixes: [String: Int] = [:]
    for word in Data.compoundPrefixes {
      let key = fold(word.spoken)
      guard (1...9).contains(word.value), prefixes[key] == nil, !key.isEmpty else {
        throw BuildError.inconsistentData("compound prefix \(word.spoken)")
      }
      prefixes[key] = word.value
    }
    let articles = Set(Data.articleForms.map(fold))
    guard articles.allSatisfy({ standalone[$0] != nil }) else {
      throw BuildError.inconsistentData("article form outside the standalone words")
    }
    guard Set(standalone.values) == Set(0...19).union(Set(tens.values)),
      Set(tens.values) == Set(stride(from: 20, through: 90, by: 10)),
      Set(prefixes.values) == Set(1...9), prefixes.count == 9
    else { throw BuildError.missingData("Dutch cardinal lexicon") }
    return LanguageNumberGrammar(
      limits: .supported, standalone: standalone, nonStandalone: articles, compoundUnits: prefixes,
      connector: "", tens: tens, ordinalForms: [:])
  }

  /// Builds the German grammar from the generated data, or throws if the data has not the shape
  /// this adapter relies on.
  static func german() throws -> LanguageNumberGrammar {
    typealias Data = GermanNumberData

    // 1. The unit-before-tens composition, read from the tens rules. One ruleset must hold all
    //    eight, each of the form `[<remainder ruleset><connector>]<tens word>`.
    var baseRuleset: String?
    var remainderRuleset: String?
    var connector: String?
    var tensRuleValues = Set<Int>()
    var tensWords: [Int: String] = [:]
    for rule in Data.rules {
      guard let value = Int(rule.selector), (20...90).contains(value), value % 10 == 0 else {
        continue
      }
      guard rule.tokens.count == 5,
        case .optionalOpen = rule.tokens[0],
        case .remainderRule(let remainder) = rule.tokens[1],
        case .literal(let joint) = rule.tokens[2],
        case .optionalClose = rule.tokens[3],
        case .literal(let word) = rule.tokens[4]
      else {
        throw BuildError.inconsistentData("tens rule \(rule.selector) has an unexpected shape")
      }
      if baseRuleset == nil { baseRuleset = rule.ruleset }
      if remainderRuleset == nil { remainderRuleset = remainder }
      if connector == nil { connector = joint }
      guard baseRuleset == rule.ruleset, remainderRuleset == remainder, connector == joint else {
        throw BuildError.inconsistentData("tens rules disagree on ruleset, remainder or connector")
      }
      tensRuleValues.insert(value)
      tensWords[value] = fold(word)
    }
    guard let base = baseRuleset, let remainderName = remainderRuleset,
      let rawConnector = connector,
      tensRuleValues == Set(stride(from: 20, through: 90, by: 10))
    else { throw BuildError.missingData("the eight tens rules") }
    let joint = fold(rawConnector)

    // 2. The tens atoms must agree with the tens words the rules end in.
    var tensForms: [String: Int] = [:]
    for atom in Data.atoms where atom.role == .tens {
      guard tensWords[atom.value] == fold(atom.spoken) else {
        throw BuildError.inconsistentData("tens atom \(atom.spoken) disagrees with its rule")
      }
      tensForms[fold(atom.spoken)] = atom.value
    }
    guard tensForms.count == 8 else { throw BuildError.missingData("eight tens atoms") }

    // 3. Which atoms may stand alone. For a value the base ruleset spells, only the base spelling
    //    stands alone (so `eins`, not the article forms `ein` and `eine`); a value only NeMo
    //    spells keeps its single spelling.
    let baseSuffix = "#" + base
    var atomsByValue: [Int: [GermanNumberData.Atom]] = [:]
    for atom in Data.atoms { atomsByValue[atom.value, default: []].append(atom) }
    var standalone: [String: Int] = [:]
    var chosenForValue: [Int: String] = [:]
    var nonStandalone = Set<String>()
    for (value, atoms) in atomsByValue {
      let fromBase = atoms.filter { $0.sources.contains { $0.hasSuffix(baseSuffix) } }
      let chosen = fromBase.isEmpty ? atoms : fromBase
      guard chosen.count == 1, let atom = chosen.first else {
        throw BuildError.inconsistentData("value \(value) has \(chosen.count) standalone spellings")
      }
      let form = fold(atom.spoken)
      standalone[form] = value
      chosenForValue[value] = form
      for other in atoms where fold(other.spoken) != form {
        nonStandalone.insert(fold(other.spoken))
      }
    }
    guard Set(chosenForValue.keys).isSuperset(of: Set(0...19)) else {
      throw BuildError.missingData("atoms for 0 through 19")
    }

    // 4. The unit form that joins a compound: the spelling of the remainder ruleset, following its
    //    own redirect to the base ruleset for the values it does not spell itself.
    var redirectFrom = Int.max
    var redirectTarget: String?
    for rule in Data.rules where rule.ruleset == remainderName && rule.tokens.count == 1 {
      if case .redirect(let target) = rule.tokens[0], let from = Int(rule.selector) {
        redirectFrom = min(redirectFrom, from)
        redirectTarget = target
      }
    }
    var compoundUnits: [String: Int] = [:]
    for value in 1...9 {
      let units = (atomsByValue[value] ?? []).filter { $0.role == .unit }
      var matches = units.filter { $0.sources.contains { $0.hasSuffix("#" + remainderName) } }
      if matches.isEmpty, value >= redirectFrom, let target = redirectTarget {
        matches = units.filter { $0.sources.contains { $0.hasSuffix("#" + target) } }
      }
      guard matches.count == 1, let atom = matches.first else {
        throw BuildError.inconsistentData("unit \(value) has \(matches.count) compound spellings")
      }
      compoundUnits[fold(atom.spoken)] = value
    }

    // 5. Ordinals, composed from the irregular forms and the suffix rules.
    let ordinalForms = try buildOrdinals(
      base: base, standalone: chosenForValue, compoundUnits: compoundUnits, joint: joint,
      tensWords: tensWords, limits: Limits.supported)

    return LanguageNumberGrammar(
      limits: .supported, standalone: standalone, nonStandalone: nonStandalone,
      compoundUnits: compoundUnits, connector: joint, tens: tensForms, ordinalForms: ordinalForms)
  }

  private static func buildOrdinals(
    base: String, standalone: [Int: String], compoundUnits: [String: Int], joint: String,
    tensWords: [Int: String], limits: Limits
  ) throws -> [String: OrdinalForm] {
    typealias Data = GermanNumberData
    guard !Data.ordinalAtoms.isEmpty, !Data.ordinalSuffixRules.isEmpty,
      !Data.ordinalInflections.isEmpty
    else { throw BuildError.missingData("ordinal data") }

    var irregular: [Int: String] = [:]
    for atom in Data.ordinalAtoms { irregular[atom.value] = fold(atom.spoken) }
    guard irregular.count == Data.ordinalAtoms.count,
      Set(irregular.keys) == Set(0..<Data.ordinalAtoms.count)
    else { throw BuildError.inconsistentData("irregular ordinals are not 0 through n") }
    let irregularBelow = irregular.count

    let rules = Data.ordinalSuffixRules.sorted { $0.fromValue < $1.fromValue }
    guard rules.first?.fromValue == irregularBelow, rules.allSatisfy({ $0.cardinalRuleset == base })
    else {
      throw BuildError.inconsistentData("ordinal suffix rules do not follow the irregular forms")
    }

    let ordinalBase = Data.ordinalInflections[0].baseRuleset
    guard Data.ordinalInflections.allSatisfy({ $0.baseRuleset == ordinalBase }),
      Data.ordinalSuffixRules.allSatisfy({ $0.source.hasSuffix("#" + ordinalBase) }),
      Data.ordinalAtoms.allSatisfy({ $0.sources.allSatisfy { $0.hasSuffix("#" + ordinalBase) } })
    else { throw BuildError.inconsistentData("ordinal data names more than one base ruleset") }
    var inflections = [""]
    for inflection in Data.ordinalInflections { inflections.append(fold(inflection.suffix)) }

    let unitForm = Dictionary(uniqueKeysWithValues: compoundUnits.map { ($0.value, $0.key) })
    func cardinalSpelling(_ value: Int) -> (text: String, joints: [Int])? {
      if let form = standalone[value] { return (form, []) }
      let unit = value % 10
      let tens = value - unit
      guard unit > 0, let tensWord = tensWords[tens], let unitWord = unitForm[unit] else {
        return nil
      }
      let first = unitWord.unicodeScalars.count
      return (unitWord + joint + tensWord, [first, first + joint.unicodeScalars.count])
    }

    var forms: [String: OrdinalForm] = [:]
    for value in limits.ordinalRange {
      let stem: String
      var joints: [Int] = []
      if let word = irregular[value] {
        stem = word
      } else {
        guard let rule = rules.last(where: { $0.fromValue <= value }),
          let spelling = cardinalSpelling(value)
        else { throw BuildError.inconsistentData("no ordinal spelling for \(value)") }
        stem = spelling.text + fold(rule.suffix)
        joints = spelling.joints
      }
      for suffix in inflections {
        let spelled = stem + suffix
        if let existing = forms[spelled], existing.value != value {
          throw BuildError.inconsistentData("\(spelled) spells \(existing.value) and \(value)")
        }
        forms[spelled] = OrdinalForm(value: value, joints: joints)
      }
    }
    return forms
  }
}
