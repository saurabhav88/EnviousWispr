import Foundation

// MARK: - The ordinal pass (#1677, PR 2 chunk 5)
//
// ONE pure pass: where a spoken ordinal word (German `dritte`, `zwölften`, `einundzwanzigste`)
// stands before a word it may modify, propose an edit that replaces ONLY the ordinal span with its
// digits and the written suffix (`3.`). External whitespace, articles, following words and
// punctuation stay as written. The pass proposes edits against one immutable snapshot; the shared
// editor applies them. Nothing registers or calls this pass yet.
//
// CANDIDATES: an ordinal the shared parser admits (values 1 to 31 in the base, -n and -r spellings,
// licensed spaced compounds), a reviewed adverb token (`erstens`), or a reviewed literal phrase
// (`ein drittel`). Adverbs and fraction phrases are matched explicitly from the reviewed data; they
// are not ordinals and never convert.
//
// CONTEXT, with three outcomes per predicate (applies, does not apply, unknown):
//  - without a following noun: STRUCTURAL. A capitalized alphabetic word that is not protected must
//    follow across horizontal whitespace, with no punctuation on the ordinal. This is a necessary
//    admission marker, not proof that the word is a noun.
//  - date, fixed expression: AUTHORITY DEPENDENT. The reviewed entries name no months and no fixed
//    phrases, and no German authority is wired in, so without evidence these are UNKNOWN and an
//    ordinal that depends on them is reported `unavailable`, never converted.
//  - proper name or title: CONSERVATIVE. A capitalized ordinal inside a sentence is withheld. This
//    is orthography, not a name classifier; a lowercase ordinal stays unknown unless the rules carry
//    a clearance.
// An unknown required predicate prevents conversion. `unavailable` is not a refusal and not a
// success; it says which context is missing.
//
// This is not a German grammar and not a part-of-speech classifier. It keeps no month, noun, article
// or name list.

struct LanguageOrdinalPass: Sendable {

  let grammar: LanguageNumberGrammar
  let rules: LanguageOrdinalRules

  init(grammar: LanguageNumberGrammar, rules: LanguageOrdinalRules) {
    self.grammar = grammar
    self.rules = rules
  }

  /// A context an ordinal depends on and that the rules cannot answer.
  enum MissingContext: Sendable, Equatable {
    case calendarAuthority
    case fixedPhraseAuthority
    case properNameClearance
  }

  /// An implemented refusal or a conservative withhold. The first case carries the reviewed entry id.
  enum Refusal: Sendable, Equatable {
    case adverbToken(entry: String)
    case literalPhrase(entry: String)
    case dateContext
    case fixedExpression
    case withoutFollowingNoun
    /// A capitalized ordinal inside a sentence: withheld conservatively, not classified.
    case capitalizedOrdinal
    /// A number component precedes this window: it may be a suffix of a failed compound, so it
    /// cannot be admitted independently.
    case numberContinuationBefore
    case editRefused(LanguageEditRefusal)
  }

  enum Disposition: Sendable, Equatable {
    case proposed(LanguageTextEdit)
    case refused(Refusal)
    /// The ordinal parsed but a required context predicate is unknown: nothing is converted.
    case unavailable([MissingContext])
  }

  struct Candidate: Sendable, Equatable {
    /// The candidate's UTF-16 range in the original text (words only, no punctuation).
    let range: Range<Int>
    /// The parsed value for an ordinal candidate; nil for an adverb or a fraction phrase.
    let value: Int?
    let disposition: Disposition
  }

  struct Run: Sendable, Equatable {
    let edits: [LanguageTextEdit]
    let candidates: [Candidate]
    let candidatesTruncated: Bool

    static let diagnosticLimit = 64
  }

  enum Outcome: Sendable, Equatable {
    case ran(Run)
    /// The rules cannot be interpreted safely: no pass ran and nothing was proposed.
    case unavailable(String)
  }

  // MARK: Entry

  func propose(in snapshot: LanguageTextSnapshot) -> Outcome {
    for shape in LanguageOrdinalRules.Shape.allCases where rules.tokens(for: shape) == nil {
      return .unavailable("reviewed shape \(shape.rawValue) is missing")
    }
    guard !rules.writtenSuffix.isEmpty, !rules.literalPhrases.isEmpty else {
      return .unavailable("no written suffix or no reviewed phrase entry")
    }
    let words = Self.words(of: LanguageProtectedSpans.chunks(of: snapshot.text))
    let protected = LanguageProtectedSpans.collect(in: snapshot)
    let parser = LanguageNumberParser(grammar: grammar)
    let phrases = rules.literalPhrases.sorted { $0.count > $1.count }
    let adverbs = Set(rules.tokens(for: .ordinalAdverb) ?? [])

    var edits: [LanguageTextEdit] = []
    var candidates: [Candidate] = []
    var truncated = false
    var index = 0
    while index < words.count {
      var consumed = 0
      var candidate: Candidate?

      if let phrase = phrases.first(where: { matches(phrase: $0, at: index, in: words) }) {
        consumed = phrase.count
        let range = words[index].start..<words[index + consumed - 1].end
        let entry = entryID(forPhrase: phrase)
        candidate = Candidate(
          range: range, value: nil, disposition: .refused(.literalPhrase(entry: entry)))
      } else if adverbs.contains(words[index].folded) {
        consumed = 1
        let entry = rules.refusalID(for: .ordinalAdverb) ?? ""
        candidate = Candidate(
          range: words[index].start..<words[index].end, value: nil,
          disposition: .refused(.adverbToken(entry: entry)))
      } else {
        for width in stride(from: min(3, words.count - index), through: 1, by: -1) {
          guard windowIsContiguous(words, from: index, width: width) else { continue }
          let range = words[index].start..<words[index + width - 1].end
          if case .parsed(let number) = parser.parse(.ordinal, in: snapshot, range: range) {
            consumed = width
            if hasNumberContinuationBefore(index, in: words) {
              candidate = refuse(range, number.value, .numberContinuationBefore)
            } else {
              candidate = decide(
                range: range, value: number.value, first: index, last: index + width - 1,
                words: words, snapshot: snapshot, protected: protected)
            }
            break
          }
        }
      }

      guard let found = candidate, consumed > 0 else {
        index += 1
        continue
      }
      if case .proposed(let edit) = found.disposition { edits.append(edit) }
      if candidates.count < Run.diagnosticLimit {
        candidates.append(found)
      } else {
        truncated = true
      }
      index += consumed
    }
    return .ran(Run(edits: edits, candidates: candidates, candidatesTruncated: truncated))
  }

  // MARK: Words

  /// One chunk reduced to its word: the range and text without opening or closing punctuation.
  struct Word {
    let start: Int
    let end: Int
    let text: String
    let folded: String
    let chunkRange: Range<Int>
    let hasLeadingPunctuation: Bool
    let hasTrailingPunctuation: Bool
    let gapAfterIsHorizontal: Bool
    let chunkText: String
  }

  private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«„“‘")
  private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'»”’“‘")

  static func words(of chunks: [LanguageProtectedSpans.Chunk]) -> [Word] {
    chunks.map { chunk in
      var scalars = Array(chunk.text.unicodeScalars)
      var lead = 0
      var trail = 0
      while let first = scalars.first, openingPunctuation.contains(first) {
        lead += first.value > 0xFFFF ? 2 : 1
        scalars.removeFirst()
      }
      while let last = scalars.last, closingPunctuation.contains(last) {
        trail += last.value > 0xFFFF ? 2 : 1
        scalars.removeLast()
      }
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars)
      let text = String(view)
      return Word(
        start: chunk.range.lowerBound + lead, end: chunk.range.upperBound - trail, text: text,
        folded: LanguageNumberGrammar.fold(text), chunkRange: chunk.range,
        hasLeadingPunctuation: lead > 0, hasTrailingPunctuation: trail > 0,
        gapAfterIsHorizontal: chunk.gapAfterIsHorizontal, chunkText: chunk.text)
    }
  }

  /// Uses only the grammar's existing components and licensed joints. A line break does not make a
  /// failed compound's suffix independent. Bare article forms remain articles, not number evidence.
  private func hasNumberContinuationBefore(_ index: Int, in words: [Word]) -> Bool {
    guard index > 0, !words[index].hasLeadingPunctuation else { return false }
    let previous = words[index - 1]
    guard !previous.hasTrailingPunctuation, !previous.folded.isEmpty else { return false }

    let key = previous.folded
    guard !grammar.nonStandalone.contains(key) else { return false }

    if key == grammar.connector
      || grammar.standalone[key] != nil
      || grammar.compoundUnits[key] != nil
      || grammar.tens[key] != nil
      || grammar.ordinalForms[key] != nil
    {
      return true
    }
    if previous.text.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
      return true
    }
    for (spelling, form) in grammar.ordinalForms {
      let scalars = Array(spelling.unicodeScalars)
      for joint in form.joints {
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars.prefix(joint))
        if String(prefix) == key { return true }
      }
    }
    return false
  }

  /// Consecutive words joined by horizontal whitespace only, with punctuation only at the outer
  /// edges of the window.
  private func windowIsContiguous(_ words: [Word], from first: Int, width: Int) -> Bool {
    guard first + width <= words.count else { return false }
    for offset in 0..<width {
      let word = words[first + offset]
      if word.text.isEmpty { return false }
      if offset > 0, word.hasLeadingPunctuation { return false }
      if offset < width - 1 {
        if word.hasTrailingPunctuation || !word.gapAfterIsHorizontal { return false }
      }
    }
    return true
  }

  private func matches(phrase: [String], at index: Int, in words: [Word]) -> Bool {
    guard windowIsContiguous(words, from: index, width: phrase.count) else { return false }
    for (offset, token) in phrase.enumerated() where words[index + offset].folded != token {
      return false
    }
    return true
  }

  private func entryID(forPhrase phrase: [String]) -> String {
    rules.refusals.first {
      if case .literalPhrases(let phrases) = $0.matcher { return phrases.contains(phrase) }
      return false
    }?.id ?? ""
  }

  // MARK: Decision

  /// The three outcomes of a required context predicate.
  private enum Answer {
    case applies
    case doesNotApply
    case unknown
  }

  private func decide(
    range: Range<Int>, value: Int, first: Int, last: Int, words: [Word],
    snapshot: LanguageTextSnapshot, protected: [LanguageProtectedSpan]
  ) -> Candidate {
    let following = followingWord(after: last, words: words, protected: protected)
    let ordinal = words[first]
    let capitalized = ordinal.text.unicodeScalars.first?.properties.isUppercase ?? false
    let sentenceInitial = isSentenceInitial(first, words: words)

    // Exhaustive over the reviewed shapes, in reviewed order: the first that applies names the
    // refusal; any that is unknown is collected; conversion needs every answer to be "does not apply".
    var unknown: [MissingContext] = []
    for shape in LanguageOrdinalRules.Shape.allCases {
      switch answer(
        shape, following: following, capitalized: capitalized, sentenceInitial: sentenceInitial)
      {
      case .doesNotApply: continue
      case .applies: return refuse(range, value, refusal(for: shape))
      case .unknown:
        guard let missing = missingContext(for: shape) else { return failClosed(range, value) }
        unknown.append(missing)
      }
    }
    if !unknown.isEmpty {
      return Candidate(range: range, value: value, disposition: .unavailable(unknown))
    }
    switch snapshot.edit(replacing: range, with: "\(value)" + rules.writtenSuffix) {
    case .success(let edit): return Candidate(range: range, value: value, disposition: .proposed(edit))
    case .failure(let refusal): return refuse(range, value, .editRefused(refusal))
    }
  }

  private func answer(
    _ shape: LanguageOrdinalRules.Shape, following: Word?, capitalized: Bool, sentenceInitial: Bool
  ) -> Answer {
    let evidence = rules.evidence
    switch shape {
    case .ordinalAdverb:
      // A candidate that parsed as an ordinal is not one of the reviewed adverb tokens.
      return .doesNotApply
    case .dateContext:
      return authorityAnswer(evidence.calendarWords, following: following)
    case .fixedExpression:
      return authorityAnswer(evidence.fixedPhraseNouns, following: following)
    case .withoutFollowingNoun:
      return following == nil ? .applies : .doesNotApply
    case .properName:
      if capitalized && !sentenceInitial { return .applies }
      if !capitalized, evidence.properNameClearance == .lowercaseAdjectiveOrthography {
        return .doesNotApply
      }
      return .unknown
    }
  }

  private func refusal(for shape: LanguageOrdinalRules.Shape) -> Refusal {
    switch shape {
    case .ordinalAdverb: return .adverbToken(entry: rules.refusalID(for: shape) ?? "")
    case .dateContext: return .dateContext
    case .fixedExpression: return .fixedExpression
    case .withoutFollowingNoun: return .withoutFollowingNoun
    case .properName: return .capitalizedOrdinal
    }
  }

  /// The context a shape needs when it is unknown. Shapes that can never be unknown have none.
  private func missingContext(for shape: LanguageOrdinalRules.Shape) -> MissingContext? {
    switch shape {
    case .dateContext: return .calendarAuthority
    case .fixedExpression: return .fixedPhraseAuthority
    case .properName: return .properNameClearance
    case .ordinalAdverb, .withoutFollowingNoun: return nil
    }
  }

  private func refuse(_ range: Range<Int>, _ value: Int, _ refusal: Refusal) -> Candidate {
    Candidate(range: range, value: value, disposition: .refused(refusal))
  }

  /// A predicate the dispatch does not know: nothing is converted.
  private func failClosed(_ range: Range<Int>, _ value: Int) -> Candidate {
    Candidate(range: range, value: value, disposition: .unavailable([.properNameClearance]))
  }

  /// The word that follows the ordinal, only when it can stand as its modified word: a capitalized
  /// alphabetic word, not protected, reached across horizontal whitespace with no punctuation on
  /// the ordinal. Anything else (missing, lowercase, numeric, protected, separated) is nil.
  private func followingWord(after last: Int, words: [Word], protected: [LanguageProtectedSpan])
    -> Word?
  {
    let ordinal = words[last]
    guard !ordinal.hasTrailingPunctuation, ordinal.gapAfterIsHorizontal, last + 1 < words.count
    else { return nil }
    let next = words[last + 1]
    guard !next.hasLeadingPunctuation, let firstScalar = next.text.unicodeScalars.first,
      firstScalar.properties.isUppercase,
      next.text.unicodeScalars.allSatisfy({
        $0.properties.isAlphabetic || $0 == "-" || $0.properties.generalCategory == .nonspacingMark
      }),
      LanguageProtectedSpans.firstIntersecting(next.chunkRange, in: protected) == nil
    else { return nil }
    return next
  }

  /// With an authority: the following word is in the set (applies) or not (does not apply).
  /// Without one: unknown.
  private func authorityAnswer(_ authority: Set<String>?, following: Word?) -> Answer {
    guard let authority else { return .unknown }
    guard let following else { return .doesNotApply }
    return authority.contains(following.folded) ? .applies : .doesNotApply
  }

  /// True at the start of the text, after a line break, or after a sentence-ending mark.
  private func isSentenceInitial(_ index: Int, words: [Word]) -> Bool {
    guard index > 0 else { return true }
    let previous = words[index - 1]
    if !previous.gapAfterIsHorizontal { return true }
    var scalars = Array(previous.chunkText.unicodeScalars)
    while let last = scalars.last, ")]}\"'»”’“‘".unicodeScalars.contains(last) {
      scalars.removeLast()
    }
    guard let last = scalars.last else { return false }
    return last == "." || last == "!" || last == "?"
  }
}
