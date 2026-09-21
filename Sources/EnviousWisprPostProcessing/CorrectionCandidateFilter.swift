import EnviousWisprCore
import Foundation

// MARK: - Candidate filter and state assignment (#996 §3.1 step 6)
//
// Pure: takes the live word list, the enabled pack terms, the open and
// rejected pair keys and the arm's language set AS VALUES and returns one
// disposition per aligned run. It never reads a store, never mutates a
// proposal or a word, and never decides whether an edit IS a correction:
// that is the judge's question (step 7). The App coordinator executes the
// dispositions (step 8).

package enum CorrectionCandidateFilter {

  /// Why a run is not sent to the judge. Each is a counted skip token.
  package enum IneligibleReason: String, Sendable, Equatable, CaseIterable {
    /// Dictation language unknown, or outside the selected arm's set.
    case languageUnsupported
    /// Every edited token is a stopword (`WordCorrector.stopwords`).
    case stopwordPhrase
    /// The corrected run ends in a contraction suffix ("it's", "don't").
    case contractionEnding
    /// The corrected phrase, or the original as a trigger, is owned by a
    /// DIFFERENT word than the resolved target.
    case aliasOwnedElsewhere
  }

  /// Plan §3.1 step 6 dispositions. Precedence when several apply (highest
  /// first): `rejected`, `ineligible(.languageUnsupported)`,
  /// `ineligible(.stopwordPhrase)`, `ineligible(.contractionEnding)`,
  /// `alreadyCovered`, `ineligible(.aliasOwnedElsewhere)`, `refreshOpen`,
  /// `candidate`. A rejection therefore never becomes a fresh candidate or a
  /// refresh, and a covered pair is never re-proposed even if an open record
  /// still exists.
  package enum Disposition: Sendable, Equatable {
    case ineligible(IneligibleReason)
    /// The ordered pair carries a rejection tombstone.
    case rejected
    /// The intended live target already carries the original as its
    /// canonical or as a sound-alike; dropped before judging.
    case alreadyCovered
    /// An open proposal for the same pair exists; the coordinator refreshes
    /// its metadata without re-judging it.
    case refreshOpen(proposalID: UUID)
    /// Send to the judge; if it says correction, propose with this state.
    case candidate(CorrectionProposalTargetState)
  }

  /// Everything step 6 reads, as values.
  package struct Inputs: Sendable {
    package let userWords: [CustomWord]
    /// Terms of the ENABLED packs only (`source == .pack`).
    package let packTerms: [CustomWord]
    /// Open (`pending`/`accepting`) proposals by pair key.
    package let openProposals: [String: UUID]
    package let rejectedPairKeys: Set<String>
    package let dictationLanguage: String?
    /// The selected arm's supported base languages; `nil` when the arm has
    /// no evidence for any language, which grants nothing.
    package let supportedLanguages: Set<String>?

    package init(
      userWords: [CustomWord], packTerms: [CustomWord], openProposals: [String: UUID],
      rejectedPairKeys: Set<String>, dictationLanguage: String?, supportedLanguages: Set<String>?
    ) {
      self.userWords = userWords
      self.packTerms = packTerms
      self.openProposals = openProposals
      self.rejectedPairKeys = rejectedPairKeys
      self.dictationLanguage = dictationLanguage
      self.supportedLanguages = supportedLanguages
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
      let disposition = dispose(run: run, pairKey: key, inputs: inputs, index: index)
      // Evidence is computed only where it can be used: a rejected or
      // ineligible run never pays for a character-level comparison.
      var evidence: Double? = nil
      if case .candidate = disposition { evidence = similarity(run) }
      return Filtered(run: run, pairKey: key, disposition: disposition, similarity: evidence)
    }
  }

  private static func dispose(
    run: EditAlignment.Run, pairKey: String, inputs: Inputs, index: WordCorrector.ExactTriggerIndex
  ) -> Disposition {
    if inputs.rejectedPairKeys.contains(pairKey) { return .rejected }
    guard let language = inputs.dictationLanguage, let supported = inputs.supportedLanguages,
      supported.contains(language)
    else { return .ineligible(.languageUnsupported) }
    let editedTokens = InverseTextNormalizer.splitWords(run.coreReplacement).map(normalisedToken)
    if !editedTokens.isEmpty, editedTokens.allSatisfy({ WordCorrector.stopwords.contains($0) }) {
      return .ineligible(.stopwordPhrase)
    }
    if hasContractionEnding(run.coreReplacement) { return .ineligible(.contractionEnding) }

    let target = resolveTarget(corrected: run.coreReplacement, inputs: inputs)
    if let target, covers(target, original: run.coreOriginal) { return .alreadyCovered }
    if ownedElsewhere(run: run, target: target, index: index) {
      return .ineligible(.aliasOwnedElsewhere)
    }
    if let open = inputs.openProposals[pairKey] { return .refreshOpen(proposalID: open) }
    if let target { return .candidate(.existingWord(target.id)) }
    return .candidate(.newWord)
  }

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
