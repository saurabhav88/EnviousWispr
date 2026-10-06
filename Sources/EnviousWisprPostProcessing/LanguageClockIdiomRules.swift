import Foundation

// MARK: - Clock-idiom syntax and reviewed refusals as typed data (#1677, PR 2 chunk 6)
//
// The language-specific half of the clock-idiom pass: two idiom templates, the anchors that may
// precede one, the trailing clock marker, the output separator, and the three REVIEWED refusal
// entries (all complete literal phrases). Adapted from the generated data; this file is the only
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
// anchor or phrase, an empty marker or separator, or no refusal entry make building the rules
// THROW. The pass then has no rules at all.

struct LanguageClockIdiomRules: Sendable, Equatable {

  struct Template: Sendable, Equatable {
    let id: String
    /// Folded spoken tokens before the hour word.
    let tokens: [String]
    let hourOffset: Int
    let minute: Int
    /// The input hours this template converts; the others need a clock-face choice.
    let inputHours: ClosedRange<Int>
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
    case emptyPhrase(String)
    case duplicatePhrase(String)
  }

  let templates: [Template]
  /// Folded anchor words.
  let anchors: Set<String>
  /// Folded trailing clock marker (`uhr`).
  let trailingMarker: String
  let outputSeparator: String
  let refusals: [Refusal]

  var phrases: [(phrase: [String], entry: String)] {
    refusals.flatMap { refusal in refusal.phrases.map { ($0, refusal.id) } }
  }

  /// Builds the German rules from the generated data, or throws.
  static func german() throws -> LanguageClockIdiomRules {
    typealias Data = GermanClockIdiomData
    return try build(
      templates: Data.templates, anchors: Data.anchors, trailingMarker: Data.trailingMarker,
      outputSeparator: Data.outputSeparator, refusals: Data.refusals)
  }

  /// The adaptation itself, taking its input as values so the failure paths are testable.
  static func build(
    templates: [GermanClockIdiomData.Template], anchors: [String], trailingMarker: String,
    outputSeparator: String, refusals: [GermanClockIdiomData.Refusal]
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
        (0...59).contains(template.minute)
      else { throw BuildError.invalidTemplate(template.id) }
      built.append(
        Template(
          id: template.id, tokens: tokens, hourOffset: template.hourOffset,
          minute: template.minute, inputHours: low...high))
    }
    guard !anchors.isEmpty else { throw BuildError.noAnchors }
    let foldedAnchors = anchors.map(LanguageNumberGrammar.fold)
    guard foldedAnchors.allSatisfy({ !$0.isEmpty }), Set(foldedAnchors).count == foldedAnchors.count
    else { throw BuildError.invalidAnchor(anchors.joined(separator: ",")) }
    let marker = LanguageNumberGrammar.fold(trailingMarker)
    guard !marker.isEmpty else { throw BuildError.emptyMarker }
    guard outputSeparator.unicodeScalars.count == 1 else { throw BuildError.invalidSeparator }

    guard !refusals.isEmpty else { throw BuildError.noRefusals }
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
    return LanguageClockIdiomRules(
      templates: built, anchors: Set(foldedAnchors), trailingMarker: marker,
      outputSeparator: outputSeparator, refusals: rows)
  }
}
