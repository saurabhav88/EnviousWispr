import EnviousWisprCore
import Foundation

/// What one dictionary file transaction did (#4086). The manager returns it after its
/// serial file worker finished the whole locked transaction, so the caller never reads
/// a half-done result.
package struct CustomWordsStoreReceipt<Value: Sendable>: Sendable {
  package let value: Value
  /// True only when the durable write finished. A transaction that found nothing to
  /// change returns normally with `false`; that is not a save.
  package let committed: Bool

  package init(value: Value, committed: Bool) {
    self.value = value
    self.committed = committed
  }
}

/// A delete's result: the library after it, and the words it actually took away, read
/// under the same lock (#4086). A refusal for a learned pair is derived from `removed`,
/// never from what the caller's list believed was there.
package struct CustomWordsRemoval: Sendable, Equatable {
  package let words: [CustomWord]
  package let removed: [CustomWord]

  package init(words: [CustomWord], removed: [CustomWord]) {
    self.words = words
    self.removed = removed
  }
}

/// An edit's result: the library after it, and the word as it was before the edit and as
/// it was saved, both read under the same lock (#4086). `before` is nil when the target
/// was not in the library; `after` is nil when the edit did not apply.
package struct CustomWordsEdit: Sendable, Equatable {
  package let words: [CustomWord]
  package let before: CustomWord?
  package let after: CustomWord?

  package init(words: [CustomWord], before: CustomWord?, after: CustomWord?) {
    self.words = words
    self.before = before
    self.after = after
  }
}

/// A read of the saved library on the file worker (#4086). The failure travels with the
/// result, because the store's `lastLoadFailure` belongs to the worker and the caller
/// must not read it afterwards from another thread.
package enum CustomWordsReadResult: Sendable, Equatable {
  case loaded(CustomWordsLibrarySnapshot)
  case failed(CustomWordsInitialLoadFailure)
}

/// Aliases generated for one imported contact name (#4086). `canonical` is the spelling
/// they were generated from: a word renamed since then does not receive them.
package struct GeneratedAliasProposal: Sendable, Equatable {
  package let id: UUID
  package let canonical: String
  package let aliases: [String]

  package init(id: UUID, canonical: String, aliases: [String]) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
  }
}

/// One edit as what the person changed, against the word they were shown (#4086). It is
/// never a whole replacement word: under the lock the transaction applies only these
/// changes to the word as it is now, so a change saved meanwhile (a usage count, a learned
/// sound-alike, an edit in another window) is kept or reported, never overwritten.
/// The merge rules: `CustomWordsMutationPolicy.merge(_:onto:)`.
package struct CustomWordEditRequest: Sendable, Equatable {
  package var id: UUID { base.id }
  /// The word as the editor showed it. Compared under the lock; never written.
  package let base: CustomWord
  /// Each is nil when the person left that field as it was.
  package let canonical: String?
  package let category: WordCategory?
  package let priority: Int?
  package let forceReplace: Bool?
  package let caseSensitive: Bool?
  package let minSimilarityOverride: Double??
  /// Sound-alikes the person added and removed, against `base`, by their exact spelling,
  /// so a change of capitals alone is a removal plus an addition with the same key
  /// (trimmed, lowercased); the merge puts the new spelling in the old one's place.
  package let addedAliases: [String]
  package let removedAliases: [String]
  /// Kept sound-alikes whose learned mark the person removed: removing a sparkled chip and
  /// typing it back makes it their own (`CustomWordSuggestionFlow.removeAlias`). Only these
  /// marks go; a mark learned after the editor opened stays.
  package let unmarkedAliases: [String]
  /// True when the person was shown the whole sound-alike list (the editor): a sound-alike
  /// removed or renamed meanwhile then makes their list out of date. False for a request
  /// that only appends (Quick Add).
  package let needsBaseAliases: Bool

  /// The fields `draft` changed against `base`, as the editor's Save sends them.
  package init(base: CustomWord, draft: CustomWord) {
    func changed<T: Equatable>(_ value: T, _ original: T) -> T? { value == original ? nil : value }
    let key = CustomWordsMutationPolicy.importPersistenceKey
    let draftCanonical = draft.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseSpellings = Set(base.aliases)
    let draftAliases = draft.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let draftSpellings = Set(draftAliases)
    var seen = Set<String>()
    self.base = base
    canonical = changed(draftCanonical, base.canonical)
    category = changed(draft.category, base.category)
    priority = changed(draft.priority, base.priority)
    forceReplace = changed(draft.forceReplace, base.forceReplace)
    caseSensitive = changed(draft.caseSensitive, base.caseSensitive)
    minSimilarityOverride =
      draft.minSimilarityOverride == base.minSimilarityOverride
      ? nil : .some(draft.minSimilarityOverride)
    addedAliases = draftAliases.filter {
      !baseSpellings.contains($0) && seen.insert(key($0)).inserted
    }
    removedAliases = base.aliases.filter { !draftSpellings.contains($0) }
    let draftKeys = Set(draftAliases.map(key))
    let draftMarks = Set(draft.learnedAliases.map(key))
    unmarkedAliases = base.learnedAliases.filter {
      draftKeys.contains(key($0)) && !draftMarks.contains(key($0))
    }
    needsBaseAliases = true
  }

  /// Quick Add's request: add one spelling to the word it was shown, nothing else.
  package init(appending spelling: String, to base: CustomWord) {
    self.base = base
    canonical = nil
    category = nil
    priority = nil
    forceReplace = nil
    caseSensitive = nil
    minSimilarityOverride = nil
    let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    addedAliases = trimmed.isEmpty ? [] : [trimmed]
    removedAliases = []
    unmarkedAliases = []
    needsBaseAliases = false
  }
}

/// What an edit did (#4086). Transient: never persisted.
package enum CustomWordEditOutcome: Sendable, Equatable {
  /// The edit was written. Both words are read under the same lock.
  case saved(before: CustomWord, after: CustomWord)
  /// The word already holds every change asked for; nothing was written.
  case unchanged(CustomWord)
  /// The word is no longer in the library. Nothing was written and nothing was recreated.
  case targetGone
  /// A change saved meanwhile overlaps this edit. Nothing was written.
  case conflict(current: CustomWord)
}

/// An edit's result: the library after the transaction and what the edit did.
package struct CustomWordsEditResult: Sendable, Equatable {
  package let words: [CustomWord]
  package let outcome: CustomWordEditOutcome

  package init(words: [CustomWord], outcome: CustomWordEditOutcome) {
    self.words = words
    self.outcome = outcome
  }
}
