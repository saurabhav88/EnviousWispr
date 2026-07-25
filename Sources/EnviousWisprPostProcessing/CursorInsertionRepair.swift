import Foundation

/// Deterministic repair of an outgoing dictation against the text either side of
/// the caret: leading space, leading case, and a redundant trailing full stop.
///
/// Pure and self-contained. It reads no accessibility state, no settings, no
/// delivery state, and no mutable vocabulary owner — protected spellings arrive
/// as an explicit argument, because `CustomWordsManager.correctorVocabulary` is
/// mutable mid-session and an in-flight repair must not change under it.
///
/// This type produces CANDIDATES only. It never decides which delivery route
/// uses them; plan §6 is the sole payload-selection authority.
///
/// Issue #1785.
public enum CursorInsertionRepair {

  // MARK: - Inputs

  /// The document text either side of the caret, as read at insertion time.
  ///
  /// Bounded windows rather than whole-field text: the decision only needs the
  /// nearest real character on each side. One character is NOT enough — `"home. "`
  /// and `"home, "` both present a space and demand opposite outcomes — so the
  /// left side is walked back over spaces and tabs to the last real character.
  public struct CaretText: Equatable, Sendable {
    /// Text immediately before the caret. Only its tail matters.
    public let left: String
    /// Text immediately after the caret. Only its head matters.
    public let right: String

    public init(left: String, right: String) {
      self.left = left
      self.right = right
    }
  }

  // MARK: - Outputs

  /// Why the leading capital was left alone.
  public enum CaseSkipReason: String, Equatable, Sendable {
    case alreadyLower
    case protectedWord
    case mixedCaseOrAcronym
    case containsDigit
    case pronounI
    case alwaysCapitalized
    case notKnownLowercase
    case lexiconUnavailable
  }

  /// Why the position itself meant no case change was appropriate.
  public enum CaseKeptReason: String, Equatable, Sendable {
    case lineStart
    case nothingLeft
    case afterOpener
    case afterTerminator
    case other
  }

  /// Why no trailing space was added.
  public enum TrailingSkipReason: String, Equatable, Sendable {
    case rightIsSpace
    case rightIsPunctuation
  }

  /// One decision the repair took, for tests and privacy-safe telemetry.
  /// Carries no user text — only the shape of what was decided.
  public enum AppliedRule: Equatable, Sendable {
    /// The caret sits between two word characters, so no contextual candidate
    /// was offered at all. Distinct from an empty rule list, which means the
    /// caret context could not be READ — one is a deliberate refusal, the other
    /// an accessibility failure, and the field needs to tell them apart.
    case refusedInsideWord
    case leadingSpace
    case lowercasedFirst
    case caseSkipped(CaseSkipReason)
    case caseKept(CaseKeptReason)
    case droppedTerminalPeriod
    case trailingSpace
    case trailingSpaceSkipped(TrailingSkipReason)
  }

  /// Both payloads, so the caller never has to reconstruct either one.
  ///
  /// `legacyText` is always present and always exactly today's output, so a
  /// caller that cannot use the candidate has the correct fallback in hand
  /// rather than re-deriving it — which is how a second trailing-space authority
  /// would get created.
  public struct PreparedPayloads: Equatable, Sendable {
    /// Today's behaviour, including its trailing space. Never `nil`.
    public let legacyText: String
    /// The contextual candidate, or `nil` when no SAFE candidate can be
    /// produced — either the caret context was unreadable, or the caret sits
    /// inside a word and repairing there would invent a broken sentence.
    /// `candidateRules` distinguishes the two.
    public let repairedText: String?
    /// What the repair proposes, regardless of which payload is ultimately used.
    public let candidateRules: [AppliedRule]

    public init(legacyText: String, repairedText: String?, candidateRules: [AppliedRule]) {
      self.legacyText = legacyText
      self.repairedText = repairedText
      self.candidateRules = candidateRules
    }
  }

  // MARK: - Character classes

  /// Ends a sentence. After one of these the following word keeps its capital.
  static let terminators: Set<Character> = [".", "!", "?"]
  /// Mid-sentence punctuation: we are still inside a sentence after these.
  static let continuers: Set<Character> = [",", ";", ":", "-", "\u{2014}"]
  /// Opening brackets and quotes: no leading space, and no case change.
  static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}"]
  /// Right-hand characters that make a trailing space wrong.
  static let trailingSuppressors: Set<Character> = [
    ".", "!", "?", ",", ";", ":", ")", "]", "}",
  ]
  /// Always capitalised regardless of position. Closed set, so it needs no lexicon.
  static let alwaysCapitalized: Set<String> = [
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
  ]

  // MARK: - Entry point

  /// Prepare both payloads for `text` at the caret described by `context`.
  ///
  /// - Parameters:
  ///   - text: the outgoing dictation, already fully processed.
  ///   - context: the document text either side of the caret, or `nil` when it
  ///     could not be read. `nil` yields today's payload only — NOT the raw input.
  ///   - protectedWords: canonical spellings that must never be recased.
  public static func repair(
    text: String,
    context: CaretText?,
    protectedWords: Set<String>
  ) -> PreparedPayloads {
    repair(
      text: text,
      context: context,
      protectedWords: protectedWords,
      lexicon: OrdinaryLowercaseLexicon.bundled
    )
  }

  /// Testing seam. Production always goes through the bundled lexicon above.
  static func repair(
    text: String,
    context: CaretText?,
    protectedWords: Set<String>,
    lexicon: OrdinaryLowercaseLexicon
  ) -> PreparedPayloads {
    let legacy = legacyPayload(text)
    guard let context else {
      return PreparedPayloads(legacyText: legacy, repairedText: nil, candidateRules: [])
    }
    // Inserting between two word characters cannot be repaired safely. The
    // spacing rules would wrap the payload in spaces and split the surrounding
    // word — `"the sto|re"` becomes `"the sto store today re"` — turning a
    // known, predictable annoyance into a broken sentence WE created. There is
    // no way to tell whether the user meant to split the word, so this refuses
    // rather than guesses, and §6 selects today's payload.
    // Founder decision 2026-07-25, correcting the frozen prototype.
    guard !isInsideWord(context) else {
      return PreparedPayloads(
        legacyText: legacy, repairedText: nil, candidateRules: [.refusedInsideWord])
    }
    let (repaired, rules) = contextualPayload(
      text: text, context: context, protectedWords: protectedWords, lexicon: lexicon)
    return PreparedPayloads(
      legacyText: legacy, repairedText: repaired, candidateRules: rules)
  }

  /// Today's delivery-stage rule, absorbed verbatim from
  /// `PasteService.appendTrailingSpace` so there is exactly one owner of it.
  static func legacyPayload(_ text: String) -> String {
    text.hasSuffix(" ") ? text : text + " "
  }

  // MARK: - The rules

  private static func contextualPayload(
    text: String,
    context: CaretText,
    protectedWords: Set<String>,
    lexicon: OrdinaryLowercaseLexicon
  ) -> (String, [AppliedRule]) {
    var out = text
    var rules: [AppliedRule] = []
    guard !text.isEmpty else { return (legacyPayload(text), rules) }

    let left = leftAnchor(of: context.left)
    let right = rightAnchor(of: context.right)

    // Rule 1: a leading space, unless one side already supplies separation.
    if let anchor = left.character, !left.crossedSpace, !openers.contains(anchor),
      let firstCharacter = out.first, !firstCharacter.isWhitespace
    {
      out = " " + out
      rules.append(.leadingSpace)
    }

    // Rule 2: leading case. We are continuing a sentence when the last real
    // character is a letter, a digit, or mid-sentence punctuation — and NOT
    // after a terminator, and not at the start of a line.
    let continuing =
      left.character.map { anchor in
        !left.atLineStart && (anchor.isLetter || anchor.isNumber || continuers.contains(anchor))
      } ?? false

    if continuing {
      let (adjusted, caseRule) = applyLeadingCase(
        to: out, protectedWords: protectedWords, lexicon: lexicon)
      out = adjusted
      rules.append(caseRule)
    } else if left.character == nil {
      // Nothing real to the left: an empty window means nothing precedes the
      // caret at all, a non-empty one means we walked back to a line start.
      rules.append(.caseKept(context.left.isEmpty ? .nothingLeft : .lineStart))
    } else if let anchor = left.character, openers.contains(anchor) {
      rules.append(.caseKept(.afterOpener))
    } else if let anchor = left.character, terminators.contains(anchor) {
      rules.append(.caseKept(.afterTerminator))
    } else {
      rules.append(.caseKept(.other))
    }

    // Rule 2b: a trailing full stop is redundant when real content follows the
    // caret. Only a full stop — `?` and `!` carry meaning the user dictated.
    let rightIsContent =
      right.map { $0.isLetter || $0.isNumber || terminators.contains($0) } ?? false
    if rightIsContent {
      let body = String(out.reversed().drop(while: \.isWhitespace).reversed())
      if body.hasSuffix(".") {
        let trailing = out.dropFirst(body.count)
        out = String(body.dropLast()) + trailing
        rules.append(.droppedTerminalPeriod)
      }
    }

    // Rule 3: a trailing space, unless what follows makes it wrong.
    if let anchor = right {
      if anchor.isWhitespace {
        rules.append(.trailingSpaceSkipped(.rightIsSpace))
      } else if trailingSuppressors.contains(anchor) {
        rules.append(.trailingSpaceSkipped(.rightIsPunctuation))
      } else if !out.hasSuffix(" ") {
        out += " "
        rules.append(.trailingSpace)
      }
    } else if !out.hasSuffix(" ") {
      out += " "
      rules.append(.trailingSpace)
    }

    return (out, rules)
  }

  /// Lowercase the first word only when it is positively known to be safe.
  ///
  /// The guards are an ALLOWLIST, deliberately. An earlier structural test
  /// ("second character is uppercase") wrongly lowercased `PostHog`, `SwiftUI`,
  /// `GitHub` and `Monday`. Refusing unless recognised fails in the safe
  /// direction: an unlisted word simply keeps its capital, which is today's
  /// behaviour.
  private static func applyLeadingCase(
    to text: String,
    protectedWords: Set<String>,
    lexicon: OrdinaryLowercaseLexicon
  ) -> (String, AppliedRule) {
    let leadingWhitespace = text.prefix(while: \.isWhitespace)
    let stripped = text.dropFirst(leadingWhitespace.count)
    guard let firstCharacter = stripped.first else {
      return (text, .caseSkipped(.alreadyLower))
    }
    guard firstCharacter.isUppercase else {
      return (text, .caseSkipped(.alreadyLower))
    }

    let firstWord = stripped.prefix(while: { !$0.isWhitespace })
    let bare = trimEdges(of: String(firstWord), in: terminators.union([",", ";", ":"]))

    if startsWithProtectedSpelling(stripped, protectedWords: protectedWords) {
      return (text, .caseSkipped(.protectedWord))
    }
    if bare.dropFirst().contains(where: \.isUppercase) {
      return (text, .caseSkipped(.mixedCaseOrAcronym))
    }
    if bare.contains(where: \.isNumber) {
      return (text, .caseSkipped(.containsDigit))
    }
    if isFirstPersonPronoun(bare) {
      return (text, .caseSkipped(.pronounI))
    }
    if alwaysCapitalized.contains(bare) {
      return (text, .caseSkipped(.alwaysCapitalized))
    }
    guard lexicon.isAvailable else {
      return (text, .caseSkipped(.lexiconUnavailable))
    }
    guard lexicon.contains(bare) else {
      return (text, .caseSkipped(.notKnownLowercase))
    }

    let lowered = String(firstCharacter).lowercased()
    return (String(leadingWhitespace) + lowered + String(stripped.dropFirst()), .lowercasedFirst)
  }

  /// Whether the caret sits between two word characters.
  ///
  /// Uses the IMMEDIATELY adjacent characters with no whitespace skip-back:
  /// mid-word means literally touching letters or digits on both sides. A space
  /// on either side means we are between words, which is repairable.
  static func isInsideWord(_ context: CaretText) -> Bool {
    guard let left = context.left.last, let right = context.right.first else {
      return false
    }
    return (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
  }

  /// Whether the payload OPENS with a complete protected canonical spelling.
  ///
  /// Matching only the first whitespace-delimited token silently corrupts
  /// multi-word canonicals: `"The Who"` would compare as `"The"`, miss the
  /// protected set, find `the` in the lexicon, and ship `"the Who"`. The
  /// shipped builtins `"Envious Labs"` and `"VS Code"` survive that bug only by
  /// accident — `envious` and `vs` happen to be absent from the lexicon — but
  /// `the`, `open` and `general` are all present, so a user's own custom word is
  /// exactly what breaks. A custom word is the strongest protection signal there
  /// is; it must not depend on a coincidence.
  ///
  /// The match must end on a word boundary so `"Store"` does not shadow
  /// `"Storefront"`.
  static func startsWithProtectedSpelling(
    _ text: Substring,
    protectedWords: Set<String>
  ) -> Bool {
    protectedWords.contains { spelling in
      guard !spelling.isEmpty, text.hasPrefix(spelling) else { return false }
      let remainder = text.dropFirst(spelling.count)
      guard let next = remainder.first else { return true }
      return next.isWhitespace || (!next.isLetter && !next.isNumber)
    }
  }

  /// The English first-person pronoun and its contractions, which never lower.
  ///
  /// Stated explicitly rather than relying on these spellings being absent from
  /// the lexicon: absence is a guarantee by omission that one careless future
  /// addition would silently break.
  static func isFirstPersonPronoun(_ word: String) -> Bool {
    let normalized = OrdinaryLowercaseLexicon.normalizeApostrophes(word)
    return ["I", "I'm", "I've", "I'll", "I'd"].contains(normalized)
  }

  /// Trim `characters` from both ends. `String.trimmingCharacters(in:)` removes a
  /// whole run per call, which is fine here because this is a single pass with no
  /// semantic re-check between removals.
  private static func trimEdges(of word: String, in characters: Set<Character>) -> String {
    let front = word.drop(while: { characters.contains($0) })
    return String(front.reversed().drop(while: { characters.contains($0) }).reversed())
  }

  // MARK: - Anchors

  struct LeftAnchor: Equatable {
    /// Last real character before the caret; `nil` when there is none.
    let character: Character?
    /// Whether spaces or tabs were skipped to reach it.
    let crossedSpace: Bool
    /// Whether a newline, or the start of the window, was reached first.
    let atLineStart: Bool
  }

  /// Walk back over spaces and tabs to the last real character.
  ///
  /// This is the fix for the defect a single character could not express:
  /// `"I went home. "` and `"I went home, "` both end in a space but need
  /// opposite case decisions. A newline is a sentence boundary, not something to
  /// skip over.
  static func leftAnchor(of window: String) -> LeftAnchor {
    var crossed = false
    for character in window.reversed() {
      if character == " " || character == "\t" {
        crossed = true
        continue
      }
      if character.isNewline {
        return LeftAnchor(character: nil, crossedSpace: crossed, atLineStart: true)
      }
      return LeftAnchor(character: character, crossedSpace: crossed, atLineStart: false)
    }
    return LeftAnchor(character: nil, crossedSpace: crossed, atLineStart: true)
  }

  /// The first character after the caret, whitespace included. Unlike the left
  /// side this does NOT skip: an existing space to the right already separates.
  static func rightAnchor(of window: String) -> Character? {
    window.first
  }
}

/// The bundled allowlist of ordinary lowercase English words.
///
/// A PRODUCT resource, not a spell-checker and not an operating-system
/// dictionary, so the same input produces the same output on every machine and
/// in every locale. Provenance, license, normalisation rules, entry count,
/// checksum and measured coverage live beside it in
/// `ordinary-lowercase-words.provenance.md`.
///
/// Invalid data fails CLOSED and disables leading-case repair only: spacing and
/// terminal-period repair keep working, and the leading word keeps its capital,
/// which is today's behaviour.
struct OrdinaryLowercaseLexicon: Equatable, Sendable {
  /// Normalised entries. Empty when the resource could not be trusted.
  let words: Set<String>
  /// Whether leading-case repair may consult this lexicon at all.
  let isAvailable: Bool

  static let resourceName = "ordinary-lowercase-words"

  /// One entry: ASCII lowercase letters, at most one INTERNAL ASCII apostrophe.
  /// Deliberately strict — a malformed line invalidates the whole resource
  /// rather than being skipped, because silently dropping entries would make
  /// coverage unreproducible.
  static func isWellFormedEntry(_ entry: String) -> Bool {
    guard !entry.isEmpty else { return false }
    var apostrophes = 0
    for (offset, character) in entry.enumerated() {
      if character == "'" {
        apostrophes += 1
        if offset == 0 || offset == entry.count - 1 { return false }
        continue
      }
      guard character.isASCII, character.isLowercase, character.isLetter else { return false }
    }
    return apostrophes <= 1
  }

  /// Fold the Unicode right single quote to the ASCII apostrophe. Cloud polish
  /// providers emit `U+2019`, and the lexicon stores `U+0027`.
  static func normalizeApostrophes(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2019}", with: "'")
  }

  /// Parse the committed file format. Returns an UNAVAILABLE lexicon on any
  /// malformed line or duplicate entry.
  static func parse(_ contents: String) -> OrdinaryLowercaseLexicon {
    var words: Set<String> = []
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let entry = normalizeApostrophes(line)
      guard isWellFormedEntry(entry) else { return .unavailable }
      guard words.insert(entry).inserted else { return .unavailable }
    }
    guard !words.isEmpty else { return .unavailable }
    return OrdinaryLowercaseLexicon(words: words, isAvailable: true)
  }

  static let unavailable = OrdinaryLowercaseLexicon(words: [], isAvailable: false)

  /// The shipped resource, resolved once through this target's own resource
  /// bundle. `Bundle.module`, never `Bundle.main`: the app is not the only host
  /// of this code.
  static let bundled: OrdinaryLowercaseLexicon = {
    guard let url = Bundle.module.url(forResource: resourceName, withExtension: "txt"),
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      return .unavailable
    }
    return parse(contents)
  }()

  /// Apply the full lookup normalisation the committed provenance record
  /// specifies: fold the Unicode right quote, trim surrounding punctuation and
  /// quotation marks, then lowercase with the invariant mapping.
  ///
  /// The trim matters because a caller can hand us a token still wearing its
  /// quotes or brackets. Only the OUTER edges are trimmed, so internal
  /// apostrophes in `let's` and `don't` survive.
  static func normalizeLookupToken(_ text: String) -> String {
    let folded = normalizeApostrophes(text)
    let front = folded.drop { $0.isWhitespace || $0.isPunctuation }
    let trimmed = front.reversed().drop { $0.isWhitespace || $0.isPunctuation }.reversed()
    return String(trimmed).lowercased()
  }

  /// Case-insensitive, locale-independent membership.
  func contains(_ word: String) -> Bool {
    guard isAvailable else { return false }
    return words.contains(Self.normalizeLookupToken(word))
  }
}
