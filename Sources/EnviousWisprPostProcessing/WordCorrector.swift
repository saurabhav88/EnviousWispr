import EnviousWisprCore
import Foundation
import os

/// Pure, Sendable word correction engine.
///
/// Six-pass replacement:
/// 0. **N-gram compound match** -- concatenate 1-3 adjacent words, match against canonicals
///    with spaces removed. Catches "Chat G P T" -> "ChatGPT", "Open A I" -> "OpenAI".
/// 1. **Exact multi-word alias** -- O(1) lookup for multi-word aliases (longest match first).
/// 2. **Fuzzy multi-word alias** -- score phrase against same-token-count aliases when exact misses.
/// 3. **Exact single-word alias** -- O(1) lookup including canonical self-entries for casing fixes.
/// 4. **Fuzzy single-word alias** -- score token against all single-word aliases (error surfaces).
/// 5. **Fuzzy canonical fallback** -- score token against canonicals for words with no aliases.
///
/// Replacement acceptance requires: score >= threshold, ambiguity margin over second-best,
/// stricter threshold for short tokens (<= 4 chars).
public struct WordCorrector: Sendable {
  public static let threshold: Double = 0.82
  public static let multiWordThreshold: Double = 0.85
  public static let shortTokenThreshold: Double = 0.90
  public static let ambiguityMargin: Double = 0.05
  public static let shortTokenMaxLength = 4

  /// #992 pack fuzzy: a vocabulary-pack term participates in the fuzzy passes
  /// only when its scored surface is at least this many characters. Short pack
  /// terms stay exact-only (Pass 1/3) — short surfaces are where coincidental
  /// fuzzy collisions concentrate ("a sync" → async, "and jinx" → nginx).
  public static let packFuzzyMinLength = 7

  /// #992 pack fuzzy: additive stricter bar for pack-tier fuzzy acceptance,
  /// stacked on top of the #638 vocab-size + length-aware adjustments. Pack
  /// terms have LOWER authority than user/builtin terms — which are matched in a
  /// separate, earlier tier (see `correct(using:)`), so this bump is a second
  /// line of defense, not the precedence mechanism.
  public static let packFuzzyThresholdBump: Double = 0.05

  /// #341 EmojiFormatter trigger-word reservation. These literals cannot be
  /// substituted by custom-word correction even when a user has defined an
  /// alias for them. See plan §3.4 global-behavior caveat.
  static let emojiTriggerReservedWords: Set<String> = ["emoji", "emoticon"]

  /// True if any token in the slice (after punctuation strip + lowercase) is a
  /// reserved trigger word. Used by Pass 0/1/2 to skip multi-word substitutions
  /// that would consume a trigger word.
  static func sliceContainsReservedTriggerWord(_ slice: ArraySlice<String>) -> Bool {
    for token in slice {
      let core = stripPunctuationStatic(token).lowercased()
      if emojiTriggerReservedWords.contains(core) { return true }
    }
    return false
  }

  /// Static mirror of the instance-private `stripPunctuation` used inside the
  /// reserved-word check. Stays minimal: strips leading/trailing punctuation
  /// runs only (matches the instance method's contract for our purpose).
  private static func stripPunctuationStatic(_ token: String) -> String {
    guard !token.isEmpty else { return token }
    let punct: Set<Character> = [
      ".", ",", "!", "?", ";", ":", "—", "–", "-", "\"", "'", "(", ")", "[", "]", "{", "}",
    ]
    var s = token
    while let first = s.first, punct.contains(first) { s.removeFirst() }
    while let last = s.last, punct.contains(last) { s.removeLast() }
    return s
  }

  private static let levenshteinWeight = 0.40
  private static let bigramWeight = 0.40
  private static let soundexWeight = 0.20

  private static let logger = Logger(subsystem: "com.enviouswispr", category: "WordCorrector")

  public init() {}

  // MARK: - Phase 2 (#638) hardening helpers — bible §8.2

  /// Common stopwords that lift the multi-word fuzzy threshold by +0.05 when
  /// they appear in a candidate span. Prevents "and we said" → "Andre",
  /// "at this" → "Matthew", "or who" → "Orhul" type degeneration as vocab
  /// grows past 100 terms.
  static let stopwords: Set<String> = [
    "the", "and", "or", "is", "to", "for", "in",
    "a", "at", "on", "of", "we", "you", "it",
  ]

  /// Lift threshold in proportion to candidate-pool density. The chance of a
  /// coincidental near-match grows roughly linearly with candidate density;
  /// this penalty restores precision-at-scale without changing the scoring
  /// shape. Bible §8.2 item 2.
  ///
  /// Pool size ≤ 100 → no penalty.
  /// Pool size 101-600 → +0.02.
  /// Pool size 601-1100 → +0.04.
  /// Pool size 1101+ → +0.06 (capped).
  public static func largeVocabPenalty(poolSize: Int) -> Double {
    guard poolSize > 100 else { return 0 }
    let bumps = (poolSize - 100) / 500
    return min(0.06, Double(bumps) * 0.02)
  }

  /// Loosen threshold for longer candidates. A one-character edit in a 5-char
  /// term costs 20% similarity; the same edit in a 20-char phrase costs 5%.
  /// Subtracts up to 0.04 from the threshold for terms longer than 8 chars.
  /// Bible §8.2 item 3.
  public static func lengthAwareAdjustment(candidateLength: Int) -> Double {
    return min(0.04, 0.005 * Double(max(0, candidateLength - 8)))
  }

  // MARK: - Phase 2b (#638) lookup-map cache

  /// Pre-built lookup structures for one `WordCorrector.correct(...)` call.
  /// Phase 2b (#638) extracts what was previously rebuilt on every call so
  /// `WordCorrectionStep` can cache it across calls of the same vocabulary
  /// generation. Bible §17 R19 (matcher rebuild risk).
  ///
  /// Sendable so callers can hop the value across actors (e.g. running
  /// `correct(...)` off MainActor inside the heart-path 10ms timeout).
  public struct Lookups: Sendable {
    public struct SurfaceCanonical: Sendable {
      public let surface: String
      public let canonical: String
    }
    public struct AliasCanonical: Sendable {
      public let alias: String
      public let canonical: String
    }
    public let singleAliasMap: [String: String]
    public let multiAliasMap: [String: String]
    public let nospaceCanonicalMap: [String: String]
    public let canonicalToID: [String: UUID]
    public let canonicalToWord: [String: CustomWord]
    public let canonicals: [String]
    public let lowercasedCanonicals: [String]
    public let singleFuzzyCandidates: [SurfaceCanonical]
    public let multiAliasByCount: [Int: [AliasCanonical]]
    /// #992 pack fuzzy tier (LOWER authority than the non-pack pools above).
    /// Single-word pack ALIAS surfaces (lowercased, length ≥ packFuzzyMinLength)
    /// for the pack Pass-4 scan; pack CANONICALS (length ≥ packFuzzyMinLength)
    /// for the pack Pass-5 scan. Scored ONLY after every non-pack fuzzy pass
    /// misses, so a user/builtin match always wins.
    public let packSingleFuzzyCandidates: [SurfaceCanonical]
    public let packCanonicals: [String]
    public let packLowercasedCanonicals: [String]
    /// #992 precedence: lowercased keys of every NON-pack exact term (single
    /// alias keys + canonical self-entries + all non-pack canonicals). A token
    /// the user/builtin vocabulary already recognizes is "correct as-is", so the
    /// pack fuzzy tier must NEVER rewrite it — including the case where the
    /// non-pack tier made no replacement because no fix was needed.
    public let nonPackExactKeys: Set<String>
  }

  // MARK: - Exact-trigger authority (#1667)

  /// The one place that answers "what exact keys does this value claim, and at
  /// what precedence" (#1667).
  ///
  /// Import collision detection used to re-derive this by hand and mirrored only
  /// two of the surfaces. That partial mirror was found wrong three separate
  /// times — first-wins vs last-wins among two alias owners, canonical-first vs
  /// alias-first, then the no-space surface it never modelled at all. A fourth
  /// divergence was latent: the detector trimmed its keys, this does not, so on
  /// malformed or legacy data the two disagreed about what a key even was.
  ///
  /// The fix is not a fourth patch. `buildLookups` and `detectAliasCollisions`
  /// now BOTH construct claims here, so there is nothing left to drift.
  package enum ExactTriggerNamespace: Sendable, Equatable {
    case single
    case multi
    case nospace

    /// Correction-pass order, used to pick which owner a single collision
    /// receipt names when one alias is blocked on several surfaces at once.
    /// Pass 0 (no-space compound) runs before the ordinary exact passes.
    package var passPriority: Int {
      switch self {
      case .nospace: return 0
      case .multi: return 1
      case .single: return 3
      }
    }
  }

  package struct ExactTriggerClaim: Sendable, Equatable {
    package let key: String
    package let namespace: ExactTriggerNamespace
  }

  package struct TriggerOwner: Sendable, Equatable {
    package let wordID: UUID
    package let canonical: String
    /// Pack terms are a lower authority: they only ever gap-fill the ordinary
    /// namespaces, and the fuzzy pools must be built from non-pack owners alone.
    /// Carried here so `buildLookups` can separate the two populations without
    /// rebuilding either map.
    package let isPack: Bool
  }

  /// A key claimed twice in an ordinary namespace, recorded rather than logged.
  ///
  /// The builder stays pure so both consumers can call it freely — the import
  /// detector builds an index too, and a builder that logged would narrate a
  /// preview as if the vocabulary had just been rebuilt. `buildLookups` remains
  /// the one place these are reported.
  package struct ExactTriggerCollision: Sendable, Equatable {
    package let key: String
    package let existingCanonical: String
    package let winningCanonical: String
  }

  /// A canonical self-entry that yielded to an alias already owning its key.
  package struct ExactTriggerCanonicalSkip: Sendable, Equatable {
    package let key: String
    package let canonical: String
    package let existingCanonical: String
  }

  /// The three possible answers to "does this alias collide against a planned
  /// ownership index, and who wins" (#1672). Not persisted, not Codable — a
  /// pure in-memory decision value scoped to one compare/commit pass.
  package enum ExactAliasOwnershipResolution: Sendable, Equatable {
    /// The alias normalizes to no exact-trigger claims at all (e.g. empty).
    case noClaims
    /// Nothing intercepts this alias — every claim is either unheld, held
    /// only by the excluded owner, or held by a compound owner that
    /// declines to intercept. Carries the claims so the caller can gap-fill
    /// them under its own ownership if it decides to keep this alias.
    case available(claims: [ExactTriggerClaim])
    /// The earliest-intercepting held claim blocks this alias.
    case blocked(by: TriggerOwner)
  }

  /// Effective incumbent ownership, after every overwrite and gap-fill rule has
  /// already been applied. Consumers read winners; they never replay precedence.
  package struct ExactTriggerIndex: Sendable {
    package var single: [String: TriggerOwner] = [:]
    package var multi: [String: TriggerOwner] = [:]
    package var nospace: [String: TriggerOwner] = [:]
    /// Diagnostics only, in construction order. Never consulted for precedence.
    package var collisions: [ExactTriggerCollision] = []
    package var canonicalSkips: [ExactTriggerCanonicalSkip] = []

    package func owner(of claim: ExactTriggerClaim) -> TriggerOwner? {
      switch claim.namespace {
      case .single: return single[claim.key]
      case .multi: return multi[claim.key]
      case .nospace: return nospace[claim.key]
      }
    }

    /// Assign a claim unconditionally. For consumers that resolve ownership
    /// incrementally — the import commit path decides one word at a time, in
    /// the order the user approved — rather than over a whole vocabulary.
    package mutating func register(_ claim: ExactTriggerClaim, to owner: TriggerOwner) {
      switch claim.namespace {
      case .single: single[claim.key] = owner
      case .multi: multi[claim.key] = owner
      case .nospace: nospace[claim.key] = owner
      }
    }

    /// Apply a WORD'S OWN canonical claims to an incrementally-resolved index.
    ///
    /// The two per-namespace rules do not read the same: an ordinary self-entry
    /// yields to whoever already holds the key, while the compound form is
    /// written unconditionally and can overwrite an earlier alias. This is that
    /// rule stated once. Two import consumers — the compare screen and the
    /// commit path — used to restate it inline, and diverged when only one of
    /// them was corrected (grounded review r5/r6, #1667).
    package mutating func applyCanonical(_ canonical: String, owner: TriggerOwner) {
      for claim in WordCorrector.exactClaims(forCanonical: canonical) {
        switch claim.namespace {
        case .nospace: register(claim, to: owner)
        case .single, .multi: if self.owner(of: claim) == nil { register(claim, to: owner) }
        }
      }
    }

    /// Register every claim in `claims` that nobody already holds. Never
    /// overwrites: a claim already held — including by a compound owner that
    /// declines to intercept this exact surface — keeps its existing owner,
    /// because that is what the corrector's own gap-fill rule does at runtime.
    package mutating func gapFill(_ claims: [ExactTriggerClaim], owner: TriggerOwner) {
      for claim in claims where self.owner(of: claim) == nil {
        register(claim, to: owner)
      }
    }

    /// The single shared answer to "does this alias collide, and who wins" —
    /// called by BOTH the import preview
    /// (`CustomWordsImportCompareEngine.detectAliasCollisions`) and the import
    /// commit (`CustomWordsManager.enforceAliases`). Neither consumer may
    /// re-derive blocker detection or decisive-owner selection locally; both
    /// call this and branch only on the returned case (#1672).
    ///
    /// Read-only: does not mutate `self`. Registration (`gapFill`) remains the
    /// caller's explicit, separate responsibility in the `.available` branch —
    /// preserving the existing atomicity rule that a partially-registered
    /// alias must never be created (evaluate fully, THEN register).
    ///
    /// `excludingOwnerID` is the word/candidate whose own claim on a key must
    /// never count as blocking itself — an existing `CustomWord.id` for the
    /// commit path, a not-yet-saved `CustomWordsImportCandidate.id` for the
    /// preview path. Both are `UUID`; the exclusion semantics are identical
    /// either way ("this owner's own claim cannot block its own alias").
    package func resolveAliasOwnership(
      for alias: String, excludingOwnerID: UUID
    ) -> ExactAliasOwnershipResolution {
      let claims = WordCorrector.exactClaims(forAlias: alias)
      guard !claims.isEmpty else { return .noClaims }

      let blockers = claims.compactMap {
        claim -> (claim: ExactTriggerClaim, owner: TriggerOwner)? in
        guard let holder = owner(of: claim), holder.wordID != excludingOwnerID else { return nil }
        return WordCorrector.ownerIntercepts(claim: claim, rawSurface: alias, owner: holder)
          ? (claim, holder) : nil
      }
      if let decisive = blockers.min(by: {
        $0.claim.namespace.passPriority < $1.claim.namespace.passPriority
      }) {
        return .blocked(by: decisive.owner)
      }
      return .available(claims: claims)
    }

    /// The ordinary-namespace maps in `buildLookups`' shape, optionally limited
    /// to non-pack owners for the fuzzy pools that must exclude pack terms.
    func canonicalsByKey(
      _ namespace: ExactTriggerNamespace, nonPackOnly: Bool = false
    ) -> [String: String] {
      let source: [String: TriggerOwner]
      switch namespace {
      case .single: source = single
      case .multi: source = multi
      case .nospace: source = nospace
      }
      return source.reduce(into: [String: String]()) { result, entry in
        guard !nonPackOnly || !entry.value.isPack else { return }
        result[entry.key] = entry.value.canonical
      }
    }
  }

  /// Whether an owner would actually INTERCEPT this surface, as opposed to
  /// merely holding the key.
  ///
  /// Pass 0 declines to substitute when the spoken text already concatenates to
  /// the owner's own canonical (`rawConcat == canonicalNospace`), so the text
  /// falls through to the ordinary passes and a DIFFERENT word corrects it. A
  /// consumer asking "who beats me here" has to know that, or it names a word
  /// that never touches the text: existing `Annie` and existing `Anika`/alias
  /// `annie`, spoken "Annie", is corrected by Anika even though `Annie` holds
  /// the no-space key. Empirically confirmed against the real corrector, not
  /// reasoned about (#1667).
  ///
  /// The ordinary namespaces have no such guard: holding the key is
  /// intercepting it.
  /// Every gate below is Pass 0's, in Pass 0's order. A first cut modelled only
  /// the "already correct" short-circuit and let unreachable surfaces outrank
  /// real ordinary claims — a four-token alias, a two-character one, a
  /// punctuated one, or one containing a reserved trigger word can never be
  /// consumed here, so a no-space holder is not blocking anything (grounded
  /// review, #1667).
  package static func ownerIntercepts(
    claim: ExactTriggerClaim, rawSurface: String, owner: TriggerOwner
  ) -> Bool {
    guard claim.namespace == .nospace else { return true }

    // Pass 0 only ever concatenates 1-3 adjacent tokens. Trim the ends, but do
    // NOT drop interior empty tokens: a doubled internal space really is an
    // extra token to the tokenizer, and "one   two" genuinely overflows the
    // three-token window. Filtering all empties said it fit (grounded review r2).
    let tokens =
      rawSurface
      .trimmingCharacters(in: .whitespaces)
      .components(separatedBy: .whitespaces)
    guard (1...3).contains(tokens.count) else { return false }

    let slice = tokens[...]
    guard !sliceContainsReservedTriggerWord(slice) else { return false }

    let stripped = slice.map { stripPunctuationStatic($0) }
    let ngram = stripped.map { $0.lowercased() }.joined()
    // Below three characters Pass 0 skips the lookup entirely; and if the
    // stripped form is not this claim's key, this is not the surface that
    // would reach the owner.
    guard ngram.count >= 3, ngram == claim.key else { return false }

    // The "already correct" short-circuit, case-sensitive exactly as Pass 0
    // compares it.
    let rawConcat = stripped.joined()
    return rawConcat != owner.canonical.replacingOccurrences(of: " ", with: "")
  }

  /// Keys an ALIAS claims. Ordinary surface first, then its no-space form when
  /// that differs. Deduplicated, so a space-free alias yields one ordinary claim
  /// plus its identical-key no-space claim only when the namespaces differ.
  package static func exactClaims(forAlias alias: String) -> [ExactTriggerClaim] {
    let key = alias.lowercased()
    guard !key.isEmpty else { return [] }
    var claims = [
      ExactTriggerClaim(key: key, namespace: alias.contains(" ") ? .multi : .single)
    ]
    let nospaceKey = alias.replacingOccurrences(of: " ", with: "").lowercased()
    if !nospaceKey.isEmpty {
      claims.append(ExactTriggerClaim(key: nospaceKey, namespace: .nospace))
    }
    return claims
  }

  /// Keys a CANONICAL claims. The self-entry exists only for a space-free
  /// canonical; the no-space claim is unconditional.
  package static func exactClaims(forCanonical canonical: String) -> [ExactTriggerClaim] {
    let key = canonical.lowercased()
    guard !key.isEmpty else { return [] }
    var claims: [ExactTriggerClaim] = []
    if !key.contains(" ") { claims.append(ExactTriggerClaim(key: key, namespace: .single)) }
    let nospaceKey = canonical.replacingOccurrences(of: " ", with: "").lowercased()
    if !nospaceKey.isEmpty {
      claims.append(ExactTriggerClaim(key: nospaceKey, namespace: .nospace))
    }
    return claims
  }

  /// Resolve effective ownership across a whole vocabulary, applying the same
  /// rules `buildLookups` has always applied — which is why `buildLookups` now
  /// projects from this rather than repeating them.
  package static func buildExactTriggerIndex(words: [CustomWord]) -> ExactTriggerIndex {
    let packWords = words.filter { $0.source == .pack }
    let nonPackWords = words.filter { $0.source != .pack }
    var index = ExactTriggerIndex()

    // Non-pack aliases: last writer wins in the ordinary namespaces.
    for word in nonPackWords {
      let owner = TriggerOwner(wordID: word.id, canonical: word.canonical, isPack: false)
      // Empty keys are NOT filtered, here or below. The construction this
      // replaces inserted them, and a refactor that quietly drops entries is
      // not a refactor. They are inert at runtime (Pass 0 requires three
      // characters, and the ordinary passes only look up non-empty tokens), so
      // preserving them costs nothing and keeps the diagnostics identical
      // (grounded review, #1667).
      for alias in word.aliases {
        let key = alias.lowercased()
        let namespace: ExactTriggerNamespace = alias.contains(" ") ? .multi : .single
        if let existing = index.owner(of: ExactTriggerClaim(key: key, namespace: namespace)),
          existing.canonical != word.canonical
        {
          index.collisions.append(
            ExactTriggerCollision(
              key: key, existingCanonical: existing.canonical, winningCanonical: word.canonical))
        }
        if namespace == .multi { index.multi[key] = owner } else { index.single[key] = owner }
      }
    }

    // Non-pack canonical self-entry: space-free only, and it YIELDS to an alias.
    for word in nonPackWords {
      let key = word.canonical.lowercased()
      guard !key.contains(" ") else { continue }
      if let existing = index.single[key] {
        if existing.canonical != word.canonical {
          index.canonicalSkips.append(
            ExactTriggerCanonicalSkip(
              key: key, canonical: word.canonical, existingCanonical: existing.canonical))
        }
        continue
      }
      index.single[key] = TriggerOwner(wordID: word.id, canonical: word.canonical, isPack: false)
    }

    // No-space namespace, non-pack only. Canonical is unconditional and last
    // writer wins; an alias fills only an empty slot. So alias-vs-alias is
    // FIRST-wins here while canonical-vs-canonical is last-wins, and a later
    // canonical can overwrite an earlier alias. Three rules, one map — the
    // reason a hand-rolled mirror kept getting this wrong.
    for word in nonPackWords {
      let owner = TriggerOwner(wordID: word.id, canonical: word.canonical, isPack: false)
      let nospace = word.canonical.replacingOccurrences(of: " ", with: "").lowercased()
      index.nospace[nospace] = owner
      for alias in word.aliases {
        let aliasNospace = alias.replacingOccurrences(of: " ", with: "").lowercased()
        guard index.nospace[aliasNospace] == nil else { continue }
        index.nospace[aliasNospace] = owner
      }
    }

    // Pack aliases gap-fill the ordinary namespaces only, and never claim a key
    // any non-pack canonical owns. Pack canonicals get no self-entry, and pack
    // terms never enter the no-space namespace.
    let nonPackCanonicalKeys = Set(nonPackWords.map { $0.canonical.lowercased() })
    for word in packWords {
      let owner = TriggerOwner(wordID: word.id, canonical: word.canonical, isPack: true)
      for alias in word.aliases {
        let key = alias.lowercased()
        guard !nonPackCanonicalKeys.contains(key) else { continue }
        if alias.contains(" ") {
          if index.multi[key] == nil { index.multi[key] = owner }
        } else {
          if index.single[key] == nil { index.single[key] = owner }
        }
      }
    }

    return index
  }

  /// Build the lookup structures for a given vocabulary. Pure function.
  /// `WordCorrectionStep` calls this once per generation change and reuses
  /// the result across many `correct(...)` calls.
  public static func buildLookups(words: [CustomWord]) -> Lookups {
    // #633 Phase 9: pack-sourced terms are EXACT-MATCH ONLY. They participate
    // in the exact alias/canonical maps (Pass 1 multi-exact, Pass 3
    // single-exact) but are excluded from every fuzzy/compound pool
    // (Pass 0 nospace-compound, Pass 2 multi-fuzzy, Pass 4 single-fuzzy,
    // Pass 5 canonical-fuzzy). Non-pack (user/builtin/observedAX) terms keep
    // their full behaviour. On any key clash, non-pack wins: the non-pack maps
    // are built first and authoritatively, then pack entries fill ONLY keys no
    // non-pack term claimed. This protects user terms from pack shadowing for
    // all clash shapes (user-alias vs pack-alias, user-canonical vs pack-alias,
    // user-alias vs pack-canonical).
    let packWords = words.filter { $0.source == .pack }
    let nonPackWords = words.filter { $0.source != .pack }

    var canonicalToID: [String: UUID] = [:]
    var canonicalToWord: [String: CustomWord] = [:]
    for word in nonPackWords {
      canonicalToID[word.canonical.lowercased()] = word.id
      canonicalToWord[word.canonical.lowercased()] = word
    }

    // The three exact maps are PROJECTED from the one authority rather than
    // rebuilt here (#1667). Every precedence rule they encode — alias last-wins,
    // canonical self-entry yielding to an alias, pack gap-fill only, and the
    // three-rules-in-one-map no-space namespace — now lives in exactly one
    // place, which the import collision detector reads too. It had drifted from
    // this construction three separate times, each time as a fresh instance
    // patch; the fix is that there is no longer a second construction to drift.
    let triggerIndex = buildExactTriggerIndex(words: words)

    #if DEBUG
      // The builder is pure so the detector can call it without narrating; the
      // reporting stays here, where a vocabulary rebuild actually happened.
      for (offset, collision) in triggerIndex.collisions.enumerated() {
        Self.logger.debug(
          "Alias collision #\(offset + 1): '\(collision.key)' claimed by '\(collision.existingCanonical)' and '\(collision.winningCanonical)', using '\(collision.winningCanonical)'"
        )
      }
      for skip in triggerIndex.canonicalSkips {
        Self.logger.debug(
          "Canonical '\(skip.canonical)' skipped: key '\(skip.key)' already maps to '\(skip.existingCanonical)'"
        )
      }
    #endif

    let singleAliasMap = triggerIndex.canonicalsByKey(.single)
    let multiAliasMap = triggerIndex.canonicalsByKey(.multi)

    // The NON-PACK exact maps. The fuzzy/compound pools derive from these so
    // pack terms can never become fuzzy candidates.
    let nonPackSingleAliasMap = triggerIndex.canonicalsByKey(.single, nonPackOnly: true)
    let nonPackMultiAliasMap = triggerIndex.canonicalsByKey(.multi, nonPackOnly: true)

    // Every non-pack canonical key (INCLUDING multi-word canonicals, which get
    // no exact-map self-entry). A pack term must never claim one of these keys,
    // so a multi-word user canonical can't be hijacked by a pack alias even
    // though it isn't present in the alias maps. (Codex diff-review edge.)
    let nonPackCanonicalKeys = Set(nonPackWords.map { $0.canonical.lowercased() })

    // Pack exact entries are already in the projected maps: the authority fills
    // ONLY keys no non-pack term claimed, for every clash shape including
    // multi-word canonicals (#1667 moved that rule there). What remains here is
    // pack ATTRIBUTION, which is not trigger ownership and stays local.
    for word in packWords {
      // #992: pack canonical self-entries are NOT added to singleAliasMap. They
      // only ever normalized casing — unreliable for packs (lowercase
      // canonicals) and the source of the live casing harm (correct
      // "Ameritrade" → "ameritrade" via Pass 3). A pack canonical near-miss is
      // now handled by the Pass-5 pack fuzzy tier with the casing guard.
      let ck = word.canonical.lowercased()
      // Attribution: fill the pack id only when no non-pack term owns this
      // canonical. Known minor telemetry edge (accepted, #992 §6): if a user
      // term and a pack term SHARE a canonical, a pack correction is attributed
      // to the user id, so `hadPackTerm` under-counts that case. Counts-only
      // telemetry; corrected text is unaffected.
      if canonicalToID[ck] == nil { canonicalToID[ck] = word.id }
      if canonicalToWord[ck] == nil { canonicalToWord[ck] = word }
    }

    // Fuzzy + compound + canonical-fuzzy pools: NON-PACK words ONLY.
    let canonicals = nonPackWords.map(\.canonical)
    let lowercasedCanonicals = canonicals.map { $0.lowercased() }
    let singleFuzzyCandidates = nonPackSingleAliasMap.map {
      Lookups.SurfaceCanonical(surface: $0.key, canonical: $0.value)
    }
    var multiAliasByCount: [Int: [Lookups.AliasCanonical]] = [:]
    for (alias, canonical) in nonPackMultiAliasMap {
      let count = alias.components(separatedBy: " ").count
      multiAliasByCount[count, default: []].append(
        Lookups.AliasCanonical(alias: alias, canonical: canonical))
    }

    // Projected too (#1667). This map is the one the detector missed entirely:
    // an imported alias equal to an existing multi-word canonical's space-free
    // form was reported collision-free, persisted, and then never fired,
    // because Pass 0 resolved the n-gram here first.
    let nospaceCanonicalMap = triggerIndex.canonicalsByKey(.nospace)

    // #992 pack fuzzy tier (LOWER authority). Single-word pack terms whose
    // scored surface length ≥ packFuzzyMinLength, built from the SAME lowercased
    // surfaces the scorer sees (normalization parity with the non-pack pools).
    // Multi-word pack terms and compounds stay out (deferred to the n-gram
    // follow-up). Scored only after every non-pack fuzzy pass misses.
    var packSingleFuzzyCandidates: [Lookups.SurfaceCanonical] = []
    for word in packWords {
      for alias in word.aliases where !alias.contains(" ") {
        let surface = alias.lowercased()
        if surface.count >= packFuzzyMinLength {
          packSingleFuzzyCandidates.append(
            Lookups.SurfaceCanonical(surface: surface, canonical: word.canonical))
        }
      }
    }
    // De-dupe by lowercased canonical: the same canonical can ship in two
    // enabled packs (e.g. "miralax" in medical+brands). Without de-duping, the
    // duplicate competes against itself in pack Pass 5 — both copies score
    // identically, driving the best-vs-second margin to 0 and wrongly rejecting
    // a valid fix (the Pass-5 loop, unlike Pass 4, has no same-canonical guard).
    var seenPackCanonicals = Set<String>()
    var packCanonicals: [String] = []
    for word in packWords {
      let canonical = word.canonical
      guard !canonical.contains(" "), canonical.count >= packFuzzyMinLength else { continue }
      if seenPackCanonicals.insert(canonical.lowercased()).inserted {
        packCanonicals.append(canonical)
      }
    }
    let packLowercasedCanonicals = packCanonicals.map { $0.lowercased() }

    // #992 precedence: every token the non-pack vocabulary already recognizes
    // as-is (single alias keys + canonical self-entries via nonPackSingleAliasMap,
    // plus all non-pack canonicals). The pack fuzzy tier is skipped for these.
    let nonPackExactKeys = Set(nonPackSingleAliasMap.keys).union(nonPackCanonicalKeys)

    return Lookups(
      singleAliasMap: singleAliasMap,
      multiAliasMap: multiAliasMap,
      nospaceCanonicalMap: nospaceCanonicalMap,
      canonicalToID: canonicalToID,
      canonicalToWord: canonicalToWord,
      canonicals: canonicals,
      lowercasedCanonicals: lowercasedCanonicals,
      singleFuzzyCandidates: singleFuzzyCandidates,
      multiAliasByCount: multiAliasByCount,
      packSingleFuzzyCandidates: packSingleFuzzyCandidates,
      packCanonicals: packCanonicals,
      packLowercasedCanonicals: packLowercasedCanonicals,
      nonPackExactKeys: nonPackExactKeys
    )
  }

  // MARK: - Replacement attribution (Phase 3a #631)

  /// Per-replacement attribution: which `CustomWord.id` this replacement
  /// originated from. Phase 3b consumes the list to bump `frequencyUsed` /
  /// `lastUsed` on each source. Phase 7 may extend with `pass: Int, span:
  /// Range<String.Index>` if needed (currently unused per bible §13).
  public struct Replacement: Sendable, Equatable {
    public let sourceID: UUID
    public init(sourceID: UUID) { self.sourceID = sourceID }
  }

  // MARK: - Main Correction

  /// Convenience overload — builds lookups inline. Use this when you only
  /// call `correct` once per vocabulary (legacy callers, tests).
  // periphery:ignore - test seam
  public func correct(_ text: String, against words: [CustomWord]) -> (
    corrected: String, replacements: [Replacement]
  ) {
    guard !words.isEmpty else { return (text, []) }
    let lookups = Self.buildLookups(words: words)
    return correct(text, using: lookups)
  }

  /// Phase 2b (#638) primary entry point. Accepts pre-built lookups so
  /// `WordCorrectionStep` can cache the build cost across calls of the same
  /// vocabulary generation. Pure function — safe to call off any actor.
  public func correct(_ text: String, using lookups: Lookups) -> (
    corrected: String, replacements: [Replacement]
  ) {
    let singleAliasMap = lookups.singleAliasMap
    let multiAliasMap = lookups.multiAliasMap
    let nospaceCanonicalMap = lookups.nospaceCanonicalMap
    let canonicalToID = lookups.canonicalToID
    let canonicalToWord = lookups.canonicalToWord
    let canonicals = lookups.canonicals
    let lowercasedCanonicals = lookups.lowercasedCanonicals
    let singleFuzzyCandidates = lookups.singleFuzzyCandidates
    let multiAliasByCount = lookups.multiAliasByCount
    let packSingleFuzzyCandidates = lookups.packSingleFuzzyCandidates
    let packCanonicals = lookups.packCanonicals
    let packLowercasedCanonicals = lookups.packLowercasedCanonicals
    let nonPackExactKeys = lookups.nonPackExactKeys

    var replacements: [Replacement] = []
    var tokens = text.components(separatedBy: .whitespaces)
    // Phase 3a (#631) helper: append a Replacement for the given canonical.
    // Falls through silently if the canonical lookup misses (shouldn't happen
    // with valid input — defensive only).
    func appendReplacement(forCanonical canonical: String) {
      if let id = canonicalToID[canonical.lowercased()] {
        replacements.append(Replacement(sourceID: id))
      }
    }

    // Pass 0: N-gram compound matching
    // Concatenate 1-3 adjacent words (stripped of punctuation, lowercased, spaces removed)
    // and check against nospace canonical/alias map.
    // "Chat G P T" -> "chatgpt" matches "ChatGPT"
    if !nospaceCanonicalMap.isEmpty {
      var i = 0
      while i < tokens.count {
        var matched = false

        for n in (1...min(3, tokens.count - i)).reversed() {
          let slice = tokens[i..<(i + n)]
          let ngram =
            slice
            .map { stripPunctuation($0).lowercased() }
            .joined()  // No separator: concatenate directly

          guard ngram.count >= 3 else { continue }

          // #341 Pass 0 reserved-word guard: if any token in the n-gram slice
          // is a trigger word, do not substitute. Protects "emoji"/"emoticon"
          // tokens uniformly across all passes (see plan §3.4 global caveat).
          if Self.sliceContainsReservedTriggerWord(slice) {
            continue
          }

          // Length ratio check: ngram must be within 25% of candidate length
          if let canonical = nospaceCanonicalMap[ngram] {
            let canonicalNospace = canonical.replacingOccurrences(of: " ", with: "")
            // Check it's not already correct
            let rawConcat = slice.map { stripPunctuation($0) }.joined()
            if rawConcat == canonicalNospace { break }

            let (firstPrefix, _, _) = splitPunctuation(tokens[i])
            let (_, _, lastSuffix) = splitPunctuation(tokens[i + n - 1])
            tokens.replaceSubrange(i..<(i + n), with: [firstPrefix + canonical + lastSuffix])
            appendReplacement(forCanonical: canonical)
            matched = true
            #if DEBUG
              Self.logger.debug(
                "WordCorrector: type=ngram-compound source='\(rawConcat)' target='\(canonical)' n=\(n)"
              )
            #endif
            break
          }
        }

        i += 1
        if matched { continue }
      }
    }

    // Pass 1 + 2: multi-word (exact then fuzzy)
    if !multiAliasMap.isEmpty {
      let maxSpan = multiAliasMap.keys.reduce(0) { max($0, $1.components(separatedBy: " ").count) }
      var i = 0
      while i < tokens.count {
        var matched = false

        for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
          let slice = tokens[i..<(i + span)]
          let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
          let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

          // #341 Pass 1 reserved-word guard (same rationale as Pass 0).
          if Self.sliceContainsReservedTriggerWord(slice) {
            continue
          }

          // Pass 1: exact multi-word alias
          if let canonical = multiAliasMap[phrase], rawPhrase != canonical {
            let (firstPrefix, _, _) = splitPunctuation(tokens[i])
            let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
            tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + canonical + lastSuffix])
            appendReplacement(forCanonical: canonical)
            matched = true
            #if DEBUG
              Self.logger.debug(
                "WordCorrector: type=multi-word-exact source='\(rawPhrase)' target='\(canonical)'")
            #endif
            break
          }
        }

        // Pass 2: fuzzy multi-word fallback (only if exact missed for all spans)
        if !matched {
          for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
            let slice = tokens[i..<(i + span)]
            let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
            let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

            // #341 Pass 2 reserved-word guard (same rationale as Pass 0/1).
            if Self.sliceContainsReservedTriggerWord(slice) {
              continue
            }

            if let candidates = multiAliasByCount[span] {
              var bestScore = 0.0
              var secondBest = 0.0
              var bestCanonical = ""
              var bestAlias = ""

              for entry in candidates {
                let alias = entry.alias
                let canonical = entry.canonical
                let s = score(phrase, against: alias)
                if s > bestScore {
                  if bestCanonical != canonical { secondBest = bestScore }
                  bestScore = s
                  bestCanonical = canonical
                  bestAlias = alias
                } else if s > secondBest && canonical != bestCanonical {
                  secondBest = s
                }
              }

              let margin = bestScore - secondBest
              // Phase 2 (#638) §8.2 item 1: lift multi-word threshold by +0.05
              // when the candidate span includes any common stopword. Prevents
              // "and we said" → "Andre" type degeneration.
              let phraseTokens = Set(phrase.components(separatedBy: " "))
              let hasStopword = !phraseTokens.isDisjoint(with: Self.stopwords)
              let stopwordPenalty = hasStopword ? 0.05 : 0.0
              // Phase 2 (#638) §8.2 item 4: per-term override for the matched
              // canonical, if any. Override is the absolute bar.
              let multiOverride = canonicalToWord[bestCanonical.lowercased()]?
                .minSimilarityOverride
              let multiThreshold = multiOverride ?? (Self.multiWordThreshold + stopwordPenalty)
              if bestScore >= multiThreshold,
                margin >= Self.ambiguityMargin,
                rawPhrase != bestCanonical
              {
                let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                tokens.replaceSubrange(
                  i..<(i + span), with: [firstPrefix + bestCanonical + lastSuffix])
                appendReplacement(forCanonical: bestCanonical)
                matched = true
                #if DEBUG
                  Self.logger.debug(
                    "WordCorrector: type=multi-word-fuzzy source='\(rawPhrase)' target='\(bestCanonical)' alias='\(bestAlias)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(margin, format: .fixed(precision: 3)) stopword=\(hasStopword) override=\(multiOverride.map { String($0) } ?? "nil")"
                  )
                #endif
                break
              } else if bestScore > 0 {
                #if DEBUG
                  let reason: String
                  if bestScore < multiThreshold {
                    reason = "below_threshold"
                  } else if margin < Self.ambiguityMargin {
                    reason = "below_margin"
                  } else {
                    reason = "same_as_input"
                  }
                  Self.logger.debug(
                    "WordCorrector: REJECT pass=multi-word-fuzzy source='\(rawPhrase)' best_target='\(bestCanonical)' alias='\(bestAlias)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(margin, format: .fixed(precision: 3)) threshold=\(multiThreshold, format: .fixed(precision: 3)) stopword=\(hasStopword) reason=\(reason)"
                  )
                #endif
              }
            }
          }
        }

        i += 1
      }
    }

    // Passes 3-5: single-word (per token)
    let corrected = tokens.map { token -> String in
      let (prefix, core, suffix) = splitPunctuation(token)
      guard !core.isEmpty, core.count >= 2 else { return token }

      let coreLower = core.lowercased()

      // #341 EmojiFormatter trigger-word reservation: "emoji" and "emoticon"
      // are reserved from custom-word substitution. The guard is unconditional
      // (applies even when EmojiFormatter is disabled in Settings) because the
      // trigger semantics belong to the deterministic post-processor downstream,
      // not the per-user vocabulary layer. See plan §3.4.
      if Self.emojiTriggerReservedWords.contains(coreLower) {
        return token
      }

      // Compute the peeled form up front (used by steps 2 and 4 below).
      // The trigger is purely structural -- a dot followed by a non-empty
      // run of letters/digits/hyphens -- deliberately not limited to any
      // curated TLD list: fuzzy scoring can silently swallow ANY glued
      // suffix that survives edge-punctuation stripping, not only a
      // hand-picked set (Codex review, PR for #2281, finding P1 round 3).
      // If nothing ever matches the peeled core, the untouched original
      // token is returned below, so a permissive trigger costs nothing
      // when the suffix isn't actually a domain.
      var matchCore = core
      var peeledSuffix = ""
      let hasPeelableSuffix: Bool
      if let split = Self.splitDomainSuffix(core) {
        matchCore = split.bare
        peeledSuffix = split.suffix
        hasPeelableSuffix = true
      } else {
        hasPeelableSuffix = false
      }
      let matchCoreLower = matchCore.lowercased()
      let matchCoreEligible =
        !Self.emojiTriggerReservedWords.contains(matchCoreLower) && matchCore.count >= 2

      // A peeled suffix, once a match is found, is reattached UNLESS the
      // matched canonical is itself domain-shaped -- it already fully
      // specifies its own domain, whatever suffix the user actually said
      // (Codex review, PR for #2281, finding P2, rounds 2-4).
      func reattached(_ canonical: String) -> String {
        let reattach = peeledSuffix.isEmpty || Self.isDomainShaped(canonical) ? "" : peeledSuffix
        return prefix + canonical + reattach + suffix
      }

      // Step 1 + 2: EXACT match to completion -- unpeeled, then peeled --
      // before any fuzzy pass runs at all, AND non-pack outranks pack
      // across that same boundary. Exact equality always outranks fuzzy
      // scoring (finding P1 round 4). Within exact itself, "non-pack always
      // wins over pack" must ALSO hold across the peel boundary: an
      // unpeeled key can resolve to a pack alias while the peeled key
      // resolves to the user's own alias (pack "githib.com", user
      // "githib") -- accepting the unpeeled pack match immediately would
      // preempt the higher-authority user match one step away (Codex
      // review, PR for #2281, finding P1 round 7). So both attempts are
      // computed first, with non-pack results checked before either pack
      // result is accepted.
      let unpeeledExact = exactSingleWordMatch(core: core, coreLower: coreLower, lookups: lookups)
      // The token already IS a registered canonical, byte-for-byte -- the
      // strongest "leave this alone" signal available. Stop the whole
      // single-word retry here rather than falling through to the peeled
      // attempt, which could otherwise replace already-correct text with an
      // unrelated match (Codex review, PR for #2281, finding P2 round 9).
      if case .alreadyCorrect = unpeeledExact { return token }

      var unpeeledMatch: (canonical: String, isPack: Bool)?
      if case .replace(let canonical, let isPack) = unpeeledExact {
        unpeeledMatch = (canonical, isPack)
      }

      let peeledExact =
        matchCoreEligible
        ? exactSingleWordMatch(core: matchCore, coreLower: matchCoreLower, lookups: lookups)
        : ExactSingleWordOutcome.noMatch
      var peeledMatch: (canonical: String, isPack: Bool)?
      if case .replace(let canonical, let isPack) = peeledExact {
        peeledMatch = (canonical, isPack)
      }
      // `.alreadyCorrect` on the PEELED form means the bare part was
      // already spelled right, so the untouched original token (bare part
      // + its existing suffix) is already the correct output -- but that
      // conclusion is only valid if nothing else is allowed to override it
      // afterward. An earlier version of this comment claimed the "falls
      // through to the final `return token`" path made this automatic; it
      // does not, because `peeledMatch` staying nil here is indistinguishable
      // from `.noMatch`, so a LOWER-authority pack exact match (or even a
      // fuzzy match) found afterward could still win and replace text that
      // was already correct (local Codex sweep of PR #2298's cloud
      // findings, same day: canonical "GitHub" + pack alias "github.com" ->
      // "Wrong" turned input "GitHub.com" into "Wrong" instead of leaving
      // it alone). Stop here, exactly like the unpeeled case above.
      if case .alreadyCorrect = peeledExact { return token }

      func acceptExact(unpeeled: Bool, _ match: (canonical: String, isPack: Bool)) -> String {
        appendReplacement(forCanonical: match.canonical)
        #if DEBUG
          Self.logger.debug(
            "WordCorrector: type=alias source='\(unpeeled ? core : matchCore)' target='\(match.canonical)'"
          )
        #endif
        return unpeeled ? prefix + match.canonical + suffix : reattached(match.canonical)
      }

      if let match = unpeeledMatch, !match.isPack {
        return acceptExact(unpeeled: true, match)
      }
      if let match = peeledMatch, !match.isPack {
        return acceptExact(unpeeled: false, match)
      }
      if let match = unpeeledMatch {
        return acceptExact(unpeeled: true, match)
      }
      if let match = peeledMatch {
        return acceptExact(unpeeled: false, match)
      }

      // Step 3 + 4: non-pack FUZZY to completion -- unpeeled (restricted to
      // domain-shaped candidates), then peeled (unrestricted) -- before the
      // pack tier gets a turn at all, so "non-pack always wins over pack"
      // holds across the peel boundary too, not only within one attempt
      // (Codex review, PR for #2281; same shape as finding P1 round 4, one
      // tier down). Step 3's domain restriction is necessary because fuzzy
      // scoring CAN cross threshold against a glued suffix, but only when
      // the CANDIDATE compared against is itself bare -- a candidate that
      // is ALSO domain-shaped makes the raw comparison apples-to-apples, so
      // a near-miss like "githib.com" needs to try this unpeeled (finding
      // P1 round 3).
      //
      // Step 3 only runs when the token ITSELF has a peelable suffix (Codex
      // review round 5, P1): without that guard it ran even for an ordinary
      // no-dot word, comparing it against domain-shaped candidates it has
      // no business being compared against and letting a weaker
      // domain-shaped match preempt the correct bare candidate reachable
      // only at step 4 -- "enviouswhisper" scoring against
      // "enviouswhisper.com" purely because the strings share a long
      // prefix, with no dot in the input at all.
      if hasPeelableSuffix,
        let canonical = nonPackFuzzySingleWordMatch(
          core: core, coreLower: coreLower, lookups: lookups,
          appendReplacement: { appendReplacement(forCanonical: $0) }, domainShapedOnly: true)
      {
        return prefix + canonical + suffix
      }
      if matchCoreEligible,
        let canonical = nonPackFuzzySingleWordMatch(
          core: matchCore, coreLower: matchCoreLower, lookups: lookups,
          appendReplacement: { appendReplacement(forCanonical: $0) }, domainShapedOnly: false)
      {
        return reattached(canonical)
      }

      // Step 5 + 6: pack fuzzy, the same unpeeled-then-peeled shape (step 5
      // gated on `hasPeelableSuffix` for the same reason step 3 is), only
      // reached once every higher-authority attempt above has missed. Step
      // 4's peeled non-pack fuzzy fixes the originally reported bug for a
      // bare (non-domain-shaped) alias.
      if hasPeelableSuffix,
        let canonical = packFuzzySingleWordMatch(
          core: core, coreLower: coreLower, lookups: lookups,
          appendReplacement: { appendReplacement(forCanonical: $0) }, domainShapedOnly: true)
      {
        return prefix + canonical + suffix
      }
      if matchCoreEligible,
        let canonical = packFuzzySingleWordMatch(
          core: matchCore, coreLower: matchCoreLower, lookups: lookups,
          appendReplacement: { appendReplacement(forCanonical: $0) }, domainShapedOnly: false)
      {
        return reattached(canonical)
      }

      return token
    }

    return (corrected.joined(separator: " "), replacements)
  }

  /// Pass 3 alone: exact single-word alias (includes canonical self-entries).
  /// Factored out so the outer single-word retry in `correct(using:)` can run
  /// EXACT matching to completion -- unpeeled, then peeled -- before trying
  /// any fuzzy pass. Exact equality always outranks fuzzy scoring and always
  /// respects the user/pack tiering baked into `singleAliasMap`, and that
  /// must hold even when a domain-shaped token is involved: a fuzzy match
  /// found via the unpeeled domain-restricted pass could otherwise preempt
  /// the user's own exact alias, reachable only by peeling first (Codex
  /// review, PR for #2281, finding P1 round 4).
  /// Returns the matched canonical AND whether it came from a pack term,
  /// but does NOT call `appendReplacement` or log -- the caller decides
  /// which of potentially several candidate exact matches (unpeeled vs
  /// peeled) actually wins before committing that side effect (Codex
  /// review, PR for #2281, finding P1 round 7: see the call site in
  /// `correct(using:)` for why the caller needs to see both before
  /// choosing).
  /// Three outcomes, not two, because the caller must react differently to
  /// "nothing registered for this key" than to "something IS registered and
  /// this token already IS that canonical" (Codex review, PR for #2281,
  /// finding P2 round 9): collapsing both into `nil` let the peeled attempt
  /// run even when the UNPEELED token was already letter-for-letter a real
  /// canonical -- e.g. core exactly equals canonical "GitHub.com", so no
  /// correction is needed at all, but an unrelated alias "github" (the
  /// peeled bare form) mapping to some OTHER canonical could still win,
  /// replacing text that was already correct. Exact self-identity is the
  /// strongest possible "leave this alone" signal there is; it must stop
  /// the whole single-word retry, not merely this one attempt.
  private enum ExactSingleWordOutcome {
    case replace(canonical: String, isPack: Bool)
    case alreadyCorrect
    case noMatch
  }

  private func exactSingleWordMatch(
    core: String, coreLower: String, lookups: Lookups
  ) -> ExactSingleWordOutcome {
    guard let canonical = lookups.singleAliasMap[coreLower] else { return .noMatch }
    guard core != canonical else { return .alreadyCorrect }
    // Authority comes from the matched KEY (`coreLower`), never from the
    // resulting canonical TEXT (Codex review, PR for #2281, finding P2
    // round 8): `canonicalToWord[canonical]` answers "who owns this
    // canonical STRING", which breaks when a pack alias and a user word
    // happen to share the same canonical text -- a pack alias "githib.com"
    // -> "Shared" would then be misattributed to the USER'S "Shared" word
    // and wrongly treated as non-pack. `singleAliasMap` is constructed so
    // non-pack always wins on a KEY collision, so `nonPackExactKeys`
    // (already the authority for exactly that construction) tells us
    // whether THIS key's mapping came from a non-pack term, unambiguously.
    let isPack = !lookups.nonPackExactKeys.contains(coreLower)
    return .replace(canonical: canonical, isPack: isPack)
  }

  /// Pass 4-5 alone (non-pack fuzzy: aliases + canonical self-entries, then
  /// canonicals as fallback). Split from the pack tier so the outer
  /// single-word retry can run the FULL non-pack fuzzy tier -- unpeeled,
  /// then peeled -- before the pack tier gets a turn at all, the same way
  /// exact already runs to completion before any fuzzy pass. Without this
  /// split, a pack-tier fuzzy hit reachable unpeeled (domain-restricted)
  /// could preempt a non-pack fuzzy hit reachable only by peeling -- the
  /// identical shape of precedence violation Codex review round 4 found one
  /// tier up (exact vs. fuzzy), and "non-pack always wins over pack" is
  /// exactly as absolute an invariant in this file as "exact always wins
  /// over fuzzy" is.
  ///
  /// `domainShapedOnly` gates both loops: the unpeeled call site passes
  /// `true` (fuzzy is only safe unpeeled when comparing against an equally
  /// domain-shaped candidate -- both sides then carry a suffix, so nothing
  /// is silently swallowed); the peeled call site passes `false` (the
  /// ordinary, unrestricted pool).
  private func nonPackFuzzySingleWordMatch(
    core: String, coreLower: String,
    lookups: Lookups, appendReplacement: (String) -> Void,
    domainShapedOnly: Bool
  ) -> String? {
    let singleFuzzyCandidates = lookups.singleFuzzyCandidates
    let canonicalToWord = lookups.canonicalToWord
    let lowercasedCanonicals = lookups.lowercasedCanonicals
    let canonicals = lookups.canonicals

    // Skip fuzzy for very short tokens
    guard core.count >= 3 else { return nil }

    // Determine threshold based on token length
    let effectiveThreshold =
      core.count <= Self.shortTokenMaxLength
      ? Self.shortTokenThreshold
      : Self.threshold

    // Pass 4: fuzzy single-word against aliases + canonical self-entries
    let coreLen = coreLower.count
    var bestScore = 0.0
    var secondBest = 0.0
    var bestMatch = ""

    for entry in singleFuzzyCandidates {
      let surface = entry.surface
      let canonical = entry.canonical
      if domainShapedOnly, !Self.isDomainShaped(surface), !Self.isDomainShaped(canonical) {
        continue
      }
      // Length-ratio pruning: skip if lengths differ too much for threshold
      let surfLen = surface.count
      let lenRatio = Double(min(coreLen, surfLen)) / Double(max(coreLen, surfLen))
      if lenRatio < 0.5 { continue }

      let s = score(coreLower, against: surface)
      if s > bestScore {
        if bestMatch != canonical { secondBest = bestScore }
        bestScore = s
        bestMatch = canonical
      } else if s > secondBest && canonical != bestMatch {
        secondBest = s
      }
    }

    // Phase 2 (#638) §8.2: vocab-size penalty + length-aware adjustment
    // applied per-candidate. Per-term override wins absolutely if set.
    let pass4VocabPenalty = Self.largeVocabPenalty(poolSize: singleFuzzyCandidates.count)
    let pass4LengthAdj = Self.lengthAwareAdjustment(candidateLength: bestMatch.count)
    let pass4Override = canonicalToWord[bestMatch.lowercased()]?.minSimilarityOverride
    let pass4Threshold =
      pass4Override ?? (effectiveThreshold + pass4VocabPenalty - pass4LengthAdj)
    if bestScore >= pass4Threshold,
      bestScore - secondBest >= Self.ambiguityMargin,
      core != bestMatch
    {
      appendReplacement(bestMatch)
      #if DEBUG
        Self.logger.debug(
          "WordCorrector: type=alias-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3)) threshold=\(pass4Threshold, format: .fixed(precision: 3))"
        )
      #endif
      return bestMatch
    } else if bestScore > 0 {
      #if DEBUG
        let pass4Margin = bestScore - secondBest
        let reason: String
        if bestScore < pass4Threshold {
          reason = "below_threshold"
        } else if pass4Margin < Self.ambiguityMargin {
          reason = "below_margin"
        } else {
          reason = "same_as_input"
        }
        Self.logger.debug(
          "WordCorrector: REJECT pass=alias-fuzzy source='\(core)' best_target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(pass4Margin, format: .fixed(precision: 3)) threshold=\(pass4Threshold, format: .fixed(precision: 3)) reason=\(reason)"
        )
      #endif
    }

    // Pass 5: fuzzy single-word against canonicals as fallback
    bestScore = 0.0
    secondBest = 0.0
    bestMatch = ""

    for (idx, targetLower) in lowercasedCanonicals.enumerated() {
      if domainShapedOnly, !Self.isDomainShaped(targetLower) { continue }
      let targetLen = targetLower.count
      let lenRatio = Double(min(coreLen, targetLen)) / Double(max(coreLen, targetLen))
      if lenRatio < 0.5 { continue }

      let s = score(coreLower, against: targetLower)
      if s > bestScore {
        secondBest = bestScore
        bestScore = s
        bestMatch = canonicals[idx]
      } else if s > secondBest {
        secondBest = s
      }
    }

    // Phase 2 (#638) §8.2: same hardening for Pass 5.
    let pass5VocabPenalty = Self.largeVocabPenalty(poolSize: lowercasedCanonicals.count)
    let pass5LengthAdj = Self.lengthAwareAdjustment(candidateLength: bestMatch.count)
    let pass5Override = canonicalToWord[bestMatch.lowercased()]?.minSimilarityOverride
    let pass5Threshold =
      pass5Override ?? (effectiveThreshold + pass5VocabPenalty - pass5LengthAdj)
    if bestScore >= pass5Threshold,
      bestScore - secondBest >= Self.ambiguityMargin,
      core != bestMatch
    {
      appendReplacement(bestMatch)
      #if DEBUG
        Self.logger.debug(
          "WordCorrector: type=canonical-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3)) threshold=\(pass5Threshold, format: .fixed(precision: 3))"
        )
      #endif
      return bestMatch
    } else if bestScore > 0 {
      #if DEBUG
        let pass5Margin = bestScore - secondBest
        let reason: String
        if bestScore < pass5Threshold {
          reason = "below_threshold"
        } else if pass5Margin < Self.ambiguityMargin {
          reason = "below_margin"
        } else {
          reason = "same_as_input"
        }
        Self.logger.debug(
          "WordCorrector: REJECT pass=canonical-fuzzy source='\(core)' best_target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(pass5Margin, format: .fixed(precision: 3)) threshold=\(pass5Threshold, format: .fixed(precision: 3)) reason=\(reason)"
        )
      #endif
    }

    return nil
  }

  /// #992 PACK FUZZY TIER — LOWER authority. Split from the non-pack fuzzy
  /// passes so the outer single-word retry can call this ONLY after BOTH
  /// non-pack fuzzy attempts (unpeeled, then peeled) have already missed --
  /// see `nonPackFuzzySingleWordMatch`'s doc comment for why that ordering,
  /// not merely "non-pack pool before pack pool within one call", is what
  /// this tier's whole reason for existing depends on. Pack matches
  /// additionally clear a stricter bar (`packFuzzyThresholdBump`) and a
  /// casing guard (a case-only change is never an improvement for the
  /// lowercase pack canonicals).
  private func packFuzzySingleWordMatch(
    core: String, coreLower: String,
    lookups: Lookups, appendReplacement: (String) -> Void,
    domainShapedOnly: Bool
  ) -> String? {
    let packSingleFuzzyCandidates = lookups.packSingleFuzzyCandidates
    let packCanonicals = lookups.packCanonicals
    let packLowercasedCanonicals = lookups.packLowercasedCanonicals
    let nonPackExactKeys = lookups.nonPackExactKeys

    guard core.count >= 3 else { return nil }
    let effectiveThreshold =
      core.count <= Self.shortTokenMaxLength
      ? Self.shortTokenThreshold
      : Self.threshold
    let coreLen = coreLower.count

    // #992 precedence guard: if the token is already a recognized non-pack
    // term (user/builtin canonical or alias), it is correct as-is — packs
    // must not rewrite it. This covers the case where non-pack matching
    // produced no replacement precisely because no fix was needed.
    if nonPackExactKeys.contains(coreLower) {
      return nil
    }

    // Pack Pass 4: single-word pack aliases.
    if !packSingleFuzzyCandidates.isEmpty {
      var pBest = 0.0
      var pSecond = 0.0
      var pMatch = ""
      for entry in packSingleFuzzyCandidates {
        if domainShapedOnly, !Self.isDomainShaped(entry.surface),
          !Self.isDomainShaped(entry.canonical)
        {
          continue
        }
        let surfLen = entry.surface.count
        let lenRatio = Double(min(coreLen, surfLen)) / Double(max(coreLen, surfLen))
        if lenRatio < 0.5 { continue }
        let s = score(coreLower, against: entry.surface)
        if s > pBest {
          if pMatch != entry.canonical { pSecond = pBest }
          pBest = s
          pMatch = entry.canonical
        } else if s > pSecond && entry.canonical != pMatch {
          pSecond = s
        }
      }
      let vocabPenalty = Self.largeVocabPenalty(poolSize: packSingleFuzzyCandidates.count)
      let lengthAdj = Self.lengthAwareAdjustment(candidateLength: pMatch.count)
      let packThreshold =
        effectiveThreshold + vocabPenalty - lengthAdj + Self.packFuzzyThresholdBump
      if pBest >= packThreshold, pBest - pSecond >= Self.ambiguityMargin, core != pMatch {
        if coreLower == pMatch.lowercased() {
          // Casing guard: case-only change — suppress, fall through.
          #if DEBUG
            Self.logger.debug(
              "WordCorrector: SUPPRESS pass=pack-alias-fuzzy reason=case_only source='\(core)' target='\(pMatch)'"
            )
          #endif
        } else {
          appendReplacement(pMatch)
          #if DEBUG
            Self.logger.debug(
              "WordCorrector: type=pack-alias-fuzzy source='\(core)' target='\(pMatch)' score=\(pBest, format: .fixed(precision: 3)) margin=\(pBest - pSecond, format: .fixed(precision: 3)) threshold=\(packThreshold, format: .fixed(precision: 3))"
            )
          #endif
          return pMatch
        }
      }
    }

    // Pack Pass 5: single-word pack canonicals.
    if !packLowercasedCanonicals.isEmpty {
      var pBest = 0.0
      var pSecond = 0.0
      var pMatch = ""
      for (idx, targetLower) in packLowercasedCanonicals.enumerated() {
        if domainShapedOnly, !Self.isDomainShaped(targetLower) { continue }
        let targetLen = targetLower.count
        let lenRatio = Double(min(coreLen, targetLen)) / Double(max(coreLen, targetLen))
        if lenRatio < 0.5 { continue }
        let s = score(coreLower, against: targetLower)
        if s > pBest {
          pSecond = pBest
          pBest = s
          pMatch = packCanonicals[idx]
        } else if s > pSecond {
          pSecond = s
        }
      }
      let vocabPenalty = Self.largeVocabPenalty(poolSize: packLowercasedCanonicals.count)
      let lengthAdj = Self.lengthAwareAdjustment(candidateLength: pMatch.count)
      let packThreshold =
        effectiveThreshold + vocabPenalty - lengthAdj + Self.packFuzzyThresholdBump
      if pBest >= packThreshold, pBest - pSecond >= Self.ambiguityMargin, core != pMatch {
        if coreLower == pMatch.lowercased() {
          #if DEBUG
            Self.logger.debug(
              "WordCorrector: SUPPRESS pass=pack-canonical-fuzzy reason=case_only source='\(core)' target='\(pMatch)'"
            )
          #endif
        } else {
          appendReplacement(pMatch)
          #if DEBUG
            Self.logger.debug(
              "WordCorrector: type=pack-canonical-fuzzy source='\(core)' target='\(pMatch)' score=\(pBest, format: .fixed(precision: 3)) margin=\(pBest - pSecond, format: .fixed(precision: 3)) threshold=\(packThreshold, format: .fixed(precision: 3))"
            )
          #endif
          return pMatch
        }
      }
    }

    return nil
  }

  // MARK: - Scoring

  public func score(_ candidate: String, against target: String) -> Double {
    let lev = levenshteinSimilarity(candidate, target) * Self.levenshteinWeight
    let bigram = bigramDice(candidate, target) * Self.bigramWeight
    let sdx = soundexScore(candidate, target) * Self.soundexWeight
    return lev + bigram + sdx
  }

  // MARK: - Levenshtein

  private func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
    let a = Array(a)
    let b = Array(b)
    let m = a.count
    let n = b.count
    if m == 0 { return n == 0 ? 1.0 : 0.0 }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
      for j in 1...n {
        dp[i][j] =
          a[i - 1] == b[j - 1]
          ? dp[i - 1][j - 1]
          : 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
      }
    }
    let dist = dp[m][n]
    return 1.0 - Double(dist) / Double(max(m, n))
  }

  // MARK: - Bigram Dice

  private func bigramDice(_ a: String, _ b: String) -> Double {
    func bigrams(_ s: String) -> Set<String> {
      guard s.count >= 2 else { return [] }
      let chars = Array(s)
      return Set((0..<chars.count - 1).map { String([chars[$0], chars[$0 + 1]]) })
    }
    let ba = bigrams(a)
    let bb = bigrams(b)
    guard !ba.isEmpty || !bb.isEmpty else { return a == b ? 1.0 : 0.0 }
    let intersection = ba.intersection(bb).count
    return 2.0 * Double(intersection) / Double(ba.count + bb.count)
  }

  // MARK: - Soundex

  private func soundexScore(_ a: String, _ b: String) -> Double {
    soundex(a) == soundex(b) ? 1.0 : 0.0
  }

  private static let soundexMap: [Character: Character] = [
    "b": "1", "f": "1", "p": "1", "v": "1",
    "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
    "d": "3", "t": "3", "e": "0", "i": "0", "o": "0", "u": "0", "y": "0", "h": "0", "w": "0",
    "l": "4", "m": "5", "n": "5", "r": "6",
  ]

  private func soundex(_ s: String) -> String {
    let lower = s.lowercased()
    guard let first = lower.first else { return "0000" }

    var code = String(first.uppercased())
    var last = Self.soundexMap[first] ?? "0"

    for ch in lower.dropFirst() {
      guard let digit = Self.soundexMap[ch] else { continue }
      if digit != "0" && digit != last {
        code.append(digit)
        if code.count == 4 { break }
      }
      last = digit
    }

    while code.count < 4 { code.append("0") }
    return code
  }

  // MARK: - Helpers

  /// Splits `s` at its FIRST dot into (bare, suffix) when everything after
  /// that dot is a non-empty run of letters/digits/hyphens/dots (with no
  /// leading, trailing, or doubled dot) -- a purely STRUCTURAL definition of
  /// "looks like it ends in a domain suffix", deliberately not limited to
  /// any curated TLD list. One shared definition, used for BOTH questions
  /// this fix has to ask: is an INPUT token worth peeling, and is a saved
  /// ALIAS/CANONICAL domain-shaped.
  ///
  /// FIRST dot, not last: many countries' everyday domains are two-part
  /// suffixes -- ".co.jp", ".co.uk", ".com.au", ".co.in" -- not the single
  /// ".com" this app's own San-Francisco-built URL vetting was written
  /// around. Peeling only the LAST label left "GitHub.co.jp" reattaching as
  /// "GitHub.co" with the ".jp" silently eaten, and a bare alias "githab"
  /// glued to "githab.co.jp" never matched at all, because the leftover
  /// ".co" was still noise on the comparison. Peeling from the first dot
  /// takes the WHOLE suffix as one unit, whatever shape it has, which is
  /// what makes a brand name recoverable in a domain-suffix style this app
  /// was not built around by default.
  ///
  /// Codex review, PR for #2281, rounds 3-4: an earlier version reused
  /// `InverseTextNormalizer.urlTLDAlt` (the closed, ten-item TLD set
  /// `matcher-set-adversarial-tests` argues for reusing elsewhere) for BOTH
  /// questions, then for only ONE of them, and each split answer left a
  /// suffix outside that list unprotected somewhere -- `Enviousvisper.us`
  /// dropped its ".us" when the list gated the peel trigger; "GitHub.us"
  /// grew a duplicate suffix when the list gated only the dedup check.
  /// `urlTLDAlt` asserts semantic meaning ("this specific string IS a
  /// TLD"), which is the right bar for a POSITIVE identification (deciding
  /// spoken text represents a real URL). Here the bar is lower and
  /// symmetric: "is this worth trying as a suffix", never asserted as fact.
  /// It is not free to be wrong, though (Codex review round 5, P2 --
  /// correcting an earlier version of this comment that claimed it was): a
  /// peeled bare form can coincidentally EXACT-match a real, unrelated
  /// alias, so an over-permissive trigger produces a real wrong correction,
  /// not merely a harmless miss -- alias "v1" turned input "v1.2" into
  /// "VersionOne.2" before a first guard existed, and a looser
  /// "not all-digit" version of that guard still let "v1.2beta" and
  /// "v1.2.3rc1" through (Codex review round 6, P2: a rejected label needs
  /// to catch ALPHANUMERIC version/build tails, not only purely-numeric
  /// ones). The exclusion this function makes is therefore the strictest
  /// one that still matches real DNS policy rather than an arbitrary
  /// tightening: a real TLD label is ALL LETTERS -- current ICANN policy
  /// bars digits and hyphens from the TLD position entirely (unlike an
  /// ordinary hostname label, which permits both) -- so a final label
  /// carrying so much as one digit marks a version number, decimal, or
  /// IP-like token rather than a domain. A purely structural check
  /// otherwise generalizes to every user's vocabulary rather than the ten
  /// TLDs this app happens to vet for URL recognition elsewhere.
  private static func splitDomainSuffix(_ s: String) -> (bare: String, suffix: String)? {
    guard let firstDot = s.firstIndex(of: "."), firstDot > s.startIndex else { return nil }
    let tail = s[s.index(after: firstDot)...]
    guard !tail.isEmpty, tail.first != ".", tail.last != ".",
      tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    else {
      return nil
    }
    let labels = tail.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ !$0.isEmpty }), let lastLabel = labels.last,
      Self.isPlausibleTLDLabel(lastLabel)
    else {
      return nil
    }
    return (String(s[s.startIndex..<firstDot]), String(s[firstDot...]))
  }

  /// True for an all-letters label (the ordinary case), OR a punycode
  /// A-label -- the ASCII-only form DNS actually carries for an
  /// internationalized TLD, always written as `xn--` followed by
  /// alphanumerics and hyphens (Russia's `.рф` is `.xn--p1ai`, e.g.). Real
  /// TLDs are never purely numeric or mixed-alphanumeric OUTSIDE this one
  /// prefixed shape, so accepting punycode here does not reopen the
  /// version-string/IP exclusions (Codex review, PR for #2281, finding P2
  /// round 8): "xn--p1ai" and "v1" are structurally distinguishable by the
  /// `xn--` prefix alone, and nothing that isn't real punycode happens to
  /// start with it.
  private static func isPlausibleTLDLabel(_ label: Substring) -> Bool {
    label.allSatisfy({ $0.isLetter }) || Self.isPunycodeTLDLabel(label)
  }

  /// The punycode-shape half of `isPlausibleTLDLabel`, factored out so
  /// `isDomainShaped` can require it WITHOUT also admitting arbitrary
  /// all-letters labels ("js", "academy", ...) the way the peel trigger
  /// does -- those two questions need different bars for the reasons
  /// `knownDedupTLDs`'s own doc comment gives (Codex review, PR for #2281,
  /// finding P2 round 9: a canonical whose domain is itself an
  /// internationalized name, written in its ASCII punycode form, was not
  /// recognized as domain-shaped at all -- `splitDomainSuffix` peeled it
  /// correctly, but the DEDUP check that decides whether to suppress a
  /// mismatched reattach only consulted the curated real-word TLD list,
  /// which can never contain an `xn--...` string).
  private static func isPunycodeTLDLabel(_ label: Substring) -> Bool {
    let lower = label.lowercased()
    guard lower.hasPrefix("xn--") else { return false }
    let rest = lower.dropFirst(4)
    return !rest.isEmpty && rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
  }

  /// A curated (not exhaustive) set of real TLDs, deliberately much broader
  /// than `InverseTextNormalizer.urlTLDAlt`'s original ten entries so common
  /// ccTLDs (`.us`, `.uk`, `.jp`, ...) are covered, but still a REAL,
  /// vetted list rather than "any letters after a dot". Read ONLY by
  /// `isDomainShaped` -- never by `splitDomainSuffix`'s peel trigger, which
  /// stays purely structural on purpose (see that function's doc comment).
  ///
  /// Why two different bars for what looks like the same question (Codex
  /// review round 6, P1): "is this worth TRYING to peel" tolerates being
  /// wrong for free -- nothing matches, the untouched token comes back.
  /// "Should a peeled suffix be SUPPRESSED because the matched canonical is
  /// already a domain" does not: a purely structural check here means any
  /// dotted brand name with a plausible-looking suffix -- "Node.js",
  /// "D3.js", "Vue.js", "Chart.js" are all real, common product names in
  /// exactly this shape -- gets misclassified as a domain and silently
  /// swallows a suffix the user actually said ("nodejs.com" -> "Node.js").
  /// A real TLD list is the only mechanical way to tell "GitHub.com" (a
  /// domain) from "Node.js" (a product name that happens to end in a
  /// dot-suffix): both are ALL-LETTERS after the dot, so no structural rule
  /// -- however tightened -- can separate them.
  /// KNOWN LIMIT, accepted rather than chased further (founder call,
  /// Codex review round 7, P2): this list is CURATED, not exhaustive --
  /// ICANN's real root zone has 1,500+ entries, and any hand-picked subset
  /// will always be missing one (round 7 named "GitHub.academy" as a real
  /// gTLD this list omits). `matcher-set-adversarial-tests`'s
  /// generalisation gate is right that a hand-authored set is a prediction
  /// about users we haven't met -- the two mechanisms that would actually
  /// close it are bundling a maintained public-suffix authority, or letting
  /// a word's OWNER mark it as a domain explicitly rather than the app
  /// guessing from its text -- and both are real feature-sized additions,
  /// not a fix for this bug. The failure mode this list still has is
  /// narrow: it needs BOTH a saved word shaped like a domain that ISN'T one
  /// AND a separately-dictated real domain suffix glued onto its bare
  /// alias, and (measured against the shipped pack and this founder's own
  /// live vocabulary while building this fix) zero words anywhere in this
  /// app are shaped like a domain at all today.
  private static let knownDedupTLDs: Set<String> = [
    "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name",
    "pro", "coop", "museum", "aero", "jobs", "mobi", "travel", "tel", "asia", "cat", "xxx",
    "io", "co", "dev", "app", "xyz", "me", "tv", "cc", "ai", "tech",
    "online", "site", "store", "shop", "cloud", "live", "life", "world", "media", "news",
    "agency", "studio", "design", "digital", "email", "expert", "guide", "help",
    "network", "software", "systems", "tools", "works", "so", "academy",
    "us", "uk", "ca", "au", "de", "fr", "jp", "cn", "in", "br",
    "ru", "es", "it", "nl", "se", "no", "dk", "fi", "pl", "ch",
    "at", "be", "pt", "gr", "ie", "nz", "sg", "hk", "tw", "kr",
    "mx", "ar", "za", "il", "ae", "sa", "tr", "id", "my", "th",
    "ph", "vn", "eu", "uy", "cl", "pe", "ec", "ve", "cr",
  ]

  /// True when `s` itself ends in a REAL domain-shaped suffix -- used to
  /// decide whether a saved alias/canonical is a domain in its own right,
  /// in which case a peeled suffix must never be appended to it a second
  /// time (Codex review, PR for #2281, finding P2 rounds 2-4, 6, 9). A
  /// punycode label (an internationalized domain's ASCII form) counts even
  /// though it can never appear in `knownDedupTLDs` -- that list holds
  /// real WORDS, and no curated word list can contain every possible
  /// `xn--...` string, but the `xn--` shape itself is unambiguous evidence
  /// on its own (round 9).
  ///
  /// A NATIVE-SCRIPT internationalized label (a real ccTLD written in its
  /// own Unicode form, never converted to punycode -- ".рф" as literal
  /// Cyrillic, not ".xn--p1ai") also counts, for a reason the curated-list
  /// exclusion for "Node.js" does NOT apply to here (local Codex sweep of
  /// PR #2298's cloud findings, same day): the false-positive risk that
  /// keeps this function from accepting "any all-letters label" is
  /// specifically an ENGLISH product-name risk (".js", ".io" as common
  /// English computing suffixes on real brand names). No ordinary English
  /// or Latin-script brand name coincidentally ends in a run of Cyrillic,
  /// CJK, or Arabic-script characters, so accepting "all-letters AND
  /// contains at least one non-ASCII character" here carries none of that
  /// risk while closing the gap for any real IDN this app cannot curate by
  /// string (there is no bounded list of "real internationalized domains"
  /// any more than there is of ASCII ones).
  private static func isDomainShaped(_ s: String) -> Bool {
    guard let split = Self.splitDomainSuffix(s) else { return false }
    guard let lastLabelSub = split.suffix.split(separator: ".").last else { return false }
    if Self.isPunycodeTLDLabel(lastLabelSub) { return true }
    if lastLabelSub.allSatisfy({ $0.isLetter }), lastLabelSub.contains(where: { !$0.isASCII }) {
      return true
    }
    return Self.knownDedupTLDs.contains(lastLabelSub.lowercased())
  }

  private func stripPunctuation(_ token: String) -> String {
    splitPunctuation(token).core
  }

  private func splitPunctuation(_ token: String) -> (prefix: String, core: String, suffix: String) {
    var prefix = ""
    var core = token
    var suffix = ""
    while let first = core.first, !first.isLetter && !first.isNumber {
      prefix.append(first)
      core = String(core.dropFirst())
    }
    while let last = core.last, !last.isLetter && !last.isNumber {
      suffix = String(last) + suffix
      core = String(core.dropLast())
    }
    return (prefix, core, suffix)
  }
}
