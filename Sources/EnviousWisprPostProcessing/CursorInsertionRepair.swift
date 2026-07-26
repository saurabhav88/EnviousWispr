import EnviousWisprCore
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
    case alreadyLower = "already_lower"
    case protectedWord = "protected_word"
    case mixedCaseOrAcronym = "mixed_case_or_acronym"
    case containsDigit = "contains_digit"
    case pronounI = "pronoun_i"
    case alwaysCapitalized = "always_capitalized"
    case notKnownLowercase = "not_known_lowercase"
    case lexiconUnavailable = "lexicon_unavailable"
    /// The dictation is not in a language whose casing rules we know. The
    /// lexicon is English, and applying it to another language is not merely
    /// useless — it is actively wrong. `See`, `Start`, `Test`, `Team` and
    /// `Most` are all ordinary English lowercase words AND German nouns, which
    /// German capitalises mid-sentence without exception. Firing there would
    /// lowercase a correctly-capitalised noun in the language spoken by the
    /// largest single share of our users.
    case languageNotSupported = "language_not_supported"
  }

  /// Why the position itself meant no case change was appropriate.
  public enum CaseKeptReason: String, Equatable, Sendable {
    case lineStart = "line_start"
    case nothingLeft = "nothing_left"
    case afterOpener = "after_opener"
    case afterTerminator = "after_terminator"
    case other
  }

  /// Why no trailing space was added.
  public enum TrailingSkipReason: String, Equatable, Sendable {
    case rightIsSpace = "right_is_space"
    case rightIsPunctuation = "right_is_punctuation"
    /// The language writes without spaces between words (Japanese, Chinese,
    /// Thai, Lao, Burmese, Khmer). A space at either end of the insertion is a
    /// visible defect in those scripts, not a separator.
    case unsegmentedScript = "unsegmented_script"
  }

  /// One decision the repair took, for tests and privacy-safe telemetry.
  /// Carries no user text — only the shape of what was decided.
  public enum AppliedRule: Equatable, Sendable {
    /// The caret sits between two word characters, so no contextual candidate
    /// was offered at all. Distinct from an empty rule list, which means the
    /// caret context could not be READ — one is a deliberate refusal, the other
    /// an accessibility failure, and the field needs to tell them apart.
    case refusedInsideWord
    /// Nothing real precedes the caret, so there is nothing to continue and no
    /// way to confirm the position is even real. Distinct from
    /// `refusedInsideWord`: that one knows exactly where it is and declines,
    /// this one cannot place itself.
    case refusedNoLeftAnchor
    case leadingSpace
    case lowercasedFirst
    case caseSkipped(CaseSkipReason)
    case caseKept(CaseKeptReason)
    case droppedTerminalPeriod
    case trailingSpace
    case trailingSpaceSkipped(TrailingSkipReason)

    /// A closed, privacy-safe name for telemetry.
    ///
    /// Deliberately carries the REASON and never the word it applied to: a
    /// wrong-case report is unanswerable without knowing that the guard which
    /// fired was `case_skipped:not_known_lowercase` rather than
    /// `case_skipped:protected_word`, and neither name reveals a syllable of
    /// what the user dictated.
    public var telemetryName: String {
      switch self {
      case .refusedInsideWord: return "refused:inside_word"
      case .refusedNoLeftAnchor: return "refused:no_left_anchor"
      case .leadingSpace: return "leading_space"
      case .lowercasedFirst: return "lowercased_first"
      case .caseSkipped(let reason): return "case_skipped:\(reason.rawValue)"
      case .caseKept(let reason): return "case_kept:\(reason.rawValue)"
      case .droppedTerminalPeriod: return "dropped_terminal_period"
      case .trailingSpace: return "trailing_space"
      case .trailingSpaceSkipped(let reason): return "trailing_space_skipped:\(reason.rawValue)"
      }
    }
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
  /// Opening brackets and unambiguous opening quotes: no leading space, and no
  /// case change. Straight quotes are NOT here — they are direction-ambiguous
  /// and resolved by `isOpeningQuote`.
  static let openers: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}"]
  /// Quotes whose direction the character alone does not settle.
  static let ambiguousQuotes: Set<Character> = ["\"", "'"]
  /// Right-hand characters that make a trailing space wrong. Closing quotes
  /// belong here for the same reason closing brackets do: a space before them
  /// lands INSIDE the quotation.
  static let trailingSuppressors: Set<Character> = [
    ".", "!", "?", ",", ";", ":", ")", "]", "}", "\u{201D}", "\u{2019}",
  ]
  /// Always capitalised regardless of position. Closed set, so it needs no lexicon.
  static let alwaysCapitalized: Set<String> = [
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
  ]

  // MARK: - Language policy

  /// What this repair may do in the language actually being dictated.
  ///
  /// Both answers are per-language and neither is a detail of the other: Japanese
  /// has no casing AND no word spacing, German has both but inverts the noun
  /// rule, and Russian spaces its words while using an alphabet our lexicon has
  /// never seen. Deciding them separately keeps every language in exactly one of
  /// four honest states rather than one all-or-nothing switch.
  struct LanguageRules: Equatable {
    /// Words are separated by spaces, so a seam may need one.
    let usesWordSpacing: Bool
    /// We hold casing knowledge for this language. English only today.
    let knowsCasing: Bool

    /// Unknown language: space, do not recase. Spacing is what all but six of
    /// Whisper's ninety-nine languages do, and a missing or extra space is a
    /// far smaller error than a wrongly lowercased proper noun.
    static let unknown = LanguageRules(usesWordSpacing: true, knowsCasing: false)

    static func forLanguage(_ raw: String?) -> LanguageRules {
      guard let base = LanguageNormalizer.baseCode(raw) else { return .unknown }
      return LanguageRules(
        usesWordSpacing: !LanguageTypes.isUnsegmentedScript(base),
        knowsCasing: base == "en")
    }
  }

  // MARK: - Entry point

  /// Prepare both payloads for `text` at the caret described by `context`.
  ///
  /// - Parameters:
  ///   - text: the outgoing dictation, already fully processed.
  ///   - context: the document text either side of the caret, or `nil` when it
  ///     could not be read. `nil` yields today's payload only — NOT the raw input.
  ///   - protectedWords: canonical spellings that must never be recased.
  ///   - language: what the engine says was spoken, raw. Required rather than
  ///     defaulted: a call site that forgets it would silently get English
  ///     casing rules applied to another language, which is the one outcome
  ///     this parameter exists to prevent.
  public static func repair(
    text: String,
    context: CaretText?,
    protectedWords: Set<String>,
    language: String?
  ) -> PreparedPayloads {
    repair(
      text: text,
      context: context,
      protectedWords: protectedWords,
      language: language,
      lexicon: OrdinaryLowercaseLexicon.bundled
    )
  }

  /// Testing seam. Production always goes through the bundled lexicon above.
  static func repair(
    text: String,
    context: CaretText?,
    protectedWords: Set<String>,
    language: String? = "en",
    lexicon: OrdinaryLowercaseLexicon
  ) -> PreparedPayloads {
    let legacy = legacyPayload(text)
    guard let context else {
      return PreparedPayloads(legacyText: legacy, repairedText: nil, candidateRules: [])
    }
    let rules = LanguageRules.forLanguage(language)
    // Inserting between two word characters cannot be repaired safely. The
    // spacing rules would wrap the payload in spaces and split the surrounding
    // word — `"the sto|re"` becomes `"the sto store today re"` — turning a
    // known, predictable annoyance into a broken sentence WE created. There is
    // no way to tell whether the user meant to split the word, so this refuses
    // rather than guesses, and §6 selects today's payload.
    // Founder decision 2026-07-25, correcting the frozen prototype.
    //
    // The refusal does NOT apply to a script that writes without spaces
    // (Codex review r4). Japanese, Chinese and Thai run their characters
    // together, so "between two word characters" is where the caret NORMALLY
    // sits — the guard fired on nearly every position and sent every such
    // dictation to a payload that appends an ASCII space. There is also nothing
    // to protect: with word spacing off and casing unknown, the candidate can
    // only ever be the text unchanged, so it cannot split anything, not even a
    // Latin word embedded in Japanese text.
    if rules.usesWordSpacing, isInsideWord(context) {
      return PreparedPayloads(
        legacyText: legacy, repairedText: nil, candidateRules: [.refusedInsideWord])
    }
    // Nothing real to the left means there is nothing to continue: the capital
    // stays and no leading space is wanted, which is already today's payload.
    // The only rules that could still act read the RIGHT window — and one of
    // them deletes a full stop the user dictated.
    //
    // MEASURED in Ghostty, 2026-07-25: its character count grows as the user
    // types (42 -> 179 -> 198) while `AXSelectedTextRange` stays pinned at 0.
    // A caret of zero in a field holding a whole scrollback is not an insertion
    // point, so that "right window" is the TOP of the buffer rather than the
    // text after the cursor — and trusting it silently stripped the full stop
    // from a sentence dictated into a terminal.
    //
    // Refusing here also fixes the honest version of the same position: text
    // inserted at the very start of a document is not continuing the sentence
    // that follows it, so its full stop is not redundant either.
    //
    // Scoped to a NON-EMPTY right window, which is the only case where the
    // right side can change the answer. With nothing on either side there is
    // nothing to distrust and the candidate is today's payload character for
    // character, so refusing there would add a refusal that changes no text.
    // Founder direction 2026-07-25 that this work in every tool.
    if leftAnchor(of: context.left).character == nil, !context.right.isEmpty {
      return PreparedPayloads(
        legacyText: legacy, repairedText: nil, candidateRules: [.refusedNoLeftAnchor])
    }
    let (repaired, appliedRules) = contextualPayload(
      text: text,
      context: context,
      protectedWords: protectedWords,
      language: rules,
      lexicon: lexicon)
    return PreparedPayloads(
      legacyText: legacy, repairedText: repaired, candidateRules: appliedRules)
  }

  /// Today's delivery-stage rule, absorbed verbatim from
  /// the retired `PasteService.appendTrailingSpace`, which is now deleted — this
  /// is the single owner of the rule.
  static func legacyPayload(_ text: String) -> String {
    text.hasSuffix(" ") ? text : text + " "
  }

  // MARK: - The rules

  private static func contextualPayload(
    text: String,
    context: CaretText,
    protectedWords: Set<String>,
    language: LanguageRules,
    lexicon: OrdinaryLowercaseLexicon
  ) -> (String, [AppliedRule]) {
    var out = text
    var rules: [AppliedRule] = []
    guard !text.isEmpty else { return (legacyPayload(text), rules) }

    let left = leftAnchor(of: context.left)
    let right = rightAnchor(of: context.right)

    // Rule 1: a leading space, unless one side already supplies separation —
    // or the language does not separate words with spaces at all.
    if language.usesWordSpacing, let anchor = left.character, !left.crossedSpace,
      !left.isOpener,
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

    if continuing, !language.knowsCasing {
      // Positioned to lowercase, but not in a language whose casing we know.
      // Recorded as a skip rather than silently omitted so the field can tell
      // "we chose not to" from "the position did not call for it".
      rules.append(.caseSkipped(.languageNotSupported))
    } else if continuing {
      let (adjusted, caseRule) = applyLeadingCase(
        to: out, protectedWords: protectedWords, lexicon: lexicon)
      out = adjusted
      rules.append(caseRule)
    } else if left.character == nil {
      // Nothing real to the left: an empty window means nothing precedes the
      // caret at all, a non-empty one means we walked back to a line start.
      rules.append(.caseKept(context.left.isEmpty ? .nothingLeft : .lineStart))
    } else if left.isOpener {
      rules.append(.caseKept(.afterOpener))
    } else if let anchor = left.character, terminators.contains(anchor) {
      rules.append(.caseKept(.afterTerminator))
    } else {
      rules.append(.caseKept(.other))
    }

    // Rule 2b: a trailing full stop is redundant when real content follows the
    // caret. Only a full stop — `?` and `!` carry meaning the user dictated.
    //
    // Whitespace is skipped to find that content, mirroring the left side, which
    // has walked back over spaces since the beginning. Without the symmetry, a
    // right window of `" yesterday"` read as "nothing follows" and kept the
    // period, producing `store today. yesterday` in the middle of a sentence
    // (Codex review r3). The skip stops at a newline: content on the NEXT line
    // is a new sentence, and the user's full stop belongs to this one.
    let rightContent = rightContentAnchor(of: context.right)
    let rightIsContent =
      rightContent.map { $0.isLetter || $0.isNumber || terminators.contains($0) } ?? false
    if rightIsContent {
      let body = String(out.reversed().drop(while: \.isWhitespace).reversed())
      if body.hasSuffix(".") {
        let trailing = out.dropFirst(body.count)
        out = String(body.dropLast()) + trailing
        rules.append(.droppedTerminalPeriod)
      }
    }

    // Rule 3: a trailing space, unless what follows makes it wrong.
    if !language.usesWordSpacing {
      rules.append(.trailingSpaceSkipped(.unsegmentedScript))
    } else if let anchor = right {
      if anchor.isWhitespace {
        rules.append(.trailingSpaceSkipped(.rightIsSpace))
      } else if trailingSuppressors.contains(anchor)
        || isClosingQuoteAhead(anchor, in: context.right)
      {
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
    return isWordSide(left, otherSide: context.left.dropLast().last)
      && isWordSide(right, otherSide: context.right.dropFirst().first)
  }

  /// Characters that join one word rather than separating two: the apostrophe in
  /// `can't` and the hyphen in `state-of-the-art`.
  static let wordConnectors: Set<Character> = ["'", "\u{2019}", "-", "\u{2010}"]

  /// Whether this character means "a word continues here".
  ///
  /// A letter or digit always does. A connector does only when the character on
  /// its far side is itself alphanumeric — `can|'t` is inside a word, while a
  /// trailing possessive in `the Joneses'|` is not, and a dash in `- item` is a
  /// bullet rather than a hyphenated word.
  ///
  /// Found by Codex review: without this, a caret at `can|'t` saw punctuation on
  /// one side, decided it was between words, and inserted a space in the middle
  /// of the contraction — the exact breakage `refusedInsideWord` exists to
  /// prevent, reached through a character the guard did not recognise.
  private static func isWordSide(_ character: Character, otherSide: Character?) -> Bool {
    if character.isLetter || character.isNumber { return true }
    guard wordConnectors.contains(character), let otherSide else { return false }
    return otherSide.isLetter || otherSide.isNumber
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
    /// Whether that character OPENS something the insertion goes inside — a
    /// bracket, or a quote resolved as opening. Computed here, where the
    /// surrounding text is still in hand, because a straight quote's direction
    /// cannot be read from the character alone.
    let isOpener: Bool
  }

  /// Walk back over spaces and tabs to the last real character.
  ///
  /// This is the fix for the defect a single character could not express:
  /// `"I went home. "` and `"I went home, "` both end in a space but need
  /// opposite case decisions. A newline is a sentence boundary, not something to
  /// skip over.
  /// Punctuation that INTRODUCES a quotation, so a straight quote right after
  /// one is opening: `He said:"`, `— "`. A comma is deliberately absent: in the
  /// dominant convention `,"` closes (`"hello," she said`), and a comma that
  /// introduces is written `, "`, which is settled by the whitespace rule first.
  static let quoteIntroducers: Set<Character> = [":", ";", "\u{2014}", "\u{2013}", "-"]

  /// Whether the character just AFTER the caret is a straight quote that closes
  /// the quotation we are inserting into.
  ///
  /// The mirror of `isOpeningQuote`, and the half the r2 enumeration missed: it
  /// settled which quotes take a space BEFORE the insertion, and said nothing
  /// about the one sitting immediately after it. Inserting into
  /// `He said "hello |" and left` was therefore given a trailing space that
  /// lands inside the quotation.
  ///
  /// A quote closes when what follows it is not more quoted words: whitespace,
  /// punctuation, or the end of what we can see. A letter or digit right after
  /// means the quote is opening the NEXT quotation, and the insertion does need
  /// its space.
  static func isClosingQuoteAhead(_ anchor: Character, in window: String) -> Bool {
    guard ambiguousQuotes.contains(anchor) else { return false }
    guard let following = window.dropFirst().first else { return true }
    return !(following.isLetter || following.isNumber)
  }

  /// Whether a straight quote at the caret's left is OPENING the quotation
  /// rather than closing it.
  ///
  /// Two review rounds each found one wrong cell of this decision, so the space
  /// is enumerated here in full rather than patched a case at a time. Every
  /// character that can precede a straight quote, and the direction it implies:
  ///
  /// | Preceding | Direction | Example |
  /// |---|---|---|
  /// | nothing at all | opening | a quote starting the field |
  /// | whitespace or newline | opening | `He said "` |
  /// | bracket or curly open quote | opening | `("` |
  /// | `:` `;` em/en dash, hyphen | opening | `He said:"` |
  /// | letter or digit | closing | `"hello"` |
  /// | `.` `!` `?` `,` | closing | `"Stop!"`, `"hello,"` |
  /// | anything else | closing | unknown punctuation |
  ///
  /// Unknown defaults to CLOSING because the two errors are not equally bad:
  /// wrongly closing adds a space inside a quotation, which is cosmetic, while
  /// wrongly opening omits a needed space and runs two words together as
  /// `hello"Store`. The cheaper mistake is the default.
  ///
  /// `window` is the left context; `quoteIndex` is where the quote sits in it.
  static func isOpeningQuote(in window: String, at quoteIndex: String.Index) -> Bool {
    guard quoteIndex > window.startIndex else { return true }
    let preceding = window[window.index(before: quoteIndex)]
    if preceding.isWhitespace { return true }
    if openers.contains(preceding) { return true }
    if quoteIntroducers.contains(preceding) { return true }
    return false
  }

  static func leftAnchor(of window: String) -> LeftAnchor {
    var crossed = false
    var index = window.endIndex
    while index > window.startIndex {
      index = window.index(before: index)
      let character = window[index]
      if character == " " || character == "\t" {
        crossed = true
        continue
      }
      if character.isNewline {
        return LeftAnchor(
          character: nil, crossedSpace: crossed, atLineStart: true, isOpener: false)
      }
      let opener =
        openers.contains(character)
        || (ambiguousQuotes.contains(character) && isOpeningQuote(in: window, at: index))
      return LeftAnchor(
        character: character, crossedSpace: crossed, atLineStart: false, isOpener: opener)
    }
    return LeftAnchor(character: nil, crossedSpace: crossed, atLineStart: true, isOpener: false)
  }

  /// The first character after the caret, whitespace included. Unlike the left
  /// side this does NOT skip: an existing space to the right already separates,
  /// so SPACING must see it.
  static func rightAnchor(of window: String) -> Character? {
    window.first
  }

  /// The first real character after the caret, skipping spaces and tabs but
  /// stopping at a newline.
  ///
  /// Spacing and the terminal-period rule ask different questions of the right
  /// side, which is why they read it differently. Spacing asks "is there already
  /// a separator", so it must see the space itself. The period rule asks "does
  /// this sentence continue", and a space is not an answer to that — the content
  /// behind it is. A newline stops the walk: text on the next line is a new
  /// sentence, and the user's full stop belongs to the one they just dictated.
  static func rightContentAnchor(of window: String) -> Character? {
    for character in window {
      if character == " " || character == "\t" { continue }
      if character.isNewline { return nil }
      return character
    }
    return nil
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
