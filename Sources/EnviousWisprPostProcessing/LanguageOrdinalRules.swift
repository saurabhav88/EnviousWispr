import Foundation

// MARK: - Reviewed ordinal rules as typed data (#1677, PR 2 chunk 5)
//
// The language-specific half of the ordinal pass: the written suffix and the six REVIEWED refusal
// entries (five context shapes and one literal-phrase entry), adapted from the generated data.
// This file is the only reader of that data. The shared algorithm (`LanguageOrdinalPass`) holds no
// language word and no language-code switch.
//
// THE REVIEWED ENTRIES ARE NOT A CONTEXT LEXICON. They supply ordinal tokens (examples from the
// reviewed rows) and shape identifiers; they do not supply the months, the fixed expressions or the
// names a pass would need to RULE OUT a date, a fixed expression or a name. What the pass cannot
// rule out it must not convert, so three context predicates have three outcomes (applies, does not
// apply, unknown) and `LanguageOrdinalContextEvidence` is the one place an authority for them can
// arrive. German has none today, so `german()` carries `.none` and every ordinal followed by a word
// reports unavailable context instead of a conversion.
//
// FAIL CLOSED: an unsupported shape (the vocabulary shape `ordinal_word_before_fraction_noun` has no
// reviewed entry and is not supported here), a missing shape, a shape listed twice, a missing
// literal-phrase entry or an empty suffix make building the rules THROW. The pass then has no rules
// at all; it never runs the remaining ones.

/// Authorities that let a context predicate answer "does not apply". `nil` means no authority:
/// the predicate is unknown and an ordinal that depends on it is not converted.
struct LanguageOrdinalContextEvidence: Sendable, Equatable {
  /// Folded calendar words (month names). A following word in the set is a date context.
  let calendarWords: Set<String>?
  /// Folded nouns that make a preceding ordinal part of a fixed expression.
  let fixedPhraseNouns: Set<String>?
  let properNameClearance: ProperNameClearance

  enum ProperNameClearance: Sendable, Equatable {
    /// No clearance: a lowercase ordinal may still be a name or title, so the predicate is unknown.
    case none
    /// A lowercase ordinal that is not preceded by a capitalized-name pattern is an adjective
    /// (orthography: names, titles and substantivized ordinals are capitalized). Not enabled for
    /// German; a decision for the panel, with its authority named.
    case lowercaseAdjectiveOrthography
  }

  /// No authority for any predicate: the German data today.
  static let none = LanguageOrdinalContextEvidence(
    calendarWords: nil, fixedPhraseNouns: nil, properNameClearance: .none)
}

struct LanguageOrdinalRules: Sendable, Equatable {

  /// The reviewed context shapes the pass implements. The raw value is the shape identifier the
  /// panel reviewed.
  enum Shape: String, CaseIterable, Sendable {
    case ordinalAdverb = "ordinal_adverb"
    case dateContext = "ordinal_word_in_date_phrase"
    case fixedExpression = "ordinal_word_in_fixed_phrase"
    case withoutFollowingNoun = "ordinal_word_without_following_noun"
    case properName = "ordinal_word_in_proper_name"

    /// How the pass executes this shape. Exhaustive: a new shape cannot compile until it says how
    /// it is enforced, and none of these is a classifier of nouns, months or names.
    enum Enforcement: Sendable, Equatable {
      /// The reviewed tokens are matched explicitly.
      case reviewedTokenMatch
      /// A structural admission test (a capitalized word follows, nothing separates it).
      case structuralAdmission
      /// Answerable only with an authority from `LanguageOrdinalContextEvidence`.
      case authorityDependent
      /// Capitalization withholds conversion; it is not a proper-name classifier.
      case conservativeWithhold
    }

    var enforcement: Enforcement {
      switch self {
      case .ordinalAdverb: return .reviewedTokenMatch
      case .withoutFollowingNoun: return .structuralAdmission
      case .dateContext: return .authorityDependent
      case .fixedExpression: return .authorityDependent
      case .properName: return .conservativeWithhold
      }
    }
  }

  enum Matcher: Sendable, Equatable {
    /// A reviewed context shape with the reviewed tokens (folded single words).
    case contextShape(Shape, tokens: [String])
    /// Reviewed literal phrases (folded word sequences), matched as complete token sequences.
    case literalPhrases([[String]])
  }

  struct Refusal: Sendable, Equatable {
    let id: String
    let version: Int
    let contentSHA256: String
    let matcher: Matcher
  }

  enum BuildError: Error, Equatable {
    case unsupportedShape(String)
    case shapeWithoutEntryKind(String)
    case missingShape(String)
    case duplicateShape(String)
    case missingLiteralPhrases
    case emptyTokens(String)
    case emptySuffix
    case unknownKind(String)
  }

  let writtenSuffix: String
  let refusals: [Refusal]
  let evidence: LanguageOrdinalContextEvidence

  func tokens(for shape: Shape) -> [String]? {
    for refusal in refusals {
      if case .contextShape(let candidate, let tokens) = refusal.matcher, candidate == shape {
        return tokens
      }
    }
    return nil
  }

  var literalPhrases: [[String]] {
    refusals.flatMap { refusal -> [[String]] in
      if case .literalPhrases(let phrases) = refusal.matcher { return phrases }
      return []
    }
  }

  func refusalID(for shape: Shape) -> String? {
    for refusal in refusals {
      if case .contextShape(let candidate, _) = refusal.matcher, candidate == shape {
        return refusal.id
      }
    }
    return nil
  }

  /// Builds the German rules from the generated reviewed data, or throws. No context authority.
  static func german() throws -> LanguageOrdinalRules {
    typealias Data = GermanOrdinalData
    return try build(
      rows: Data.refusals, writtenSuffix: Data.writtenSuffix, evidence: .none)
  }

  /// The adaptation itself, taking its input as values so the failure paths are testable.
  static func build(
    rows: [GermanOrdinalData.Refusal], writtenSuffix: String,
    evidence: LanguageOrdinalContextEvidence
  ) throws -> LanguageOrdinalRules {
    guard !writtenSuffix.isEmpty else { throw BuildError.emptySuffix }
    var refusals: [Refusal] = []
    var shapes = Set<Shape>()
    for row in rows {
      guard !row.tokens.isEmpty, row.tokens.allSatisfy({ !$0.isEmpty }) else {
        throw BuildError.emptyTokens(row.id)
      }
      let folded = row.tokens.map(LanguageNumberGrammar.fold)
      switch row.kind {
      case .contextShape:
        guard let name = row.contextShape else { throw BuildError.shapeWithoutEntryKind(row.id) }
        guard let shape = Shape(rawValue: name) else { throw BuildError.unsupportedShape(name) }
        guard shapes.insert(shape).inserted else { throw BuildError.duplicateShape(name) }
        refusals.append(
          Refusal(
            id: row.id, version: row.version, contentSHA256: row.contentSHA256,
            matcher: .contextShape(shape, tokens: folded)))
      case .literalPhrase:
        guard row.contextShape == nil else { throw BuildError.unknownKind(row.id) }
        let phrases = folded.map { $0.split(separator: " ").map(String.init) }
        guard phrases.allSatisfy({ !$0.isEmpty }) else { throw BuildError.emptyTokens(row.id) }
        refusals.append(
          Refusal(
            id: row.id, version: row.version, contentSHA256: row.contentSHA256,
            matcher: .literalPhrases(phrases)))
      }
    }
    for shape in Shape.allCases where !shapes.contains(shape) {
      throw BuildError.missingShape(shape.rawValue)
    }
    guard
      refusals.contains(where: {
        if case .literalPhrases = $0.matcher { return true } else { return false }
      })
    else { throw BuildError.missingLiteralPhrases }
    return LanguageOrdinalRules(
      writtenSuffix: writtenSuffix, refusals: refusals, evidence: evidence)
  }
}
