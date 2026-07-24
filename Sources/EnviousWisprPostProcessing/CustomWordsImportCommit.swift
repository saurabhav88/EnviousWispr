import EnviousWisprCore
import Foundation

// Atomic commit for a reviewed Custom Words import (#1665, epic #1619 PR-F2b).
//
// One write applies every approved addition AND replacement, or nothing at
// all. `addBatch` cannot express Replace, and two writes would be exactly the
// partial-commit failure this epic exists to avoid.
//
// KEY SPACE: everything here is a PERSISTENCE question — "would these occupy
// the same slot in stored data?" — so it uses the persistence key that mirrors
// `CustomWordsManager`'s own dedup and `WordCorrector`'s lookup, never the
// compare engine's stronger matching key (PR-F2a, #1661).

/// The effective word list Review was built from, used to detect a library
/// that changed underneath an open review.
package struct CustomWordsImportLibrarySnapshot: Sendable, Equatable {
  /// Per-word identity + tuning, deliberately excluding usage history
  /// (`frequencyUsed` / `lastUsed`) and the runtime-only `source` tag: a
  /// dictation that merely bumped a counter must not invalidate a review.
  private struct Entry: Sendable, Hashable {
    let id: UUID
    let canonical: String
    let aliases: [String]
    let category: WordCategory
    let priority: Int
    let forceReplace: Bool
    let caseSensitive: Bool
    let minSimilarityOverride: Double?

    init(_ word: CustomWord) {
      id = word.id
      canonical = word.canonical
      aliases = word.aliases
      category = word.category
      priority = word.priority
      forceReplace = word.forceReplace
      caseSensitive = word.caseSensitive
      minSimilarityOverride = word.minSimilarityOverride
    }
  }

  private let entries: Set<Entry>

  /// `words` must be the EFFECTIVE list (active built-ins + user words), which
  /// is what the coordinator publishes and what Review renders — never the raw
  /// user-words array, which would mismatch every baseline by the built-ins.
  package init(words: [CustomWord]) {
    entries = Set(words.map(Entry.init))
  }

  /// Order-independent, keyed by id. Built-in ids are minted per launch but
  /// stable within a process, and both sides of any comparison live in one
  /// process run.
  package func semanticallyMatches(_ words: [CustomWord]) -> Bool {
    entries == Set(words.map(Entry.init))
  }
}

/// One approved Replace: the local word to overwrite, and the imported values.
package struct CustomWordsImportReplacement: Sendable, Equatable {
  package let existingID: UUID
  package let candidate: CustomWordsImportCandidate

  package init(existingID: UUID, candidate: CustomWordsImportCandidate) {
    self.existingID = existingID
    self.candidate = candidate
  }
}

package struct CustomWordsImportCommitPlan: Sendable, Equatable {
  package let baseline: CustomWordsImportLibrarySnapshot
  package let additions: [CustomWordsImportCandidate]
  package let replacements: [CustomWordsImportReplacement]
  /// Carried from the originating `CustomWordsImportBatch.enrichmentEligible`
  /// (#1701 Chunk 2), retained by `CustomWordsImportFlowModel` from
  /// `loadCandidates()` through `confirm()` — nothing about the originating
  /// batch otherwise survives to commit time. `commitImport` reads this once,
  /// inside its own locked transaction, to decide whether freshly-added words
  /// enter the bulk-import-enrichment queue. Never applies to Replace: a
  /// machine guess must not overwrite hand-tuned aliases either way.
  package let enrichmentEligible: Bool

  package init(
    baseline: CustomWordsImportLibrarySnapshot,
    additions: [CustomWordsImportCandidate],
    replacements: [CustomWordsImportReplacement],
    enrichmentEligible: Bool = true
  ) {
    self.baseline = baseline
    self.additions = additions
    self.replacements = replacements
    self.enrichmentEligible = enrichmentEligible
  }

  /// True when the commit would change nothing — an all-Skip confirm. Such a
  /// commit writes no file and takes no backup.
  package var isEmpty: Bool { additions.isEmpty && replacements.isEmpty }
}

/// One manager-level read of the persisted library plus its durable
/// bulk-import-enrichment total, returned together so a caller can never see
/// one without the other (#1701 Chunk 2). Deliberately NOT
/// `CustomWordsImportLibrarySnapshot` above — that type is Review's baseline
/// (excludes usage history, compares by value for staleness); this one is the
/// AppKit-layer read path for `CustomWordsCoordinator.loadSnapshot()`, always
/// initialized together so the total can never be read stale relative to the
/// words it describes.
package struct CustomWordsLibrarySnapshot: Sendable, Equatable {
  package let words: [CustomWord]
  /// `nil` = no bulk-import-enrichment run in progress. A number is the
  /// honest original size of the current run, only ever extended (never
  /// reset smaller) by a later import committing mid-drain.
  package let pendingEnrichmentBatchTotal: Int?

  package init(words: [CustomWord], pendingEnrichmentBatchTotal: Int?) {
    self.words = words
    self.pendingEnrichmentBatchTotal = pendingEnrichmentBatchTotal
  }
}

/// One bulk-import-enrichment checkpoint outcome: stable word identity plus
/// generated aliases ONLY — deliberately never a full `CustomWord` snapshot,
/// which could go stale across the `await` between the background
/// coordinator reading a word and checkpointing its result (#1701 Chunk 2).
/// `CustomWordsManager.applyEnrichmentResults` reloads the live word by this
/// `id`, under the same lock it writes with, and appends only these aliases
/// to whatever is there right now.
package struct CustomWordEnrichmentResult: Sendable, Equatable {
  package let id: UUID
  package let generatedAliases: [String]

  package init(id: UUID, generatedAliases: [String]) {
    self.id = id
    self.generatedAliases = generatedAliases
  }
}

/// The full outcome of one `CustomWordsManager.applyEnrichmentResults` call
/// (Codex Chunk 2 review finding 6): the resulting snapshot, AND — separately
/// from the caller's raw input — exactly which results actually applied and
/// exactly which aliases actually landed for each, after in-word dedup AND
/// cross-word alias-ownership enforcement (finding 3). A TOUCHED word (found
/// and still pending) always appears here, with fewer aliases than it sent —
/// possibly zero, if every one collided or was redundant with its own
/// canonical — never more. A word is ABSENT only when its result was skipped
/// entirely (not found, or no longer pending) — the input alone is never
/// proof of what was actually persisted.
package struct CustomWordsEnrichmentCheckpointOutcome: Sendable, Equatable {
  package let snapshot: CustomWordsLibrarySnapshot
  package let applied: [CustomWordEnrichmentResult]

  package init(snapshot: CustomWordsLibrarySnapshot, applied: [CustomWordEnrichmentResult]) {
    self.snapshot = snapshot
    self.applied = applied
  }
}

package struct CustomWordsImportCommitReceipt: Sendable, Equatable {
  package let addedIDs: [UUID]
  package let replacedIDs: [UUID]
  /// Aliases dropped by enforcement, covering source aliases AND colliding
  /// `suggestedAliases`. The AI channel gets no compare-time disclosure, so
  /// this receipt is its only reporting path.
  package let droppedAliasCollisions: [CustomWordsImportAliasCollision]
  /// The durable bulk-import-enrichment total immediately after this commit
  /// (#1701 Chunk 2) — `nil` when no run is in progress. Lets
  /// `CustomWordsCoordinator` adopt the fresh total from the SAME commit that
  /// just wrote it, without a separate follow-up read.
  package let pendingEnrichmentBatchTotal: Int?

  package init(
    addedIDs: [UUID],
    replacedIDs: [UUID],
    droppedAliasCollisions: [CustomWordsImportAliasCollision],
    pendingEnrichmentBatchTotal: Int? = nil
  ) {
    self.addedIDs = addedIDs
    self.replacedIDs = replacedIDs
    self.droppedAliasCollisions = droppedAliasCollisions
    self.pendingEnrichmentBatchTotal = pendingEnrichmentBatchTotal
  }
}

/// `LocalizedError` because the coordinator surfaces `localizedDescription`
/// straight to the user — without it they would get Foundation's generic
/// "operation could not be completed" instead of being told, truthfully, that
/// nothing was changed.
package enum CustomWordsImportCommitError: LocalizedError, Sendable, Equatable {
  /// The library changed underneath the open review — nothing was written.
  case staleLibrary
  /// The plan references a word that is not in the library, or is malformed.
  case invalidPlan
  /// The existing file exists but could not be read — fail closed (PR-P0).
  case unreadableLibrary

  package var errorDescription: String? {
    switch self {
    case .staleLibrary:
      return "Your word list changed while you were reviewing. Nothing was imported."
    case .invalidPlan:
      return "This import could not be applied. Nothing was changed."
    case .unreadableLibrary:
      return "Your saved words could not be read. Nothing was imported. Try again."
    }
  }
}
