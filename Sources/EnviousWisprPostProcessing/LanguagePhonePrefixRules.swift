import Foundation

// MARK: - Reviewed phone-prefix rules as typed data (#1677, PR 2 chunk 4)
//
// The language-specific half of the phone-prefix pass: the trigger word, the replacement, and the
// four REVIEWED refusal shapes, adapted from the generated reviewed-refusal data. This file is the
// only reader of that data. The shared algorithm (`LanguagePhonePrefixPass`) holds no language
// word and no language-code switch.
//
// FAIL CLOSED: a refusal shape the pass does not implement, a missing required shape, a shape
// listed twice, or trigger tokens that disagree make building the rules THROW. The pass then has
// no rules at all; it never runs the remaining ones.

struct LanguagePhonePrefixRules: Sendable, Equatable {

  /// The refusal shapes the pass implements. The raw value is the shape identifier the panel
  /// reviewed; the generated data names shapes by it.
  enum Shape: String, CaseIterable, Sendable {
    case plusBetweenOperands = "plus_between_operands"
    case plusJoiningNouns = "plus_joining_nouns"
    case plusBeforeTemperatureOrPercent = "plus_before_temperature_or_percent"
    case plusNotFollowedByDigit = "plus_not_followed_by_digit"

    /// How the pass executes this shape. A negative structural condition is enforced by the
    /// admission rules themselves; the others are explicit predicates over the candidate.
    enum Enforcement: Sendable, Equatable {
      case explicitPredicate
      case admissionFailure
    }

    /// Exhaustive: a new shape cannot compile until it says how it is enforced.
    var enforcement: Enforcement {
      switch self {
      case .plusBetweenOperands: return .explicitPredicate
      case .plusBeforeTemperatureOrPercent: return .explicitPredicate
      case .plusJoiningNouns: return .admissionFailure
      case .plusNotFollowedByDigit: return .admissionFailure
      }
    }
  }

  /// One reviewed entry, kept with the identity the panel approved.
  struct Refusal: Sendable, Equatable {
    let id: String
    let version: Int
    let contentSHA256: String
    let shape: Shape
  }

  enum BuildError: Error, Equatable {
    case unsupportedShape(String)
    case missingShape(String)
    case duplicateShape(String)
    case noTriggerToken
    case emptyReplacement
    case emptyWordClass(String)
  }

  /// The word classes the gates for numbers written WITHOUT a sign read (admission data, not
  /// reviewed refusals). Every set is folded (lower-case, NFC) and non-empty.
  struct Unsigned: Sendable, Equatable {
    /// Words that may stand between a label and the number ("ist", "lautet", "unter").
    let linkersBefore: Set<String>
    /// Phone words: a number after them is not another field ("Nummer", "Handy").
    let phoneWords: Set<String>
    /// Capitalised words that are not nouns (pronouns, imperatives, sentence starters).
    let nonNounWords: Set<String>
    /// Verbs that make the number an amount ("kostet", "beträgt").
    let valueVerbs: Set<String>
    /// Articles that introduce a possessor after a phone word ("Nummer der Praxis").
    let possessorArticles: Set<String>
    /// Endings that make a word a number field ("Kundennummer").
    let fieldSuffixes: [String]
    /// Explicit local or national qualifiers that withhold the international reading.
    let localQualifiers: Set<String>
    /// The ending of a possessive name ("Lisas Nummer").
    let possessiveSuffix: String

    static func german() throws -> Unsigned {
      typealias U = GermanPhonePrefixData.Unsigned
      return try build(
        linkersBefore: U.linkersBefore, phoneWords: U.phoneWords, nonNounWords: U.nonNounWords,
        valueVerbs: U.valueVerbs, possessorArticles: U.possessorArticles,
        fieldSuffixes: U.fieldSuffixes, localQualifiers: U.localQualifiers,
        possessiveSuffix: U.possessiveSuffix)
    }

    static func build(
      linkersBefore: [String], phoneWords: [String], nonNounWords: [String], valueVerbs: [String],
      possessorArticles: [String], fieldSuffixes: [String], localQualifiers: [String],
      possessiveSuffix: String
    ) throws -> Unsigned {
      func folded(_ words: [String], _ role: String) throws -> [String] {
        let out = words.map(LanguageNumberGrammar.fold).filter { !$0.isEmpty }
        guard !out.isEmpty, out.count == words.count else { throw BuildError.emptyWordClass(role) }
        return out
      }
      let suffix = LanguageNumberGrammar.fold(possessiveSuffix)
      guard !suffix.isEmpty else { throw BuildError.emptyWordClass("possessiveSuffix") }
      return Unsigned(
        linkersBefore: Set(try folded(linkersBefore, "linkersBefore")),
        phoneWords: Set(try folded(phoneWords, "phoneWords")),
        nonNounWords: Set(try folded(nonNounWords, "nonNounWords")),
        valueVerbs: Set(try folded(valueVerbs, "valueVerbs")),
        possessorArticles: Set(try folded(possessorArticles, "possessorArticles")),
        fieldSuffixes: try folded(fieldSuffixes, "fieldSuffixes"),
        localQualifiers: Set(try folded(localQualifiers, "localQualifiers")),
        possessiveSuffix: suffix)
    }
  }

  /// Folded trigger words (lower-case, NFC).
  let triggers: [String]
  /// What replaces the trigger word and its separator.
  let replacement: String
  let refusals: [Refusal]
  let unsigned: Unsigned

  func refusal(for shape: Shape) -> Refusal? {
    refusals.first { $0.shape == shape }
  }

  /// Builds the German rules from the generated reviewed data, or throws.
  static func german() throws -> LanguagePhonePrefixRules {
    typealias Data = GermanPhonePrefixData
    return try build(
      rows: Data.refusals, triggerTokens: Data.triggerTokens, replacement: Data.replacement,
      unsigned: try Unsigned.german())
  }

  /// The adaptation itself, taking its input as values so the failure paths are testable.
  static func build(
    rows: [GermanPhonePrefixData.Refusal], triggerTokens: [String], replacement: String,
    unsigned: Unsigned
  ) throws -> LanguagePhonePrefixRules {
    guard !replacement.isEmpty else { throw BuildError.emptyReplacement }
    let triggers = triggerTokens.map(LanguageNumberGrammar.fold)
    guard !triggers.isEmpty, triggers.allSatisfy({ !$0.isEmpty }) else {
      throw BuildError.noTriggerToken
    }
    var refusals: [Refusal] = []
    for row in rows {
      guard let shape = Shape(rawValue: row.contextShape) else {
        throw BuildError.unsupportedShape(row.contextShape)
      }
      if refusals.contains(where: { $0.shape == shape }) {
        throw BuildError.duplicateShape(row.contextShape)
      }
      refusals.append(
        Refusal(id: row.id, version: row.version, contentSHA256: row.contentSHA256, shape: shape))
    }
    for shape in Shape.allCases where !refusals.contains(where: { $0.shape == shape }) {
      throw BuildError.missingShape(shape.rawValue)
    }
    return LanguagePhonePrefixRules(
      triggers: triggers, replacement: replacement, refusals: refusals, unsigned: unsigned)
  }
}
