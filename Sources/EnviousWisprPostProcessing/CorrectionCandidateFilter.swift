import EnviousWisprCore
import Foundation

// MARK: - Candidate filter and state assignment (#996 §3.1 step 6)
//
// Pure: takes the live word list and the enabled pack terms AS VALUES and
// returns one disposition per aligned run. It never reads a store, never
// mutates a word, and never decides whether an edit IS a correction: that is
// the judge's question (step 7). The App coordinator saves the accepted
// candidates at once (2026-09-21 plan §3.1 step 8). There is no rejection
// memory: a pair the user undid may be learned again (founder 2026-09-21,
// Wispr Flow's shape).

/// What the corrected spelling resolves to among the live words: the
/// candidate's payload, so the coordinator and telemetry name the same
/// state the filter saw.
package enum LearnTargetState: Sendable, Equatable {
  /// A user word or enabled pack term carries the corrected canonical.
  case existingWord(UUID)
  case newWord
}

package enum CorrectionCandidateFilter {

  /// Why a run is not sent to the judge. Each is a counted skip token.
  package enum IneligibleReason: String, Sendable, Equatable, CaseIterable {
    /// Every edited token is a stopword (`WordCorrector.stopwords`).
    case stopwordPhrase
    /// The corrected run ends in a contraction suffix ("it's", "don't").
    case contractionEnding
    /// The corrected run is the original with letters deleted and nothing
    /// typed, two or more of them from one place: an edit caught half-way
    /// ("do fewer words" -> "drds", "Sorat" -> "S", #3105). A join that
    /// removes only spaces is not this, nor single letters removed in
    /// separate places ("Whisper" -> "Wispr", #3949).
    case unfinishedEdit
    /// The run only writes one number word as the same number in digits
    /// ("two" -> "2", "fourth" -> "4th", German "zwei" -> "2"): formatting,
    /// not a misheard word, and the learned entry would be bare digits (#3969).
    case numberFormatting
    /// The corrected phrase, or the original as a trigger, is owned by a
    /// DIFFERENT word than the resolved target.
    case aliasOwnedElsewhere
  }

  /// Plan §3.1 step 6 dispositions. Precedence when several apply (highest
  /// first): `ineligible(.stopwordPhrase)`, `ineligible(.contractionEnding)`,
  /// `ineligible(.unfinishedEdit)`, `ineligible(.numberFormatting)`,
  /// `alreadyCovered`, `ineligible(.aliasOwnedElsewhere)`, `candidate`. A
  /// covered pair is never sent to the judge.
  package enum Disposition: Sendable, Equatable {
    case ineligible(IneligibleReason)
    /// The intended live target already carries the original as its
    /// canonical or as a sound-alike; dropped before judging.
    case alreadyCovered
    /// Send to the judge; if it says correction, save with this state.
    case candidate(LearnTargetState)
  }

  /// Everything step 6 reads, as values: the live words and nothing else.
  package struct Inputs: Sendable {
    package let userWords: [CustomWord]
    /// Terms of the ENABLED packs only (`source == .pack`).
    package let packTerms: [CustomWord]

    package init(userWords: [CustomWord], packTerms: [CustomWord]) {
      self.userWords = userWords
      self.packTerms = packTerms
    }
  }

  /// One run's answer, with the evidence the judge request may carry.
  package struct Filtered: Sendable, Equatable {
    package let run: EditAlignment.Run
    package let pairKey: String
    package let disposition: Disposition
    /// `WordCorrector.score` of the original against the corrected run when
    /// the run is a `candidate`, both sides are Latin script and within
    /// `maxSimilarityChars`; `nil` means "no evidence", never zero. Optional
    /// local advisory evidence: it never affects a disposition, it does not
    /// reach `CorrectionJudgeRequest` (which has no evidence field), and this
    /// chunk authorises no consumer to invent a threshold for it; any later
    /// use must name its consumer and governing policy.
    package let similarity: Double?
  }

  /// Runs the judge will be asked about, in the plan's order (capitalised
  /// first, source order for ties), capped at `CorrectionJudgeRequest.maxCandidates`,
  /// with request ids assigned 1... only after the cap.
  package struct Prepared: Sendable, Equatable {
    package let candidates: [CorrectionCandidate]
    /// The filtered entry behind each request id.
    package let byID: [Int: Filtered]
    /// Eligible candidates that did not fit the cap, in the order they lost.
    package let overflow: [Filtered]
  }

  package static let contractionSuffixes = ["'s", "'t", "'re", "'ll", "'ve", "'d", "'m"]
  /// Character-level similarity is quadratic in the run length; four words
  /// can still be arbitrarily long, so a side over this is "no evidence".
  package static let maxSimilarityChars = 200

  // MARK: - Dispositions

  package static func filter(runs: [EditAlignment.Run], inputs: Inputs) -> [Filtered] {
    let index = WordCorrector.buildExactTriggerIndex(words: inputs.userWords + inputs.packTerms)
    return runs.map { run in
      let key = CorrectionPairKey.make(original: run.coreOriginal, corrected: run.coreReplacement)
      let disposition = dispose(run: run, inputs: inputs, index: index)
      // Evidence is computed only where it can be used: an ineligible run
      // never pays for a character-level comparison.
      var evidence: Double? = nil
      if case .candidate = disposition { evidence = similarity(run) }
      return Filtered(run: run, pairKey: key, disposition: disposition, similarity: evidence)
    }
  }

  private static func dispose(
    run: EditAlignment.Run, inputs: Inputs, index: WordCorrector.ExactTriggerIndex
  ) -> Disposition {
    let editedTokens = InverseTextNormalizer.splitWords(run.coreReplacement).map(normalisedToken)
    if !editedTokens.isEmpty, editedTokens.allSatisfy({ WordCorrector.stopwords.contains($0) }) {
      return .ineligible(.stopwordPhrase)
    }
    if hasContractionEnding(run.coreReplacement) { return .ineligible(.contractionEnding) }
    if isDeletionOnly(original: run.coreOriginal, corrected: run.coreReplacement) {
      return .ineligible(.unfinishedEdit)
    }
    if isNumberFormatting(run) { return .ineligible(.numberFormatting) }

    let target = resolveTarget(corrected: run.coreReplacement, inputs: inputs)
    if let target, covers(target, original: run.coreOriginal) { return .alreadyCovered }
    if ownedElsewhere(run: run, target: target, index: index) {
      return .ineligible(.aliasOwnedElsewhere)
    }
    if let target { return .candidate(.existingWord(target.id)) }
    return .candidate(.newWord)
  }

  /// #3105: the corrected text is the original with at least two letters
  /// removed and nothing added (a case-insensitive subsequence), and every
  /// way to read it removes two or more letters from one place. The junk
  /// the judge learned was a half-finished backspace ("test experience" ->
  /// "texperience"); real corrections type new letters ("day toast" ->
  /// "Tuist") or remove single letters in separate places ("Whisper Eyes" ->
  /// "WisprEyes", "Flicker" -> "Flickr", #3949, founder 2026-10-19). Some
  /// unfinished backspaces also admit that reading ("letter" -> "letr" removes
  /// "te" in one place, or `t` and `e` apart); the judge decides those. Runs
  /// longer than `maxSimilarityChars` keep the #3105 answer, since the
  /// alignment search is quadratic. This is a shape rule, so it holds on every
  /// settle path: a fix sent with Enter or left with the caret beside it
  /// still reaches the judge. A join that only removes spaces ("Pay Pal" ->
  /// "PayPal") is left to the judge (the join-only rule in the #3105 plan:
  /// a join cannot be told from junk by shape).
  package static func isDeletionOnly(original: String, corrected: String) -> Bool {
    let o = Array(original.lowercased())
    let c = Array(corrected.lowercased())
    guard c.count < o.count else { return false }
    // Fewer than two LETTERS removed is a real fix the recogniser padded
    // ("adiane" -> "Adian", "Johnson's" -> "Johnson"), not an edit abandoned
    // half-way. Accepted residual (Codex PR-1 review P2, hypothetical): a
    // completed fix that deletes two or more letters from one place
    // ("microphoness" -> "microphone") is not learned; the recogniser was not
    // seen to pad a word with two junk letters, and the #3105 junk this stops
    // was.
    let removedLetters = o.filter(\.isLetter).count - c.filter(\.isLetter).count
    guard removedLetters >= 2 else { return false }
    var i = 0
    for ch in o where i < c.count && ch == c[i] { i += 1 }
    guard i == c.count else { return false }
    guard o.count <= maxSimilarityChars else { return true }
    // Accepted residual (#3949): two one-letter trims in one run ("cats dogs"
    // -> "cat dog") and two one-letter half-edits now reach the judge too.
    return !canRemoveOnlySeparateSingleLetters(original: o, corrected: c)
  }

  /// True when `corrected` is a subsequence of `original` under at least one
  /// alignment where every removed stretch (between two kept characters)
  /// holds at most one letter; removed spaces and punctuation do not count.
  /// Every alignment is searched, not only the first left-to-right match:
  /// "baab" -> "ba" scatters by keeping the second `a`. False when `corrected`
  /// is not a subsequence at all.
  static func canRemoveOnlySeparateSingleLetters(
    original o: [Character], corrected c: [Character]
  ) -> Bool {
    // reach[j][k]: after some prefix of `o`, `j` characters of `c` are kept
    // and the open removed stretch holds `k` letters (0 or 1).
    var reach = Array(repeating: [false, false], count: c.count + 1)
    reach[0][0] = true
    for ch in o {
      var next = Array(repeating: [false, false], count: c.count + 1)
      for j in 0...c.count {
        for k in 0...1 where reach[j][k] {
          if j < c.count, ch == c[j] { next[j + 1][0] = true }
          let letters = k + (ch.isLetter ? 1 : 0)
          if letters < 2 { next[j][letters] = true }
        }
      }
      reach = next
    }
    return reach[c.count][0] || reach[c.count][1]
  }

  /// One number, read two ways: a count or a rank.
  enum NumberForm: Hashable {
    case cardinal(Int)
    case ordinal(Int)
  }

  /// #3969: the run writes ONE number word as the same number in digits. The
  /// formatter already writes 10 and up, decimals and money as digits and
  /// keeps one to nine as words, so this is the user's own style choice
  /// ("two" -> "2"), never a misheard word. Both SURFACE strings are checked
  /// before anything else: the lexical core strips edge marks, so "one" ->
  /// "-1" or "ten" -> "10%" would otherwise look like plain formatting. A sign,
  /// unit, bracket, space or second number keeps the run with the judge.
  /// Accepted trade-off: a name spoken as one number word and written as
  /// digits only ("One" -> "1") is not learned; its entry would be bare digits.
  package static func isNumberFormatting(_ run: EditAlignment.Run) -> Bool {
    let original = withoutSentenceDecoration(run.original)
    let replacement = withoutSentenceDecoration(run.replacement)
    guard isLettersOnlyPhrase(original), let digits = digitNumber(replacement) else { return false }
    return numberWordReadings(original).contains(digits)
  }

  /// Trailing sentence punctuation and enclosing quotation marks only.
  /// Brackets stay: "(1)" can mean minus one.
  static func withoutSentenceDecoration(_ text: String) -> String {
    var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let trailing: Set<Character> = [".", ",", ";", ":", "!", "?"]
    let quotes: Set<Character> = [
      "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{00AB}", "\u{00BB}",
    ]
    var changed = true
    while changed {
      changed = false
      if let last = s.last, trailing.contains(last) || quotes.contains(last) {
        s = s.dropLast()
        changed = true
      }
      if let first = s.first, quotes.contains(first) {
        s = s.dropFirst()
        changed = true
      }
    }
    return String(s)
  }

  /// Letters, with single spaces or hyphens between letters; nothing else.
  static func isLettersOnlyPhrase(_ text: String) -> Bool {
    guard let first = text.first, let last = text.last, first.isLetter, last.isLetter else {
      return false
    }
    var previous: Character = first
    for ch in text {
      if ch == " " || ch == "-" {
        guard previous.isLetter else { return false }
      } else if !ch.isLetter {
        return false
      }
      previous = ch
    }
    return true
  }

  /// One integer in plain digits, or an English ordinal whose suffix fits it
  /// ("1st", "2nd", "3rd", "11th"). Anything else is nil.
  static func digitNumber(_ text: String) -> NumberForm? {
    let digits = text.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, digits.count <= 9, let value = Int(digits) else { return nil }
    let suffix = text.dropFirst(digits.count)
    if suffix.isEmpty { return .cardinal(value) }
    return suffix == englishOrdinalSuffix(value) ? .ordinal(value) : nil
  }

  static func englishOrdinalSuffix(_ n: Int) -> String {
    if (11...13).contains(n % 100) { return "th" }
    switch n % 10 {
    case 1: return "st"
    case 2: return "nd"
    case 3: return "rd"
    default: return "th"
    }
  }

  /// Every way the app's own number readers read ONE word: English (the
  /// formatter's lexicon, plus a hyphenated tens compound such as
  /// "twenty-one" or "twenty-first"), German and Dutch
  /// (`LanguageNumberGrammar`, whose compounds are single words). A phrase
  /// with a space is not read: the formatter already writes those numbers as
  /// digits, and reading multi-word heads invents values ("twenty and
  /// first"), so they stay with the judge.
  static func numberWordReadings(_ word: String) -> Set<NumberForm> {
    guard !word.contains(" ") else { return [] }
    var readings: Set<NumberForm> = []
    let parts = word.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 1 {
      let w = parts[0]
      if let v = InverseTextNormalizer.units[w] ?? InverseTextNormalizer.tens[w] {
        readings.insert(.cardinal(v))
      }
      if let v = InverseTextNormalizer.ordinalWord[w] ?? InverseTextNormalizer.ordStandalone[w] {
        readings.insert(.ordinal(v))
      }
    } else if parts.count == 2, let tens = InverseTextNormalizer.tens[parts[0]] {
      if let unit = InverseTextNormalizer.units[parts[1]], (1...9).contains(unit) {
        readings.insert(.cardinal(tens + unit))
      }
      if let unit = InverseTextNormalizer.ordUnit[parts[1]] {
        readings.insert(.ordinal(tens + unit))
      }
    }
    let snapshot = LanguageTextSnapshot(word)
    let whole = 0..<snapshot.units.count
    for parser in [germanNumbers, dutchNumbers].compactMap({ $0 }) {
      if case .parsed(let n) = parser.parse(.cardinal, in: snapshot, range: whole) {
        readings.insert(.cardinal(n.value))
      }
    }
    // A German ordinal written "4." reaches here as "4": the period is
    // sentence decoration, so it counts as the plain number.
    if let parser = germanNumbers,
      case .parsed(let n) = parser.parse(.ordinal, in: snapshot, range: whole)
    {
      readings.insert(.cardinal(n.value))
    }
    return readings
  }

  static let germanNumbers: LanguageNumberParser? = {
    guard let grammar = try? LanguageNumberGrammar.forLanguage("de") else { return nil }
    return LanguageNumberParser(grammar: grammar)
  }()
  static let dutchNumbers: LanguageNumberParser? = {
    guard let grammar = try? LanguageNumberGrammar.forLanguage("nl") else { return nil }
    return LanguageNumberParser(grammar: grammar)
  }()

  /// The corrected spelling as an existing word: user words first, then the
  /// enabled pack terms, matched on the canonical case-insensitively. Returns
  /// the EXISTING record; never mints an id.
  package static func resolveTarget(corrected: String, inputs: Inputs) -> CustomWord? {
    let key = CorrectionPairKey.normalise(corrected.trimmingCharacters(in: .whitespaces))
    if let user = inputs.userWords.first(where: { CorrectionPairKey.normalise($0.canonical) == key }
    ) {
      return user
    }
    return inputs.packTerms.first { CorrectionPairKey.normalise($0.canonical) == key }
  }

  /// The target already carries the original as its canonical or as a
  /// sound-alike (case-insensitive): nothing to learn.
  static func covers(_ word: CustomWord, original: String) -> Bool {
    let key = CorrectionPairKey.normalise(original)
    if CorrectionPairKey.normalise(word.canonical) == key { return true }
    return word.aliases.contains { CorrectionPairKey.normalise($0) == key }
  }

  /// `alias_owned_elsewhere`: the original as a trigger, or the corrected
  /// phrase, is intercepted by a word OTHER than the resolved target, using the
  /// corrector's own ownership rules (`resolveAliasOwnership`). A claim the
  /// target itself holds is excluded, so own coverage is never a conflict.
  static func ownedElsewhere(
    run: EditAlignment.Run, target: CustomWord?, index: WordCorrector.ExactTriggerIndex
  ) -> Bool {
    // A new word has no id of its own: `nil` excludes nobody, so any
    // interceptor is another word. Never a sentinel identity.
    let own: UUID? = target?.id
    for surface in [run.coreOriginal, run.coreReplacement] {
      if case .blocked = index.resolveAliasOwnership(for: surface, excludingOwnerID: own) {
        return true
      }
    }
    return false
  }

  static func hasContractionEnding(_ text: String) -> Bool {
    guard let last = InverseTextNormalizer.splitWords(text).last else { return false }
    let word = last.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
      .trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
    return contractionSuffixes.contains { word.hasSuffix($0) && word.count > $0.count }
  }

  static func normalisedToken(_ token: String) -> String {
    String(token.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  // MARK: - Evidence

  /// Advisory similarity for the judge, Latin script only. Outside Latin the
  /// answer is `nil` (no evidence), never a fabricated score.
  package static func similarity(_ run: EditAlignment.Run) -> Double? {
    let o = run.coreOriginal
    let r = run.coreReplacement
    guard o.count <= maxSimilarityChars, r.count <= maxSimilarityChars else { return nil }
    guard isLatin(o), isLatin(r) else { return nil }
    return WordCorrector().score(o.lowercased(), against: r.lowercased())
  }

  /// Every letter is in a Latin block (Basic, Latin-1, Extended A/B,
  /// Extended Additional); digits, punctuation and spaces are ignored.
  static func isLatin(_ text: String) -> Bool {
    for s in text.unicodeScalars where s.properties.isAlphabetic {
      switch s.value {
      case 0x0041...0x005A, 0x0061...0x007A, 0x00AA, 0x00BA, 0x00C0...0x024F, 0x1E00...0x1EFF:
        continue
      default:
        return false
      }
    }
    return true
  }

  // MARK: - Request shape

  /// Order the eligible runs (capitalised-first, source order for ties), cap
  /// at four, then assign request ids 1... so an id is never minted for a run
  /// that does not reach the judge.
  package static func prepare(_ filtered: [Filtered]) -> Prepared {
    let eligible = filtered.filter {
      if case .candidate = $0.disposition { return true }
      return false
    }
    let ordered = eligible.enumerated().sorted { lhs, rhs in
      let lc = startsCapitalised(lhs.element.run.coreReplacement)
      let rc = startsCapitalised(rhs.element.run.coreReplacement)
      if lc != rc { return lc && !rc }
      return lhs.offset < rhs.offset
    }.map(\.element)
    let kept = Array(ordered.prefix(CorrectionJudgeRequest.maxCandidates))
    let overflow = Array(ordered.dropFirst(CorrectionJudgeRequest.maxCandidates))
    var byID: [Int: Filtered] = [:]
    var candidates: [CorrectionCandidate] = []
    for (offset, f) in kept.enumerated() {
      let id = offset + 1
      byID[id] = f
      candidates.append(
        CorrectionCandidate(id: id, original: f.run.coreOriginal, replacement: f.run.coreReplacement))
    }
    return Prepared(candidates: candidates, byID: byID, overflow: overflow)
  }

  static func startsCapitalised(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first(where: { $0.properties.isAlphabetic }) else {
      return false
    }
    return first.properties.isUppercase
  }
}
