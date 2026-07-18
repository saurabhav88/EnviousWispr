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

  package init(
    baseline: CustomWordsImportLibrarySnapshot,
    additions: [CustomWordsImportCandidate],
    replacements: [CustomWordsImportReplacement]
  ) {
    self.baseline = baseline
    self.additions = additions
    self.replacements = replacements
  }

  /// True when the commit would change nothing — an all-Skip confirm. Such a
  /// commit writes no file and takes no backup.
  package var isEmpty: Bool { additions.isEmpty && replacements.isEmpty }
}

package struct CustomWordsImportCommitReceipt: Sendable, Equatable {
  package let addedIDs: [UUID]
  package let replacedIDs: [UUID]
  /// Aliases dropped by enforcement, covering source aliases AND colliding
  /// `suggestedAliases`. The AI channel gets no compare-time disclosure, so
  /// this receipt is its only reporting path.
  package let droppedAliasCollisions: [CustomWordsImportAliasCollision]

  package init(
    addedIDs: [UUID],
    replacedIDs: [UUID],
    droppedAliasCollisions: [CustomWordsImportAliasCollision]
  ) {
    self.addedIDs = addedIDs
    self.replacedIDs = replacedIDs
    self.droppedAliasCollisions = droppedAliasCollisions
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
