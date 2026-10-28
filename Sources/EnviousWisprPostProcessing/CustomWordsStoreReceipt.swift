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
