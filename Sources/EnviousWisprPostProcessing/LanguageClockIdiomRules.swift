import Foundation

// MARK: - Clock-idiom syntax and reviewed refusals as typed data (#1677, PR 2 chunk 6)
//
// The language-specific half of the clock-idiom pass: the idiom templates, the anchors that may
// precede one (word sequences: German `um`, Dutch `het is nu`), the trailing clock marker, the
// output separator, the language's refusal policy and REVIEWED refusal entries (all complete
// literal phrases; German has three, Dutch declares none), and whether a capitalized word after a
// minute idiom marks a noun (German only). Adapted from the generated data; this file is the only
// reader of it. The shared algorithm (`LanguageClockIdiomPass`) holds no language word.
//
// TWO KINDS OF DATA, NEVER MIXED UP:
//  - SYNTAX data (templates, anchors, marker, separator) is implementation admission data grounded
//    in the approved scope. It is not a reviewed refusal and is not a general German clock grammar.
//  - REFUSAL data is the reviewed literal-phrase entries only: duration, fraction and `halb voll`
//    phrases. The pending noon/midnight entry and the pending regional forms are not here.
//
// A template admits only the input hours whose written result needs no clock-face choice: `halb
// eins` would need 0:30 or 12:30 and `viertel nach zwölf` would need 12:15 or 0:15, so those hours
// are outside the template's range and the pass withholds them as a STRUCTURAL exclusion.
//
// FAIL CLOSED: a template whose output hour could leave 1 to 12, a duplicate or empty template,
// anchor or phrase, an empty marker or separator, or (for a language that requires reviewed
// refusals) a refusal set that is not exactly its required entries make building the rules THROW.
// The pass then has no rules at all.

struct LanguageClockIdiomRules: Sendable, Equatable {

  struct Template: Sendable, Equatable {
    let id: String
    /// Folded spoken tokens before the hour word.
    let tokens: [String]
    let hourOffset: Int
    let minute: Int
    /// The input hours this template converts; the others need a clock-face choice.
    let inputHours: ClosedRange<Int>
    /// A spoken minute before the tokens (`5 nach`, `10 vor halb`): nil for a fixed idiom. The
    /// written minute is `minute + sign x spoken minute`, for a spoken minute in `minutes`.
    let minuteSlot: (sign: Int, minutes: ClosedRange<Int>)?

    static func == (lhs: Template, rhs: Template) -> Bool {
      lhs.id == rhs.id && lhs.tokens == rhs.tokens && lhs.hourOffset == rhs.hourOffset
        && lhs.minute == rhs.minute && lhs.inputHours == rhs.inputHours
        && lhs.minuteSlot?.sign == rhs.minuteSlot?.sign
        && lhs.minuteSlot?.minutes == rhs.minuteSlot?.minutes
    }
  }

  /// The kinds of reviewed refusal the pass executes. Exhaustive.
  enum RefusalKind: Sendable, Equatable, CaseIterable {
    case literalPhrase

    enum Enforcement: Sendable, Equatable {
      /// The reviewed phrases are matched as complete token sequences, nothing broader.
      case completeLiteralPhraseMatch
    }

    var enforcement: Enforcement {
      switch self {
      case .literalPhrase: return .completeLiteralPhraseMatch
      }
    }
  }

  struct Refusal: Sendable, Equatable {
    let id: String
    let version: Int
    let contentSHA256: String
    let kind: RefusalKind
    /// Folded word sequences.
    let phrases: [[String]]
  }

  enum BuildError: Error, Equatable {
    case noTemplates
    case duplicateTemplate(String)
    case invalidTemplate(String)
    case noAnchors
    case invalidAnchor(String)
    case emptyMarker
    case invalidSeparator
    case noRefusals
    case refusalsNotRequiredSet
    case refusalsWithoutPolicy
    case emptyPhrase(String)
    case duplicatePhrase(String)
  }

  let templates: [Template]
  /// Folded anchor word sequences; a one-word anchor may also be glued to `halb`/`half`.
  let anchors: Set<[String]>
  /// Folded trailing clock marker (`uhr`).
  let trailingMarker: String
  let outputSeparator: String
  let refusals: [Refusal]
  /// The language's reviewed literal refusals are part of its contract: the pass refuses to run
  /// without them (German). A language without (Dutch) runs with an empty set.
  let requiresReviewedRefusals: Bool
  /// A capitalized word after a minute idiom marks a noun phrase (German capitalizes nouns).
  let capitalizedNounGate: Bool

  var phrases: [(phrase: [String], entry: String)] {
    refusals.flatMap { refusal in refusal.phrases.map { ($0, refusal.id) } }
  }

  /// The languages whose generated data declares clock idioms.
  static var languages: Set<String> { Set(ClockIdiomData.languages.keys) }

  /// The rules of one language from the generated data: nil when the language declares no clock
  /// idioms, a thrown error when its data is unusable.
  static func forLanguage(_ code: String) throws -> LanguageClockIdiomRules? {
    guard let data = ClockIdiomData.languages[code] else { return nil }
    return try build(
      templates: data.templates, anchors: data.anchors, trailingMarker: data.trailingMarker,
      outputSeparator: data.outputSeparator, refusals: data.refusals,
      requiresReviewedRefusals: data.requiresReviewedRefusals,
      requiredEntries: data.requiredEntries, capitalizedNounGate: data.capitalizedNounGate)
  }

  /// The adaptation itself, taking its input as values so the failure paths are testable.
  static func build(
    templates: [ClockIdiomData.Template], anchors: [[String]], trailingMarker: String,
    outputSeparator: String, refusals: [ClockIdiomData.Refusal], requiresReviewedRefusals: Bool,
    requiredEntries: [String], capitalizedNounGate: Bool
  ) throws -> LanguageClockIdiomRules {
    guard !templates.isEmpty else { throw BuildError.noTemplates }
    var built: [Template] = []
    for template in templates {
      guard !built.contains(where: { $0.id == template.id }) else {
        throw BuildError.duplicateTemplate(template.id)
      }
      let tokens = template.tokens.map(LanguageNumberGrammar.fold)
      let low = template.inputHourLow
      let high = template.inputHourHigh
      guard !template.id.isEmpty, !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }),
        (1...12).contains(low), (1...12).contains(high), low <= high,
        (1...12).contains(low + template.hourOffset), (1...12).contains(high + template.hourOffset),
        template.minuteSign == 0 || template.minuteMax >= 1
      else { throw BuildError.invalidTemplate(template.id) }
      let slot: (sign: Int, minutes: ClosedRange<Int>)?
      switch template.minuteSign {
      case 0:
        guard (0...59).contains(template.minute) else { throw BuildError.invalidTemplate(template.id) }
        slot = nil
      case 1, -1:
        let sign = template.minuteSign
        guard (0...59).contains(template.minute + sign),
          (0...59).contains(template.minute + sign * template.minuteMax)
        else { throw BuildError.invalidTemplate(template.id) }
        slot = (sign, 1...template.minuteMax)
      default: throw BuildError.invalidTemplate(template.id)
      }
      built.append(
        Template(
          id: template.id, tokens: tokens, hourOffset: template.hourOffset,
          minute: template.minute, inputHours: low...high, minuteSlot: slot))
    }
    guard !anchors.isEmpty else { throw BuildError.noAnchors }
    let foldedAnchors = anchors.map { $0.map(LanguageNumberGrammar.fold) }
    guard
      foldedAnchors.allSatisfy({ sequence in
        !sequence.isEmpty
          && sequence.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
      }), Set(foldedAnchors).count == foldedAnchors.count
    else {
      throw BuildError.invalidAnchor(anchors.map { $0.joined(separator: " ") }.joined(separator: ","))
    }
    let marker = LanguageNumberGrammar.fold(trailingMarker)
    guard !marker.isEmpty else { throw BuildError.emptyMarker }
    guard outputSeparator.unicodeScalars.count == 1 else { throw BuildError.invalidSeparator }

    if requiresReviewedRefusals {
      guard !refusals.isEmpty else { throw BuildError.noRefusals }
    } else {
      guard refusals.isEmpty, requiredEntries.isEmpty else {
        throw BuildError.refusalsWithoutPolicy
      }
    }

    var seen = Set<[String]>()
    var rows: [Refusal] = []
    for row in refusals {
      let phrases = row.phrases.map {
        LanguageNumberGrammar.fold($0).split(separator: " ").map(String.init)
      }
      guard !phrases.isEmpty, phrases.allSatisfy({ !$0.isEmpty }) else {
        throw BuildError.emptyPhrase(row.id)
      }
      for phrase in phrases where !seen.insert(phrase).inserted {
        throw BuildError.duplicatePhrase(phrase.joined(separator: " "))
      }
      rows.append(
        Refusal(
          id: row.id, version: row.version, contentSHA256: row.contentSHA256,
          kind: .literalPhrase, phrases: phrases))
    }
    // A language that requires reviewed refusals carries exactly its required entries.
    if requiresReviewedRefusals {
      guard Set(rows.map(\.id)) == Set(requiredEntries), rows.count == requiredEntries.count else {
        throw BuildError.refusalsNotRequiredSet
      }
    }
    return LanguageClockIdiomRules(
      templates: built, anchors: Set(foldedAnchors), trailingMarker: marker,
      outputSeparator: outputSeparator, refusals: rows,
      requiresReviewedRefusals: requiresReviewedRefusals,
      capitalizedNounGate: capitalizedNounGate)
  }
}
