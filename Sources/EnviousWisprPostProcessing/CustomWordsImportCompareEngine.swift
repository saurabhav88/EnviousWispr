import EnviousWisprCore
import Foundation

// Compare/dedup engine for Custom Words import (#1661, epic #1619 PR-F2a).
//
// Classifies imported candidates against the existing library. Detection and
// disclosure only: alias collisions recorded here are informational — the
// commit step (PR-F2b) is the safety guarantee that a colliding alias is
// never persisted. Fully decision-agnostic: `compare` runs BEFORE any Review
// decision exists, so nothing here consults one.

/// Conservative, explicit-opt-in fuzzy matching policy. `.disabled` can never
/// match: no canonical meets an infinite minimum length.
package struct CustomWordsImportFuzzyPolicy: Sendable, Equatable {
  package let minimumLength: Int
  package let maximumEditDistance: Int

  package static let disabled = CustomWordsImportFuzzyPolicy(
    minimumLength: .max, maximumEditDistance: 0)

  package init(minimumLength: Int, maximumEditDistance: Int) {
    self.minimumLength = minimumLength
    self.maximumEditDistance = maximumEditDistance
  }
}

package enum CustomWordsImportClassification: Sendable, Equatable {
  case new
  case exact(existing: CustomWord)
  case variant(existing: CustomWord, matchedAlias: String)
  /// Edit-distance spelling similarity, not phonetic "sounds-alike".
  case fuzzy(existing: CustomWord, distance: Int)
  /// ≥2 equally-valid matches. Homogeneous by construction: the staged
  /// classification order means the matches are all exact-kind, all
  /// variant-kind, or all fuzzy-kind, never mixed. Ordered deterministically
  /// (normalized canonical, then UUID) for stable display — the tie-break
  /// orders the list instead of silently electing a winner.
  case ambiguous(matches: [CustomWordsImportAmbiguousMatch])
}

package struct CustomWordsImportAmbiguousMatch: Sendable, Equatable {
  package enum Kind: Sendable, Equatable {
    /// Two or more existing words whose canonicals are distinct to the
    /// persistence layer but identical under this engine's stronger matching
    /// key. `CustomWordsManager` dedups on `trimmed.lowercased()` only, so
    /// `"Claude Code"` / `"Claude  Code"` and precomposed / decomposed
    /// spellings of the same word can all legitimately coexist on disk.
    case exact
    case variant(matchedAlias: String)
    case fuzzy(distance: Int)
  }

  package let existing: CustomWord
  package let kind: Kind

  package init(existing: CustomWord, kind: Kind) {
    self.existing = existing
    self.kind = kind
  }
}

package struct CustomWordsImportAliasCollision: Sendable, Equatable {
  package let alias: String
  /// The winning existing-word or incoming-candidate owner. For a
  /// canonical-over-alias collision this MAY be a LATER candidate — every
  /// incoming canonical is registered before any imported alias is checked,
  /// so an earlier candidate's alias can lose to a later candidate's
  /// canonical; "earlier candidate always wins" only holds for
  /// alias-vs-alias precedence, not canonical-vs-alias.
  package let heldBy: UUID

  package init(alias: String, heldBy: UUID) {
    self.alias = alias
    self.heldBy = heldBy
  }
}

package struct CustomWordsImportComparison: Identifiable, Sendable, Equatable {
  package let candidate: CustomWordsImportCandidate
  package let classification: CustomWordsImportClassification
  package let collidingAliases: [CustomWordsImportAliasCollision]

  package var id: UUID { candidate.id }

  package init(
    candidate: CustomWordsImportCandidate,
    classification: CustomWordsImportClassification,
    collidingAliases: [CustomWordsImportAliasCollision]
  ) {
    self.candidate = candidate
    self.classification = classification
    self.collidingAliases = collidingAliases
  }
}

/// Off-MainActor comparison. Takes `existingWords` as a value-type snapshot —
/// staleness against a changing library is the commit step's concern (F2b),
/// never this actor's.
package actor CustomWordsImportCompareEngine {
  package init() {}

  package func compare(
    candidates: [CustomWordsImportCandidate],
    against existingWords: [CustomWord],
    fuzzyPolicy: CustomWordsImportFuzzyPolicy
  ) async throws -> [CustomWordsImportComparison] {
    // Every stage below checks cancellation, not just the final loop: Upload
    // admits up to 25,000 rows, so coalescing and collision detection are
    // real work a cancelled sheet must be able to abandon promptly.
    try Task.checkCancellation()
    let coalesced = try Self.coalesceDuplicates(candidates)

    // Existing-library lookups, built once per call.
    // Canonical surfaces map to ALL their owners, not one. The manager dedups
    // canonicals on `trimmed.lowercased()` (CustomWordsManager.swift:425-427)
    // — a WEAKER key than this engine's, which also collapses internal
    // whitespace and precomposes Unicode. So `"Claude Code"` / `"Claude  Code"`
    // (and precomposed / decomposed spellings) can both be present on disk and
    // collapse to one key here. Keeping only the first would silently elect an
    // arbitrary replacement target — exactly what the ambiguous classification
    // exists to prevent.
    var existingCanonicalOwners: [String: [CustomWord]] = [:]
    for word in existingWords {
      existingCanonicalOwners[Self.normalize(word.canonical), default: []].append(word)
    }
    // Nothing prevents two existing words from sharing an alias (only
    // canonicals are deduped), so alias surfaces map to ALL their owners.
    var existingAliasOwners: [String: [(word: CustomWord, alias: String)]] = [:]
    for word in existingWords {
      for alias in word.aliases {
        existingAliasOwners[Self.normalize(alias), default: []].append((word, alias))
      }
    }

    // Fuzzy is the only stage that scans the library word by word, so the
    // existing side is normalized, eligibility-filtered, and BUCKETED BY
    // LENGTH once here instead of per candidate. Two strings within edit
    // distance d differ in length by at most d, so a candidate only ever has
    // to look at buckets [len-d, len+d] — the rest cannot match by
    // definition. Without this, an import at Upload's 25,000-row cap against
    // a comparable library would scan every existing word for every
    // candidate (~625M checks) and re-normalize the same canonicals on each
    // pass. Built only when the policy can match, so a disabled policy pays
    // nothing.
    //
    // Residual, deliberately not solved here (#1663): within the eligible
    // buckets the scan is still linear, so a pathological library (tens of
    // thousands of same-length words) still degrades. A real sublinear
    // structure is only worth building once fuzzy is known to ship and its
    // thresholds are measured — both are open founder decisions, and
    // optimising against guessed thresholds risks the wrong structure.
    var fuzzyIndexByLength: [Int: [FuzzyCandidateWord]] = [:]
    if fuzzyPolicy.maximumEditDistance > 0 {
      for word in existingWords {
        let key = Self.normalize(word.canonical)
        guard key.count >= fuzzyPolicy.minimumLength, Self.isLettersOnly(key) else { continue }
        fuzzyIndexByLength[key.count, default: []].append(
          FuzzyCandidateWord(word: word, key: key))
      }
    }

    let collisions = try Self.detectAliasCollisions(
      coalesced: coalesced, existingWords: existingWords)

    var results: [CustomWordsImportComparison] = []
    results.reserveCapacity(coalesced.count)
    for candidate in coalesced {
      try Task.checkCancellation()
      let classification = Self.classify(
        candidate: candidate,
        existingCanonicalOwners: existingCanonicalOwners,
        existingAliasOwners: existingAliasOwners,
        fuzzyIndexByLength: fuzzyIndexByLength,
        fuzzyPolicy: fuzzyPolicy
      )
      results.append(
        CustomWordsImportComparison(
          candidate: candidate,
          classification: classification,
          collidingAliases: collisions[candidate.id] ?? []
        ))
    }
    return results
  }

  // MARK: - Normalization
  //
  // TWO keys, deliberately, because two different questions are being asked.
  // Conflating them caused defects on both sides of the comparison (Codex
  // review r1 on the library side, r2 on the candidate side), so they are
  // now named and used strictly where each belongs:
  //
  // - `persistenceKey` answers "would these occupy the SAME SLOT in stored
  //   data?" It mirrors `CustomWordsManager`'s own dedup key exactly
  //   (`trimmed.lowercased()`, CustomWordsManager.swift:425-427), which is
  //   also what `WordCorrector` looks up (`alias.lowercased()`,
  //   WordCorrector.swift:180-214) on already-trim-sanitized aliases. Used
  //   for candidate coalescing and alias-collision detection — both are
  //   questions about persistence and correction-map slots.
  //
  // - `normalize` answers "does the user MEAN the same word?" It is
  //   deliberately stronger: it also precomposes Unicode and collapses
  //   internal whitespace, so `café` typed either way, and a stray double
  //   space, still match. Used only for classification.
  //
  // Because `normalize` is strictly stronger, two words distinct under
  // `persistenceKey` can collapse under it — that is real, and it is why
  // multi-owner canonical matches classify `ambiguous` rather than electing
  // an arbitrary winner.

  /// Persistence/correction-slot key. Mirrors `CustomWordsManager`'s dedup.
  package static func persistenceKey(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Matching key. Case-fold, precompose, trim, collapse internal whitespace
  /// — NOTHING else. Punctuation is never stripped: `C`, `C++`, `C#`,
  /// `.NET`, and `node.js` must stay distinct.
  package static func normalize(_ s: String) -> String {
    s.folding(options: .caseInsensitive, locale: nil)
      .precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  // MARK: - Duplicate-candidate coalescing

  /// Repeated candidate canonicals coalesce before classification, keeping
  /// the first row's ID and spelling, so two "New" rows can't silently
  /// collide at persistence time. Keyed on `persistenceKey`, NOT the
  /// stronger matching key: two candidates the manager would happily store
  /// as separate words must stay separate review rows, or a backup holding
  /// both could never restore the second one. Per field (all six authority carriers),
  /// the first `.supplied` value in plan order wins, evaluated
  /// independently; `aliases` unions every `.supplied` list in plan order
  /// (deduplicated via the normalization key, first spelling wins) and stays
  /// `.unspecified` only when every duplicate row was `.unspecified`.
  static func coalesceDuplicates(
    _ candidates: [CustomWordsImportCandidate]
  ) throws -> [CustomWordsImportCandidate] {
    var order: [String] = []
    var byKey: [String: CustomWordsImportCandidate] = [:]

    for candidate in candidates {
      try Task.checkCancellation()
      let key = persistenceKey(candidate.canonical)
      guard var merged = byKey[key] else {
        order.append(key)
        byKey[key] = candidate
        continue
      }

      if case .unspecified = merged.aliases {
        merged.aliases = candidate.aliases
      } else if case .supplied(let existing) = merged.aliases,
        case .supplied(let incoming) = candidate.aliases
      {
        merged.aliases = .supplied(unionByNormalizationKey(existing, incoming))
      }
      merged.suggestedAliases = unionByNormalizationKey(
        merged.suggestedAliases, candidate.suggestedAliases)
      if case .unspecified = merged.category { merged.category = candidate.category }
      if case .unspecified = merged.priority { merged.priority = candidate.priority }
      if case .unspecified = merged.forceReplace { merged.forceReplace = candidate.forceReplace }
      if case .unspecified = merged.caseSensitive {
        merged.caseSensitive = candidate.caseSensitive
      }
      if case .unspecified = merged.minSimilarityOverride {
        merged.minSimilarityOverride = candidate.minSimilarityOverride
      }
      byKey[key] = merged
    }
    return order.compactMap { byKey[$0] }
  }

  private static func unionByNormalizationKey(_ first: [String], _ second: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for alias in first + second {
      let key = persistenceKey(alias)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      result.append(alias)
    }
    return result
  }

  // MARK: - Classification

  /// Fixed staged order: exact canonical → variant (existing alias) →
  /// fuzzy (edit distance against existing canonicals only) → new.
  private static func classify(
    candidate: CustomWordsImportCandidate,
    existingCanonicalOwners: [String: [CustomWord]],
    existingAliasOwners: [String: [(word: CustomWord, alias: String)]],
    fuzzyIndexByLength: [Int: [FuzzyCandidateWord]],
    fuzzyPolicy: CustomWordsImportFuzzyPolicy
  ) -> CustomWordsImportClassification {
    let key = normalize(candidate.canonical)

    if let owners = existingCanonicalOwners[key], owners.isEmpty == false {
      if owners.count == 1 {
        return .exact(existing: owners[0])
      }
      // Distinct on disk, identical under this engine's key — no principled
      // basis to elect one as the replacement target, so surface all of them.
      let matches = owners.map {
        CustomWordsImportAmbiguousMatch(existing: $0, kind: .exact)
      }
      return .ambiguous(matches: orderedDeterministically(matches))
    }

    if let owners = existingAliasOwners[key], owners.isEmpty == false {
      // One word can hold the surface under several alias spellings that
      // normalize identically — that's still a single owner.
      var seenWordIDs = Set<UUID>()
      var uniqueOwners: [(word: CustomWord, alias: String)] = []
      for owner in owners where seenWordIDs.insert(owner.word.id).inserted {
        uniqueOwners.append(owner)
      }
      if uniqueOwners.count == 1 {
        return .variant(
          existing: uniqueOwners[0].word, matchedAlias: uniqueOwners[0].alias)
      }
      let matches =
        uniqueOwners
        .map {
          CustomWordsImportAmbiguousMatch(existing: $0.word, kind: .variant(matchedAlias: $0.alias))
        }
      return .ambiguous(matches: orderedDeterministically(matches))
    }

    if let fuzzyResult = fuzzyMatch(
      candidateKey: key, indexByLength: fuzzyIndexByLength, policy: fuzzyPolicy)
    {
      return fuzzyResult
    }

    return .new
  }

  /// One existing word, pre-normalized and pre-screened for fuzzy eligibility.
  /// Its length is the index bucket, so it is not stored again here.
  struct FuzzyCandidateWord {
    let word: CustomWord
    let key: String
  }

  /// Conservative fuzzy eligibility: policy enabled, both normalized
  /// canonicals at least the minimum length, both letters-only (digits or
  /// punctuation exclude the fuzzy path entirely), aliases never a fuzzy
  /// surface. A distance tie across multiple existing words is ambiguity.
  /// The library side arrives pre-normalized, pre-filtered, and bucketed by
  /// length; only buckets within the maximum distance are visited, since a
  /// larger length gap cannot be bridged by that many edits.
  private static func fuzzyMatch(
    candidateKey: String,
    indexByLength: [Int: [FuzzyCandidateWord]],
    policy: CustomWordsImportFuzzyPolicy
  ) -> CustomWordsImportClassification? {
    guard policy.maximumEditDistance > 0 else { return nil }
    guard candidateKey.count >= policy.minimumLength else { return nil }
    guard isLettersOnly(candidateKey) else { return nil }

    let candidateLength = candidateKey.count
    var best: [(word: CustomWord, distance: Int)] = []
    // Optional rather than a `maximumEditDistance + 1` sentinel: this type's
    // own vocabulary already includes extreme values (`.disabled` uses
    // `minimumLength: .max`), and the symmetric `maximumEditDistance: .max`
    // would overflow that addition and trap before matching anything. No
    // arithmetic on the policy means no such trap, and no policy value has to
    // be rejected to stay safe.
    var bestDistance: Int?
    // Walk the BUCKETS, not a numeric length range: the number of distinct
    // word lengths is tiny, whereas a numeric range built from a policy with
    // an extreme distance would iterate unboundedly. Result order is
    // unaffected by dictionary iteration order — a single best match is
    // unique, and ties are sorted by `orderedDeterministically` before return.
    for (length, entries) in indexByLength {
      guard abs(length - candidateLength) <= policy.maximumEditDistance else { continue }
      for entry in entries {
        guard
          let distance = editDistance(candidateKey, entry.key, cap: policy.maximumEditDistance),
          distance >= 1
        else { continue }
        let word = entry.word
        guard let current = bestDistance else {
          bestDistance = distance
          best = [(word, distance)]
          continue
        }
        if distance < current {
          bestDistance = distance
          best = [(word, distance)]
        } else if distance == current {
          best.append((word, distance))
        }
      }
    }

    guard best.isEmpty == false else { return nil }
    if best.count == 1 {
      return .fuzzy(existing: best[0].word, distance: best[0].distance)
    }
    let matches =
      best
      .map {
        CustomWordsImportAmbiguousMatch(existing: $0.word, kind: .fuzzy(distance: $0.distance))
      }
    return .ambiguous(matches: orderedDeterministically(matches))
  }

  private static func orderedDeterministically(
    _ matches: [CustomWordsImportAmbiguousMatch]
  ) -> [CustomWordsImportAmbiguousMatch] {
    matches.sorted { a, b in
      let ka = normalize(a.existing.canonical)
      let kb = normalize(b.existing.canonical)
      if ka != kb { return ka < kb }
      return a.existing.id.uuidString < b.existing.id.uuidString
    }
  }

  private static func isLettersOnly(_ s: String) -> Bool {
    s.isEmpty == false && s.allSatisfy(\.isLetter)
  }

  /// Levenshtein distance with a cap: returns nil when the distance exceeds
  /// `cap`, so long unrelated strings exit early.
  static func editDistance(_ a: String, _ b: String, cap: Int) -> Int? {
    let aChars = Array(a)
    let bChars = Array(b)
    if abs(aChars.count - bChars.count) > cap { return nil }
    if aChars.isEmpty { return bChars.count <= cap ? bChars.count : nil }
    if bChars.isEmpty { return aChars.count <= cap ? aChars.count : nil }

    var previous = Array(0...bChars.count)
    var current = [Int](repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
      current[0] = i
      var rowMinimum = current[0]
      for j in 1...bChars.count {
        let substitution = previous[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
        current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
        rowMinimum = min(rowMinimum, current[j])
      }
      if rowMinimum > cap { return nil }
      swap(&previous, &current)
    }
    let distance = previous[bChars.count]
    return distance <= cap ? distance : nil
  }

  // MARK: - Alias-collision detection (decision-agnostic; disclosure only)

  /// Keyed on `persistenceKey` throughout, not the matching key: a collision
  /// is a claim about two entries fighting over the same slot in stored data
  /// and in `WordCorrector`'s lookup map, and both use the manager's weaker
  /// key. Using the stronger matching key here would flag pairs that never
  /// actually collide at runtime.
  ///
  /// The corrected algorithm (plan rounds 5-7):
  /// 1. One canonical-ownership set from every existing word's canonical AND
  ///    every incoming candidate's canonical; existing-library ownership
  ///    always sorts first, then incoming plan order.
  /// 2. Each candidate's SOURCE aliases in plan order (never
  ///    `suggestedAliases` — enrichment has not run at compare time; a
  ///    colliding suggestion is enforced-and-receipted at commit instead).
  ///    An alias equal to its OWN candidate's canonical is redundant, not a
  ///    collision — silently normalized away, never reported.
  /// 3. Canonical ownership is checked FIRST; a match records the WINNING
  ///    canonical owner and the alias is never registered below.
  /// 4. Alias-ownership: incumbent (existing-library) aliases always win over
  ///    any import; among two incumbents sharing an alias the LATER one wins
  ///    (mirroring `WordCorrector`'s last-write-wins map build); among
  ///    imported aliases, first-in-plan-order wins. Only the LOSING candidate
  ///    is flagged — the winner's alias is not at risk.
  /// 5. Otherwise the candidate owns that alias surface for the batch.
  static func detectAliasCollisions(
    coalesced: [CustomWordsImportCandidate],
    existingWords: [CustomWord]
  ) throws -> [UUID: [CustomWordsImportAliasCollision]] {
    var canonicalOwners: [String: UUID] = [:]
    for word in existingWords {
      let key = persistenceKey(word.canonical)
      if canonicalOwners[key] == nil { canonicalOwners[key] = word.id }
    }
    for candidate in coalesced {
      let key = persistenceKey(candidate.canonical)
      if canonicalOwners[key] == nil { canonicalOwners[key] = candidate.id }
    }

    // Incumbent aliases: LAST writer wins, mirroring runtime rather than
    // this function's own first-wins convention. When two existing words
    // share an alias, `WordCorrector.buildLookups` assigns unconditionally
    // (`singleAliasMap[key] = word.canonical`, WordCorrector.swift:180-214,
    // whose own debug line reads "using <later canonical>"), so the later
    // word is the one that actually claims the trigger. Reporting the
    // earlier one would name a word that is not really holding the alias,
    // and F2c's Replace-target suppression compares against this exact id.
    var aliasOwners: [String: UUID] = [:]
    for word in existingWords {
      for alias in word.aliases {
        let key = persistenceKey(alias)
        if key.isEmpty == false { aliasOwners[key] = word.id }
      }
    }

    var collisions: [UUID: [CustomWordsImportAliasCollision]] = [:]
    for candidate in coalesced {
      try Task.checkCancellation()
      guard case .supplied(let sourceAliases) = candidate.aliases else { continue }
      let ownCanonicalKey = persistenceKey(candidate.canonical)
      for alias in sourceAliases {
        let key = persistenceKey(alias)
        if key.isEmpty || key == ownCanonicalKey { continue }
        // A candidate only ever owns its OWN canonical surface, which the
        // `key == ownCanonicalKey` guard above already consumed — so any
        // canonical owner found here is necessarily a different word.
        if let canonicalOwner = canonicalOwners[key] {
          collisions[candidate.id, default: []].append(
            CustomWordsImportAliasCollision(alias: alias, heldBy: canonicalOwner))
          continue
        }
        // Likewise, a candidate can only already own an alias surface via an
        // earlier alias of its own, which is a duplicate spelling rather than
        // a collision — skip it without flagging.
        if let aliasOwner = aliasOwners[key] {
          if aliasOwner != candidate.id {
            collisions[candidate.id, default: []].append(
              CustomWordsImportAliasCollision(alias: alias, heldBy: aliasOwner))
          }
          continue
        }
        aliasOwners[key] = candidate.id
      }
    }
    return collisions
  }
}
