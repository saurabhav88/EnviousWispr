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
    /// Whether `left` begins at the very start of the document rather than at a
    /// bounded-window cut.
    ///
    /// The difference is invisible in the string itself and decides whether a
    /// token touching the window's start is COMPLETE or merely the tail of a
    /// longer word. Defaults to `false`, which refuses — a caller that does not
    /// know cannot accidentally authorise a deletion.
    public let leftReachesDocumentStart: Bool

    /// Whether this context was parsed from a terminal's rendered SCREEN rather
    /// than read from a real caret.
    ///
    /// The narrow POLICY fact, and nothing more: process and accessibility
    /// evidence stay in Services. A screen-derived line is one rendered row, so
    /// a payload containing a line break cannot be reasoned about here — see
    /// the refusal in `prepare`.
    public let isScreenDerived: Bool

    public init(
      left: String, right: String, leftReachesDocumentStart: Bool = false,
      isScreenDerived: Bool = false
    ) {
      self.left = left
      self.right = right
      self.leftReachesDocumentStart = leftReachesDocumentStart
      self.isScreenDerived = isScreenDerived
    }
  }

  // MARK: - Outputs

  /// Why the leading capital was left alone.
  public enum CaseSkipReason: String, Equatable, Sendable {
    case alreadyLower = "already_lower"
    case protectedWord = "protected_word"
    case mixedCaseOrAcronym = "mixed_case_or_acronym"
    /// German only: the word-class tagger called this a noun, and German
    /// capitalises every noun. #1922.
    case nounInNounCapitalisingLanguage = "noun_in_noun_capitalising_language"
    /// A form whose capital marks polite address — German `Sie`, Swedish `Ni`.
    /// The capital IS the meaning, so no dictionary can see it. #1922.
    case politeForm = "polite_form"
    case containsDigit = "contains_digit"
    case pronounI = "pronoun_i"
    case alwaysCapitalized = "always_capitalized"
    /// The system dictionary does not recognise the lowercase form.
    case notOrdinaryWord = "not_ordinary_word"
    /// No usable dictionary for THIS dictation's language on this machine.
    /// Per-language since #1922: a missing Danish dictionary says nothing about
    /// the English one, and demoting all of them would turn one language's
    /// outage into a whole-feature outage.
    case dictionaryUnavailable = "dictionary_unavailable"
    /// Apple's recogniser read this word as a person, place or organisation in
    /// this sentence, so the capital is carrying meaning.
    case recognizedName = "recognized_name"
    /// The name recogniser is unavailable on this device.
    case wordClassUnavailable = "word_class_unavailable"
    /// The user taught macOS this word, which skews heavily toward names and
    /// brands, so it is evidence against lowering.
    case learnedWord = "learned_word"
    /// Launch preparation has not finished. The first dictation after a cold
    /// launch keeps its capital — today's behaviour — rather than paying the
    /// measured 105.6 ms of one-time setup on the paste path.
    case oracleWarming = "oracle_warming"
    /// A live decision exceeded its deadline. Latched for the process, so a
    /// stalled spelling service can never be waited on twice.
    case oracleTimedOut = "oracle_timed_out"
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
    /// The payload's first word repeated the word immediately left of the caret,
    /// so ours was dropped. Placement only — see `dropDuplicateSeamToken`.
    case droppedDuplicateWord
    case droppedTerminalPeriod
    case trailingSpace
    case trailingSpaceSkipped(TrailingSkipReason)

    /// A closed, privacy-safe name for telemetry.
    ///
    /// Deliberately carries the REASON and never the word it applied to: a
    /// wrong-case report is unanswerable without knowing that the guard which
    /// fired was `case_skipped:not_ordinary_word` rather than
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
      case .droppedDuplicateWord: return "dropped_duplicate_word"
      case .droppedTerminalPeriod: return "dropped_terminal_period"
      case .trailingSpace: return "trailing_space"
      case .trailingSpaceSkipped(let reason): return "trailing_space_skipped:\(reason.rawValue)"
      }
    }

    /// Whether this rule REMOVES text the user actually dictated, as opposed to
    /// adjusting placement, spacing or a capital.
    ///
    /// The distinction decides whether a clipboard route pays for a commit-time
    /// caret re-read. Everything else this repair does is worth one letter or
    /// one space if the caret has moved underneath it — the same cost as
    /// refusing — so re-reading buys nothing and fires far more often than the
    /// caret actually moves. A deletion is different: committing it against
    /// stale evidence loses content rather than trading one blemish for another.
    ///
    /// Written as an EXHAUSTIVE switch with no `default`, deliberately. A future
    /// rule that deletes something must not be able to inherit "false" by
    /// omission — the compiler makes it a decision. Cloud review found exactly
    /// that gap: the first version of this asked `contains(.droppedDuplicateWord)`
    /// at the call site and silently missed `.droppedTerminalPeriod`.
    public var deletesDictatedText: Bool {
      switch self {
      case .droppedDuplicateWord, .droppedTerminalPeriod:
        return true
      case .refusedInsideWord, .refusedNoLeftAnchor, .leadingSpace, .lowercasedFirst,
        .caseSkipped, .caseKept, .trailingSpace, .trailingSpaceSkipped:
        return false
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
  /// How a language wants its leading capital decided, when it wants one decided
  /// at all. `nil` in `LanguageRules.casingPolicy` means abstain.
  ///
  /// Two knobs, because exactly two things vary across the TWELVE languages that
  /// have a policy — English plus the eleven #1922 added — and neither implies the
  /// other. German inverts the noun rule and has polite forms; Swedish has polite
  /// forms and no noun rule; the other ten have neither.
  struct CasingPolicy: Equatable {
    /// Keep the capital when the word-class tagger calls this word a noun.
    ///
    /// TRUE for German ONLY, and that is a measurement, not an oversight: German
    /// capitalises every noun, so "lower a positively identified non-noun" is its
    /// rule. French and Italian LOWERCASE their common nouns, so the same veto
    /// there refuses correct lowerings — measured at a third of their recall for
    /// one point of precision. Do not extend this on intuition.
    let nounVeto: Bool

    /// Forms that are always capitalised for politeness, lowercased for lookup.
    ///
    /// A closed grammatical inventory (German `Sie`/`Ihr`/`Ihnen` and their
    /// declensions, Swedish `Ni`), NOT a vocabulary prediction — the distinction
    /// `matcher-set-adversarial-tests`' generalisation gate turns on. The test is
    /// whether the CAPITAL ITSELF carries the meaning: `Sie` capitalised is the
    /// polite you, `sie` is "she". Italian and Russian polite lists were tried
    /// and REVERTED because theirs failed that test — `la`, `le`, `suo`, `sua`,
    /// `вы` are ordinary articles, possessives and pronouns, so protecting them
    /// blocked correct lowerings and cost far more than it saved.
    let politeForms: Set<String>

    /// The English shape: dictionary and name detection decide, nothing else.
    static let plain = CasingPolicy(nounVeto: false, politeForms: [])
  }

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

    /// How to decide the leading capital, or `nil` to leave it alone.
    ///
    /// Replaces the former `knowsCasing: Bool`, which could only say yes or no
    /// and so could not express that German's rule is inverted. One authority for
    /// "what may this repair do in this language", covering spacing and casing.
    let casingPolicy: CasingPolicy?

    /// The resolved two-letter code, or `nil` when the language is unknown.
    ///
    /// Carried because LOWERCASING IS LOCALE-DEPENDENT and the repair cannot
    /// recover the language once `forLanguage` has mapped it. Turkish `I`
    /// lowercases to `ı`, not `i`, and only a Turkish locale knows that; Dutch
    /// needs its own digraph handling. Measured both ways in
    /// `2026-08-05-lowering-locale-probe.swift`.
    let baseCode: String?

    /// Unknown language: space, do not recase. Spacing is what all but six of
    /// Whisper's ninety-nine languages do, and a missing or extra space is a
    /// far smaller error than a wrongly lowercased proper noun.
    static let unknown = LanguageRules(
      usesWordSpacing: true, casingPolicy: nil, baseCode: nil)

    /// The eleven languages measured as safe, and the two that need more than the
    /// English shape.
    ///
    /// This is a POLICY table keyed by language code, and that is deliberate even
    /// though `cursor-aware-insertion.md` RULE: never-extend-knowsCasing-by-adding-a-language-code
    /// forbids code-gating. That rule governs AVAILABILITY — whether macOS can
    /// actually serve a language — because Apple's facilities fail open and a
    /// code-based gate would trust a service that is lying. Availability is still
    /// probed at runtime by the oracle, unchanged. What lives here is the
    /// LANGUAGE'S OWN GRAMMAR: German capitalises its nouns whether or not this
    /// Mac has a German dictionary installed. There is no fail-open to detect.
    ///
    /// Every entry is measured on held-out published text; per-language numbers
    /// and the floors they must clear are in the #1922 plan §13. A language absent
    /// from this table abstains, which is what all 23 remaining European
    /// languages do today and must keep doing.
    static let casingPolicies: [String: CasingPolicy] = [
      // Full toolkit, English shape.
      "en": .plain, "fr": .plain, "it": .plain,
      // Dictionary only, English shape. No name detection exists for these, so
      // the dictionary alone carries the decision.
      "ru": .plain, "nl": .plain, "es": .plain, "pt": .plain,
      "da": .plain, "fi": .plain, "tr": .plain,
      // German: the only language whose rule inverts.
      "de": CasingPolicy(
        nounVeto: true,
        politeForms: ["sie", "ihr", "ihnen", "ihre", "ihrer", "ihres", "ihrem", "ihren"]),
      // Swedish: polite forms without a noun rule. `.lexicalClass` is unavailable
      // for Swedish, so a veto here would be inert even if the grammar wanted one.
      "sv": CasingPolicy(nounVeto: false, politeForms: ["ni", "er", "ert", "era"]),
    ]

    static func forLanguage(_ raw: String?) -> LanguageRules {
      guard let base = LanguageNormalizer.baseCode(raw) else { return .unknown }
      return LanguageRules(
        usesWordSpacing: !LanguageTypes.isUnsegmentedScript(base),
        casingPolicy: casingPolicies[base],
        baseCode: base)
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
  /// Today's payload only, with the reason recorded.
  ///
  /// For the caller's deadline path: when a decision is abandoned there is no
  /// repaired candidate at all, so delivery continues with exactly what the app
  /// produced before this feature existed. Deliberately narrow — it keeps the
  /// oracle types inside this module rather than widening them so Pipeline can
  /// name one.
  package static func legacyOnly(text: String, reason: CaseSkipReason) -> PreparedPayloads {
    PreparedPayloads(
      legacyText: legacyPayload(text),
      repairedText: nil,
      candidateRules: [.caseSkipped(reason)])
  }

  /// The oracle-explicit entry point.
  ///
  /// `package` rather than internal because Pipeline snapshots the runtime on
  /// the main actor and passes the value in, so no caller has to mutate
  /// process-global state to control this decision — which is what let two test
  /// suites race each other (local diff review, P2).
  package static func repair(
    text: String,
    context: CaretText?,
    protectedWords: Set<String>,
    language: String? = "en",
    oracle: SeamCasingOracle
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
    // A screen-derived context describes ONE rendered row. A payload carrying a
    // line break would submit a line the user never saw assembled, and in a
    // terminal a newline can SUBMIT the command — so refuse rather than reason
    // about it. Cheap, and it costs nothing real: dictation into a terminal
    // prompt is a single line by construction.
    if context.isScreenDerived, text.contains(where: \.isNewline) {
      return PreparedPayloads(
        legacyText: legacy, repairedText: nil, candidateRules: [.refusedNoLeftAnchor])
    }
    let (repaired, appliedRules) = contextualPayload(
      text: text,
      context: context,
      protectedWords: protectedWords,
      language: rules,
      oracle: oracle)
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
    oracle: SeamCasingOracle
  ) -> (String, [AppliedRule]) {
    var out = text
    var rules: [AppliedRule] = []
    guard !text.isEmpty else { return (legacyPayload(text), rules) }

    let left = leftAnchor(of: context.left)
    let right = rightAnchor(of: context.right)

    // Rule 1: a leading space, unless one side already supplies separation —
    // or the language does not separate words with spaces at all.
    //
    // NEVER in a terminal (founder 2026-07-28, after live testing). A terminal
    // truncates each rendered row at its last VISIBLE character — measured: an
    // input row reported length 2 while the rules around it were 68 — because it
    // draws a cursor where the trailing space would be. So `fix the` and
    // `fix the ` are byte-identical on screen and this rule cannot tell them
    // apart. Since every dictation already ends with a trailing space, it fired
    // on every consecutive dictation and produced a double space every time.
    //
    // Dropping it rather than dropping the trailing space is the founder's call
    // and the better one: the trailing space is a product promise users have
    // already learned everywhere else, and removing it in terminals alone would
    // make terminals the one inconsistent surface. The cost — typing a word,
    // not typing a space, then dictating — is user-controlled and already how
    // the app behaves next to a period, which users understand because they
    // caused it.
    if !context.isScreenDerived, language.usesWordSpacing, let anchor = left.character,
      !left.crossedSpace, !left.isOpener,
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

    if continuing, let policy = language.casingPolicy {
      let (adjusted, caseRule) = applyLeadingCase(
        to: out, leftWindow: context.left, isScreenDerived: context.isScreenDerived,
        protectedWords: protectedWords, oracle: oracle,
        policy: policy, languageCode: language.baseCode)
      out = adjusted
      rules.append(caseRule)
    } else if continuing {
      // Positioned to lowercase, but not in a language whose casing we know.
      // Recorded as a skip rather than silently omitted so the field can tell
      // "we chose not to" from "the position did not call for it".
      rules.append(.caseSkipped(.languageNotSupported))
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

    // Rule 2a: drop a word repeated across the left seam.
    //
    // Polish never sees the document (#1790 is parked), so it returns a
    // well-formed sentence whose opening word the user has often already typed:
    // caret after `I want to go to the`, polish returns `The store is closed
    // today.`, and the result reads `…to the the store…`. This layer is the one
    // that can see both sides, so it removes OUR copy. Founder framing, #1803:
    // "is the word to the left of the cursor the same as the word to the right?
    // If yes, delete that first word before you paste."
    //
    // Placement is seam-only: no lexicon, no part of speech, no judgement about
    // the sentence. It runs AFTER `applyLeadingCase` deliberately — running it
    // first would retarget the casing rule onto the SECOND word, so
    // `the` + `The Review is ready.` would lowercase `Review` (it is in the
    // lexicon) and ship `the review is ready.` (grounded review r1).
    //
    // Guard order matches plan §3: spacing language, alphanumeric anchor, a left
    // token proven complete, a token-shaped match, and something surviving.
    if language.usesWordSpacing,
      let anchor = left.character, anchor.isLetter || anchor.isNumber,
      let leftToken = completeLeftToken(
        in: context.left, reachesDocumentStart: context.leftReachesDocumentStart),
      let deduplicated = dropDuplicateSeamToken(
        from: out, leftToken: leftToken, documentOwnsSeparator: left.crossedSpace)
    {
      out = deduplicated
      rules.append(.droppedDuplicateWord)
    }

    // Rule 2b: never leave TWO full stops touching.
    //
    // SCOPE CORRECTED by the founder, 2026-07-26: "polish takes care of the
    // commas and periods; all the deterministic thing needs to do is place the
    // new sentence where it belongs." Polish owns the sentence — its wording,
    // its internal capitalisation, and its final punctuation. This layer owns
    // only the SEAM, which is the part polish cannot see.
    //
    // The rule that used to live here judged whether the user's trailing full
    // stop was redundant, which is a judgement about the SENTENCE and therefore
    // polish's to make. It produced six of this branch's review findings —
    // `etc.`, `U.S.`, `Jan.`, `Ave.`, `No.`, and a whole sentence inserted
    // between two others — every one of them DELETING a character the user
    // dictated. Deleted rather than fixed a seventh time.
    //
    // What remains is not a judgement: if our text ends with a full stop and the
    // very next character is another one, the pair is a placement artifact we
    // would be creating, so we drop ours. No word knowledge, no lexicon, no
    // language, no abbreviation question.
    if out.reversed().drop(while: \.isWhitespace).first == ".",
      rightAnchor(of: context.right) == "."
    {
      let body = String(out.reversed().drop(while: \.isWhitespace).reversed())
      let trailing = out.dropFirst(body.count)
      out = String(body.dropLast()) + trailing
      rules.append(.droppedTerminalPeriod)
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
    leftWindow: String,
    isScreenDerived: Bool,
    protectedWords: Set<String>,
    oracle: SeamCasingOracle,
    policy: CasingPolicy,
    languageCode: String?
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

    // ORDER IS LOAD-BEARING. The user's own protected spellings outrank every
    // system answer: a custom word is the strongest signal there is, and asking
    // the dictionary first would silently weaken that contract (PR #1804).
    if startsWithProtectedSpelling(stripped, protectedWords: protectedWords) {
      return (text, .caseSkipped(.protectedWord))
    }
    // Dutch `IJ` is ONE casing unit, so its second character is not evidence of
    // an acronym. Without this exemption every `IJ`-initial Dutch word dies here,
    // four guards before the lowering code ever runs — which made rev 2's
    // "add a locale" fix completely inert (verified: `2026-08-05-dutch-guard-probe.swift`).
    //
    // Scoped as narrowly as it can be: Dutch only, exactly `I` then `J`, and only
    // that one character is forgiven. `USA` still refuses in Dutch, because its
    // `S` is not the exempted position. The single-character `Ĳ` ligature never
    // reaches here — it has no second uppercase character.
    if bare.dropFirst().contains(where: \.isUppercase), !isDutchIJDigraph(bare, languageCode) {
      return (text, .caseSkipped(.mixedCaseOrAcronym))
    }
    if bare.contains(where: \.isNumber) {
      return (text, .caseSkipped(.containsDigit))
    }
    // English-only by construction, and that is deliberate: `isFirstPersonPronoun`
    // is `["I", "I'm", …]` and `alwaysCapitalized` is the English weekday/month
    // set. Applying either to German or Turkish would be asserting an English
    // fact about another language. Both were language-blind before this change,
    // which was harmless only because English was the sole casing language.
    if languageCode == "en" {
      if isFirstPersonPronoun(bare) {
        return (text, .caseSkipped(.pronounI))
      }
      if alwaysCapitalized.contains(bare) {
        return (text, .caseSkipped(.alwaysCapitalized))
      }
    }
    // A polite form is capitalised for its ROLE, so the capital carries the
    // meaning and no dictionary can see it: German `Sie` is the polite you while
    // `sie` is "she". Closed grammatical inventory, checked before the oracle
    // because the oracle would happily call it an ordinary word.
    if policy.politeForms.contains(bare.lowercased()) {
      return (text, .caseSkipped(.politeForm))
    }
    // The tagger must see the seam AS IT WILL BE WRITTEN, separator included.
    //
    // Rule 1 has already prepended the leading space to `text`, so it lives in
    // `leadingWhitespace`. Joining the raw left window straight to `stripped`
    // fuses them into one token — `and` + `Mark` becomes `andMark`, which the
    // tagger reads as a Verb, which is a SAFE class, which lowercases somebody's
    // name. Measured on 10 name continuations whose caret sits directly after a
    // word: 7 were wrongly authorised fused, 0 when separated correctly.
    //
    // Every corpus this design was measured against used left contexts that
    // already ended in a space, so none of them could exercise this. Caught by
    // local diff review r2 (P1).
    let taggerLeft = leftWindow + String(leadingWhitespace)
    if let refusal = oracle.mayLower(
      word: bare, left: taggerLeft, payload: String(stripped), languageCode: languageCode)
    {
      return (text, .caseSkipped(refusal))
    }

    // A TERMINAL hides the trailing space, so the seam above may be a lie.
    //
    // A rendered row ends at its last VISIBLE character, which is why `fix the`
    // and `fix the ` are byte-identical on screen and why Rule 1 is disabled
    // here. So `taggerLeft` fuses the left text onto the payload — `with` +
    // `Mark` reads as `withMark`, which the tagger calls a verb, which is a safe
    // class, which lowercases somebody's name. The same defect Rule 1's space
    // fixes everywhere else, arriving through the one door Rule 1 does not
    // cover.
    //
    // MEASURED on six names whose caret sits after a word: FUSED recognised 1
    // of 6, SEPARATED recognised 5. So the separated reading is asked as well,
    // and either one calling it a name keeps the capital.
    //
    // This can only ever DECLINE to lower. Every oracle refusal preserves the
    // capital, which is what the app did before this feature existed, so a
    // wrong answer here cannot damage text that was already correct.
    //
    // Asked only when the seam is actually FUSED. Trailing whitespace in a
    // terminal is unrecoverable in BOTH directions — a read can show cell
    // padding the user never typed, or hide a space they did — so the test is
    // what `taggerLeft` actually ends with rather than an assumption about
    // which. Whitespace already there, from either side, means the tagger has
    // its separator and the second reading would merely double it.
    if isScreenDerived, let lastLeft = taggerLeft.last, !lastLeft.isWhitespace {
      let separated = taggerLeft + " "
      if let refusal = oracle.mayLower(
        word: bare, left: separated, payload: String(stripped), languageCode: languageCode)
      {
        return (text, .caseSkipped(refusal))
      }
    }

    // German inverts the rule: every noun is capitalised, so a positively
    // identified noun keeps its capital.
    //
    // A VETO, never a decider. Everything above has already decided to lower;
    // this can only withdraw that. #1803's rejected design made word class the
    // DECIDER plus a safe-tag allowlist, which lowered nominalised adverbs and
    // pronouns. As a conjunction it cannot introduce a damage class the rule did
    // not already have. Measured 127 wrong to 22 on the tuned split; on the clean
    // dev holdout the BUILT code lowers 1,547 German seams correctly and 7 wrongly
    // (0.30%), taking German from 22.0% to 88.5% end-state accuracy. An earlier
    // 91-to-9 figure here was the PROBE's, and the probe reimplemented part of the
    // chain (issue-1922-artifacts/2026-08-05-shipfloor-dev.out).
    //
    // The dictation ALONE, never the surrounding document: #1803 measured that
    // adding the document flipped `Morgen` from adverb to noun. And the top tag,
    // not `tagHypotheses` — that was #1803's prescribed fix and it is byte-
    // identical here, because noun carries weight only when noun already wins.
    if policy.nounVeto, oracle.isNoun(String(stripped)) {
      return (text, .caseSkipped(.nounInNounCapitalisingLanguage))
    }

    return (loweringLeadingUnit(of: text, languageCode: languageCode), .lowercasedFirst)
  }

  /// Is `bare` a Dutch word opening with the `IJ` digraph?
  ///
  /// Deliberately ASCII `I`+`J` and Dutch only. Widening either axis breaks
  /// acronym protection somewhere: any-language would forgive `IT`, and
  /// any-second-capital would forgive `USA`.
  static func isDutchIJDigraph(_ bare: String, _ languageCode: String?) -> Bool {
    guard languageCode == "nl" else { return false }
    var it = bare.makeIterator()
    guard it.next() == "I", it.next() == "J" else { return false }
    // Only the `J` is forgiven — anything uppercase after it is still an acronym.
    return !bare.dropFirst(2).contains(where: \.isUppercase)
  }

  /// Lowercase the leading CASING UNIT, which is not always one character.
  ///
  /// Two things the old `String(firstCharacter).lowercased()` got wrong, both
  /// latent until #1922 made Turkish and Dutch reachable, both measured in
  /// `2026-08-05-lowering-locale-probe.swift`:
  ///
  /// - **Locale.** `lowercased()` uses the root locale, so Turkish `I` becomes
  ///   `i` when it must become `ı`.
  /// - **Unit length.** Dutch `IJ` is one casing unit spelled with two
  ///   characters, so lowering only the first yields `iJs`. A locale argument
  ///   does NOT fix this — measured, `lowercased(with: nl)` also returns `iJs`.
  /// The one locale authority for this file.
  ///
  /// Extracted because TWO places lowercase and both must agree: the text we
  /// WRITE, and the word we ASK THE DICTIONARY ABOUT. Whole-diff review found
  /// them disagreeing — the query used the root locale, so Turkish `Işık` was
  /// looked up as `işık` instead of `ışık`, the Turkish dictionary rejected an
  /// ordinary word, and the capital was kept. That fails safe and costs recall,
  /// which is why no test caught it.
  static func casingLocale(for languageCode: String?) -> Locale {
    Locale(identifier: languageCode ?? "en")
  }

  static func loweringLeadingUnit(of text: String, languageCode: String?) -> String {
    let leadingWhitespace = text.prefix(while: \.isWhitespace)
    let stripped = text.dropFirst(leadingWhitespace.count)
    guard let firstCharacter = stripped.first else { return text }
    let locale = casingLocale(for: languageCode)

    // Dutch digraph: two characters in, two characters out.
    if languageCode == "nl", stripped.count >= 2 {
      let second = stripped[stripped.index(after: stripped.startIndex)]
      if firstCharacter == "I", second == "J" {
        return String(leadingWhitespace) + "ij" + String(stripped.dropFirst(2))
      }
    }
    let lowered = String(firstCharacter).lowercased(with: locale)
    return String(leadingWhitespace) + lowered + String(stripped.dropFirst())
  }

  // MARK: - Seam de-duplication (#1803)

  /// Whitespace that is NOT a line break.
  ///
  /// Swift counts `\n` as whitespace, and both the casing rule and the anchor
  /// walk use the bare `isWhitespace`. An unqualified "whitespace" contract here
  /// would let `the` + `The\nstore` delete the word AND the newline, welding two
  /// lines together — so every whitespace decision in this rule is horizontal.
  static func isHorizontalWhitespace(_ character: Character) -> Bool {
    character.isWhitespace && !character.isNewline
  }

  /// A token with its edge connectors removed, or `nil` when nothing well-formed
  /// survives.
  ///
  /// `wordConnectors` may only sit INSIDE a token: `can't` and
  /// `state-of-the-art` are one token each, while the trailing apostrophe of
  /// `the Joneses'` and the bullet in `- item` are not part of one.
  static func normalizedToken(_ raw: String) -> String? {
    var characters = Array(raw)
    while let first = characters.first, wordConnectors.contains(first) {
      characters.removeFirst()
    }
    while let last = characters.last, wordConnectors.contains(last) {
      characters.removeLast()
    }
    guard let first = characters.first, let last = characters.last,
      first.isLetter || first.isNumber, last.isLetter || last.isNumber
    else { return nil }
    return String(characters)
  }

  /// Two tokens are the same word, ignoring case and apostrophe shape.
  ///
  /// Case-insensitive because the duplicate IS a capitalisation mismatch, and
  /// apostrophe-folded because cloud polish emits `U+2019` while a typed
  /// document holds `U+0027`.
  static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
    normalizeApostrophes(lhs).lowercased()
      == normalizeApostrophes(rhs).lowercased()
  }

  /// The complete token immediately left of the caret, or `nil`.
  ///
  /// Returns `nil` when completeness cannot be PROVEN. The left window is
  /// bounded (20 UTF-16 units), so a backward scan that consumes the whole
  /// window may be holding the tail of a longer word — comparing that would
  /// match a suffix and delete a word on the strength of it.
  ///
  /// `reachesDocumentStart` is the one piece of evidence the string itself
  /// cannot carry: a window that starts at document offset 0 was never cut, so a
  /// token touching its start IS complete. Everything else fails in the safe
  /// direction — a missed duplicate, never an invented deletion.
  static func completeLeftToken(in window: String, reachesDocumentStart: Bool) -> String? {
    var cursor = window.endIndex
    // Reach the anchor. A newline is a boundary, not a separator to cross.
    while cursor > window.startIndex {
      let previous = window.index(before: cursor)
      let character = window[previous]
      if character.isNewline { return nil }
      guard isHorizontalWhitespace(character) else { break }
      cursor = previous
    }
    let end = cursor
    guard end > window.startIndex else { return nil }

    var start = end
    while start > window.startIndex {
      let previous = window.index(before: start)
      let character = window[previous]
      guard character.isLetter || character.isNumber || wordConnectors.contains(character)
      else { break }
      start = previous
    }
    // The scan ran out of window instead of meeting a boundary. That is only
    // ambiguous when the window was CUT: a window that begins at the document's
    // own start has no hidden prefix, so the token is complete. Without this the
    // rule refused every short field — document `the ` plus payload
    // `The store...` is a common Slack or search-box case (local diff review).
    guard start > window.startIndex || reachesDocumentStart else { return nil }
    return normalizedToken(String(window[start..<end]))
  }

  /// Remove the payload's leading token when it duplicates `leftToken`.
  ///
  /// Returns `nil` — meaning refuse — unless the payload opens with exactly one
  /// complete token followed by a non-empty run of horizontal whitespace. A
  /// payload opening with a quote or bracket, or whose token is followed by
  /// punctuation rather than a space, is left alone rather than deleted with
  /// dangling punctuation left behind.
  ///
  /// `documentOwnsSeparator` settles which side supplies the seam space. Rule 1
  /// declines to add one when the payload already begins with whitespace, so
  /// with `crossedSpace` true AND a polish payload carrying its own leading
  /// space, both sides supply one and keeping both emits a double space
  /// (grounded review r2). Exactly one side wins, never both.
  static func dropDuplicateSeamToken(
    from text: String,
    leftToken: String,
    documentOwnsSeparator: Bool
  ) -> String? {
    var index = text.startIndex
    while index < text.endIndex, isHorizontalWhitespace(text[index]) {
      index = text.index(after: index)
    }
    let leadingWhitespace = text[text.startIndex..<index]
    // A payload that starts on its own line is not continuing this one.
    guard index < text.endIndex, !text[index].isNewline else { return nil }

    let tokenStart = index
    while index < text.endIndex,
      text[index].isLetter || text[index].isNumber || wordConnectors.contains(text[index])
    {
      index = text.index(after: index)
    }
    let rawToken = String(text[tokenStart..<index])
    guard let token = normalizedToken(rawToken), token.count == rawToken.count else {
      // A trimmed edge connector means the payload opened with punctuation that
      // deletion would strand. Refuse rather than guess.
      return nil
    }
    guard tokensMatch(token, leftToken) else { return nil }

    // The token must be followed by a real separator, so `The` alone and
    // `The, store` both refuse.
    guard index < text.endIndex, isHorizontalWhitespace(text[index]) else { return nil }
    while index < text.endIndex, isHorizontalWhitespace(text[index]) {
      index = text.index(after: index)
    }
    // The ENTIRE separator must be horizontal, not just its first character.
    // `The \nstore` passes the guard above on the space, and this loop then
    // stops AT the newline — so without this the token would be deleted across
    // a line break, which is precisely what the newline refusal exists to
    // prevent (cloud review, PR #1804).
    guard index < text.endIndex, !text[index].isNewline else { return nil }

    // Never empty the user's dictation. This is the guard the deleted
    // terminal-period rule never had.
    let remainder = text[index...]
    guard remainder.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

    return (documentOwnsSeparator ? "" : String(leadingWhitespace)) + String(remainder)
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

  /// Characters that join one word rather than separating two.
  ///
  /// ENUMERATED rather than grown one reviewer finding at a time: r1 added the
  /// apostrophe and hyphen, r6 then found the underscore, which is the same
  /// class arriving twice. The complete set, and what is deliberately outside it:
  ///
  /// | Character | In | Why |
  /// |---|---|---|
  /// | `'` `’` | yes | `can't`, `Jones's` — straight and curly both occur, cloud polish emits curly |
  /// | `-` `‐` `‑` | yes | `state-of-the-art`, plus the Unicode and non-breaking hyphens |
  /// | `_` | yes | `foo_bar` — dictation into code editors is a real target |
  /// | `.` | NO | a period is also a sentence boundary; treating it as word-internal
  ///   would make `home.Next` unrepairable, and the dotted-initialism case it
  ///   would serve is handled by `endsWithAbbreviation` instead |
  /// | `/` `,` `:` | NO | these separate; `and/or` splitting is not corruption |
  static let wordConnectors: Set<Character> = [
    "'", "\u{2019}", "-", "\u{2010}", "\u{2011}", "_",
  ]

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
    let normalized = normalizeApostrophes(word)
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
      if character.isNewline {
        return LeftAnchor(
          character: nil, crossedSpace: crossed, atLineStart: true, isOpener: false)
      }
      // ANY whitespace, not just the two ASCII ones. A non-breaking space is
      // ordinary in text copied from a web page, and treating it as a real
      // character made it an anchor — so the repair added a SECOND separator
      // beside it (Codex review r5). The newline check runs first because a line
      // break is a boundary, not a separator to skip over.
      if character.isWhitespace {
        crossed = true
        continue
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
}

/// Fold the Unicode right single quote to the ASCII apostrophe.
///
/// NOT word knowledge — pure punctuation normalisation, which is why it
/// outlives `OrdinaryLowercaseLexicon`. Two consumers shipped in PR #1804 still
/// need it: seam de-duplication compares tokens with it, and the pronoun-`I`
/// guard normalises before matching. Cloud polish providers emit `U+2019`.
func normalizeApostrophes(_ text: String) -> String {
  text.replacingOccurrences(of: "\u{2019}", with: "'")
}
