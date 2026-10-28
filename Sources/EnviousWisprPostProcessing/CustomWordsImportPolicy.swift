import EnviousWisprCore
import Foundation

/// Reviewed-import policy for the dictionary (#4086): what one confirmed import
/// plan does to the on-disk file — stale check, replacements, additions,
/// enrichment queueing, canonical uniqueness, alias collision enforcement — plus
/// the field-level Replace and Add rules it applies. Extracted verbatim from
/// `CustomWordsManager.commitImport`. The transform runs inside
/// `CustomWordsFileStore.performLockedTransaction` against the freshly loaded file;
/// it never touches the disk itself. The pre-import backup stays the store's: the
/// caller passes it in as `backup`, and the transform invokes it at the same point
/// it always ran, still under the lock and before the save.
enum CustomWordsImportPolicy {
  typealias File = CustomWordsFileStore.CustomWordsFile

  static func commit(
    _ plan: CustomWordsImportCommitPlan, to file: inout File, builtins: [BuiltinWord],
    backup: () -> Void
  ) throws -> (value: (CustomWordsImportCommitReceipt, [CustomWord]?), shouldSave: Bool) {
    // (1) Stale check against the EFFECTIVE list Review was built from —
    // now against the freshly, LOCKED load, so it is more current than
    // before, never weaker (#1690).
    let effective = CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins)
    guard plan.baseline.semanticallyMatches(effective) else {
      throw CustomWordsImportCommitError.staleLibrary
    }

    // An all-Skip confirm changes nothing: no backup, no write.
    guard !plan.isEmpty else {
      return (
        (
          CustomWordsImportCommitReceipt(
            addedIDs: [], replacedIDs: [], droppedAliasCollisions: []), nil
        ), false
      )
    }

    // (2) Replacements. `existingID` may name a built-in, which lives in
    // `builtinDefaults` rather than `file.words`.
    //
    // Two replacements aimed at the SAME existing word are rejected, not
    // silently resolved: both would apply against the original entry and the
    // later one would quietly win, so the user would get an import they did
    // not approve while the receipt claimed both landed.
    guard Set(plan.replacements.map(\.existingID)).count == plan.replacements.count else {
      throw CustomWordsImportCommitError.invalidPlan
    }
    var replacedIDs: [UUID] = []
    for replacement in plan.replacements {
      guard let existing = effective.first(where: { $0.id == replacement.existingID }) else {
        throw CustomWordsImportCommitError.invalidPlan
      }
      let merged = Self.applyReplace(existing: existing, candidate: replacement.candidate)
      guard !merged.canonical.isEmpty else { throw CustomWordsImportCommitError.invalidPlan }

      // A built-in stays hidden only while some user word still carries its
      // canonical, so a Replace that MOVES the canonical away has to retire the
      // built-in too — otherwise it reappears beside the replacement and the
      // user gets two words where they approved one.
      //
      // This is checked before the branch on purpose: it applies whether the
      // override is being created now (built-in never edited) or already exists
      // in `file.words` (built-in edited earlier, which is why the canonical
      // still matches). Guarding only the create case leaves the identical bug
      // reachable through the update case.
      if let builtin = builtins.first(where: {
        $0.word.canonical.caseInsensitiveCompare(existing.canonical) == .orderedSame
      }),
        builtin.word.canonical.caseInsensitiveCompare(merged.canonical) != .orderedSame,
        !file.deletedBuiltinIds.contains(builtin.id)
      {
        file.deletedBuiltinIds.append(builtin.id)
      }

      if let index = file.words.firstIndex(where: { $0.id == existing.id }) {
        file.words[index] = merged
      } else {
        file.words.append(merged)
      }
      replacedIDs.append(existing.id)
    }

    // (3) Additions — fresh UUID each; unspecified fields take type defaults,
    // since there is no existing word to preserve from.
    //
    // Eligible additions enter the bulk-import-enrichment queue here
    // (#1701 Chunk 2) — `plan.enrichmentEligible` is per-BATCH, so it
    // applies uniformly to every addition in this plan, never to a
    // Replace (a machine guess must not overwrite hand-tuned aliases
    // either way, matching D15's existing rule for suggestedAliases).
    var addedIDs: [UUID] = []
    var newlyPendingCount = 0
    for candidate in plan.additions {
      var word = Self.makeAddition(from: candidate)
      guard !word.canonical.isEmpty else { throw CustomWordsImportCommitError.invalidPlan }
      if plan.enrichmentEligible {
        word.enrichmentPending = true
        newlyPendingCount += 1
      }
      file.words.append(word)
      addedIDs.append(word.id)
    }
    // Atomically, in this SAME transaction as the flags just set above
    // (never left "untouched" while flags change underneath it): extend
    // an already-active total, or start one. Never reset smaller — a
    // second import committing mid-drain must not lose the first run's
    // remaining count. When the stored total is nil, it is NOT safe to
    // assume nothing was pending before this commit (Codex Chunk 2 review
    // finding 2a) — that is the same defensive "should never happen"
    // state `repairPendingEnrichmentTotalIfNeeded` exists to heal, and if
    // this commit wrote a total covering only its OWN new additions, the
    // total would go non-nil and the repair path would never fire again,
    // permanently undercounting. Base a fresh total on every word
    // currently pending (already includes this commit's own additions,
    // appended above), never just this commit's delta.
    if newlyPendingCount > 0 {
      if let existingTotal = file.pendingEnrichmentBatchTotal {
        file.pendingEnrichmentBatchTotal = existingTotal + newlyPendingCount
      } else {
        file.pendingEnrichmentBatchTotal = file.words.filter(\.enrichmentPending).count
      }
    }

    let touchedIDs = Set(addedIDs + replacedIDs)

    // (4) Canonical uniqueness, and no imported canonical may land on an alias
    // held by a different word this import did not replace. F2c never offers a
    // decision that produces either shape, so reaching here means a bad plan.
    var resulting = CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins)
    var seenCanonicals: [String: UUID] = [:]
    for word in resulting {
      let key = CustomWordsMutationPolicy.importPersistenceKey(word.canonical)
      if let owner = seenCanonicals[key], owner != word.id {
        throw CustomWordsImportCommitError.invalidPlan
      }
      seenCanonicals[key] = word.id
    }
    for word in resulting where touchedIDs.contains(word.id) {
      let canonicalKey = CustomWordsMutationPolicy.importPersistenceKey(word.canonical)
      for other in resulting where other.id != word.id && !touchedIDs.contains(other.id) {
        if other.aliases.contains(where: { CustomWordsMutationPolicy.importPersistenceKey($0) == canonicalKey }) {
          throw CustomWordsImportCommitError.invalidPlan
        }
      }
    }

    // (5) Alias enforcement on the APPLIED result, so two replacements in one
    // plan are covered, not just additions. Only words this import touched can
    // lose an alias — an untouched word is not this import's to edit.
    // Touched words are resolved in APPLY order (replacements in plan order,
    // then additions), not the merged library's own order — otherwise which of
    // two claimants keeps a shared alias would depend on incidental storage
    // order rather than on the plan the user approved.
    let (filtered, dropped) = Self.enforceAliases(
      on: resulting, touchedOrder: replacedIDs + addedIDs)
    for word in filtered where touchedIDs.contains(word.id) {
      if let index = file.words.firstIndex(where: { $0.id == word.id }) {
        file.words[index].aliases = word.aliases
        // A collision drop takes the alias's learned mark with it (#996):
        // the one provenance rule, re-applied after the last alias edit.
        file.words[index] = CustomWordsMutationPolicy.sanitizeForPersistence(file.words[index])
      }
    }

    // (6) Best-effort backup, WHILE THE LOCK IS STILL HELD, immediately
    // before requesting the save — so it snapshots the exact same
    // pre-transaction live file this locked transform just loaded, not a
    // separately fetched read (#1690). A backup failure logs and
    // proceeds: correctness comes from the atomic write and the strict
    // loader, not from the backup existing.
    backup()

    // (7) Compute the post-write publication shape now; `performLockedTransaction`
    // saves `file` right after this closure returns, so this IS what will be on disk.
    resulting = CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins)
    let receipt = CustomWordsImportCommitReceipt(
      addedIDs: addedIDs, replacedIDs: replacedIDs, droppedAliasCollisions: dropped,
      pendingEnrichmentBatchTotal: file.pendingEnrichmentBatchTotal)
    return ((receipt, resulting), true)
  }

  /// Field-level Replace, per the adopted plan's table. `id`, `frequencyUsed`,
  /// and `lastUsed` are always preserved; `canonical` is always taken; every
  /// other field is taken ONLY when the source actually supplied it, so a
  /// source with no opinion can never blank hand-tuned configuration.
  /// `suggestedAliases` are never applied on Replace — a machine guess must
  /// not overwrite hand-tuned aliases.
  static func applyReplace(
    existing: CustomWord, candidate: CustomWordsImportCandidate
  ) -> CustomWord {
    func supplied<Value>(_ field: CustomWordsImportField<Value>, else fallback: Value) -> Value {
      if case .supplied(let value) = field { return value }
      return fallback
    }
    let aliases = supplied(candidate.aliases, else: existing.aliases)
    // Learned provenance (#996) follows the same authority rule: a backup
    // supplies it (an empty list and a nil date are authoritative clears),
    // every other source has no opinion and the live marks stay. The helper
    // then prunes any supplied mark whose alias is not among the stored ones.
    return CustomWordsMutationPolicy.sanitizeForPersistence(
      CustomWord(
        id: existing.id,
        canonical: candidate.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
        aliases: aliases,
        category: supplied(candidate.category, else: existing.category),
        priority: supplied(candidate.priority, else: existing.priority),
        forceReplace: supplied(candidate.forceReplace, else: existing.forceReplace),
        caseSensitive: supplied(candidate.caseSensitive, else: existing.caseSensitive),
        source: .user,
        frequencyUsed: existing.frequencyUsed,
        lastUsed: existing.lastUsed,
        minSimilarityOverride: supplied(
          candidate.minSimilarityOverride, else: existing.minSimilarityOverride),
        learnedAliases: supplied(candidate.learnedAliases, else: existing.learnedAliases),
        learnedAt: supplied(candidate.learnedAt, else: existing.learnedAt)
      ))
  }

  /// A new word from a candidate. Unspecified fields fall back to the type's
  /// own defaults — there is no existing word to preserve from. Add is the ONE
  /// place AI `suggestedAliases` are persisted, after the source's own spellings.
  static func makeAddition(from candidate: CustomWordsImportCandidate) -> CustomWord {
    func supplied<Value>(_ field: CustomWordsImportField<Value>, else fallback: Value) -> Value {
      if case .supplied(let value) = field { return value }
      return fallback
    }
    let sourceAliases = supplied(candidate.aliases, else: [])
    var union = CustomWordsMutationPolicy.sanitizeAliases(sourceAliases)
    var seen = Set(union.map(CustomWordsMutationPolicy.importPersistenceKey))
    for suggestion in CustomWordsMutationPolicy.sanitizeAliases(candidate.suggestedAliases)
    where seen.insert(CustomWordsMutationPolicy.importPersistenceKey(suggestion)).inserted {
      union.append(suggestion)
    }
    return CustomWordsMutationPolicy.sanitizeForPersistence(
      CustomWord(
        canonical: candidate.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
        aliases: union,
        category: supplied(candidate.category, else: .general),
        priority: supplied(candidate.priority, else: 0),
        forceReplace: supplied(candidate.forceReplace, else: false),
        caseSensitive: supplied(candidate.caseSensitive, else: false),
        source: .user,
        minSimilarityOverride: supplied(candidate.minSimilarityOverride, else: nil),
        learnedAliases: supplied(candidate.learnedAliases, else: []),
        learnedAt: supplied(candidate.learnedAt, else: nil)
      ))
  }

  /// Guarantees no alias this import touched is left ambiguous, whatever
  /// Review believed. Precedence, in order: a word's own canonical beats its
  /// own redundant alias (dropped silently, it is not ambiguity); any other
  /// word's canonical beats an alias; an untouched incumbent's alias beats any
  /// imported one; among touched words, earlier in `touchedOrder` wins.
  ///
  /// `touchedOrder` is the APPLY order, so a shared alias resolves by the plan
  /// the user approved rather than by incidental storage order.
  static func enforceAliases(
    on words: [CustomWord], touchedOrder: [UUID]
  ) -> (words: [CustomWord], dropped: [CustomWordsImportAliasCollision]) {
    // Ownership DATA comes from `WordCorrector` (#1667), and the collision
    // DECISION comes from its `resolveAliasOwnership` (#1672) — the same
    // function `CustomWordsImportCompareEngine.detectAliasCollisions` calls.
    // This function used to mirror both itself, keyed on `importPersistenceKey`
    // (no no-space surface at all, so an imported alias equal to an existing
    // multi-word canonical's space-free form was KEPT here even once the
    // compare screen had learned to disclose it), then later restated the
    // shared blocker/decisive-owner logic as its own local copy. Doing either
    // again is the defect this ends: the screen said one thing and the commit
    // did another, twice, before this.
    var result = words
    // Last wins, and the list must not be assumed id-unique. Renaming a
    // built-in stores a user override carrying the built-in's OWN id while
    // `mergedWords` keeps showing the built-in (its canonical no longer
    // matches any user word), so within one process the two share an id and
    // `uniqueKeysWithValues` would trap on a state the manager itself creates.
    // `mergedWords` returns built-ins first, so last-wins resolves to the
    // user's own word — the one an import can legitimately touch.
    let indexByID = Dictionary(
      result.indices.map { (result[$0].id, $0) }, uniquingKeysWith: { _, last in last })

    // Canonical ownership is resolved by handing the WHOLE final array — the
    // exact array the runtime corrector will build its own lookups from — to
    // the one authority, in its own FINAL STORAGE order. A first version tried
    // to replay just the touched canonicals in APPLY order instead. That is
    // wrong: the compound namespace's last-write-wins rule is about storage
    // order, because that is the order `buildExactTriggerIndex` iterates when
    // it runs for real on the saved file. Apply order can name a winner the
    // corrector itself would never produce (grounded review r7, #1667).
    //
    // Touched words' proposed final aliases are stripped from this seed,
    // because their surviving aliases are decided by the loop below in the
    // plan's approved order — that precedence is a genuinely separate,
    // already-established rule this pass must not disturb. Canonicals stay,
    // so ownership is still resolved from the complete final vocabulary.
    let touchedIndices = Set(touchedOrder.compactMap { indexByID[$0] })
    let ownershipSeed = result.indices.map { wordIndex -> CustomWord in
      var word = result[wordIndex]
      if touchedIndices.contains(wordIndex) { word.aliases = [] }
      return word
    }
    var index = WordCorrector.buildExactTriggerIndex(words: ownershipSeed)

    var dropped: [CustomWordsImportAliasCollision] = []
    for id in touchedOrder {
      guard let wordIndex = indexByID[id] else { continue }
      let word = result[wordIndex]
      let canonicalKey = CustomWordsMutationPolicy.importPersistenceKey(word.canonical)
      var kept: [String] = []
      for alias in word.aliases {
        if CustomWordsMutationPolicy.importPersistenceKey(alias).isEmpty { continue }
        // Redundant with the word's own canonical: silently removed, never
        // reported — it is not an ambiguity anyone needs to hear about.
        if CustomWordsMutationPolicy.importPersistenceKey(alias) == canonicalKey { continue }

        // Blocker detection, decisive-owner selection, and the "holding a key
        // isn't always intercepting it" gate are no longer restated here —
        // `resolveAliasOwnership` is the one shared answer both this commit
        // path and the preview (`CustomWordsImportCompareEngine`) call, so
        // there is nothing left in either file to drift apart again (#1672).
        switch index.resolveAliasOwnership(for: alias, excludingOwnerID: word.id) {
        case .noClaims:
          continue
        case .blocked(let owner):
          dropped.append(CustomWordsImportAliasCollision(alias: alias, heldBy: owner.wordID))
        case .available(let claims):
          // Gap-fill, never overwrite. An alias reaches here unblocked for one
          // of three reasons: nobody holds the key, this word already holds
          // it, or a compound holder declines to intercept. In that last case
          // the holder must STAY registered, because at runtime an alias only
          // ever fills an empty compound slot. Overwriting handed the key to
          // the wrong word.
          index.gapFill(
            claims,
            owner: WordCorrector.TriggerOwner(
              wordID: word.id, canonical: word.canonical, isPack: false)
          )
          kept.append(alias)
        }
      }
      result[wordIndex].aliases = kept
    }
    return (result, dropped)
  }
}
