import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// Manages custom word state, CRUD operations, and persistence.
@MainActor @Observable
final class CustomWordsCoordinator {
  var customWords: [CustomWord] = []
  var customWordError: String?
  /// Set when the launch-time load failed (#1646) so Your Words can show an
  /// honest banner instead of a silent empty list. `.unreadable`: the file is
  /// intact, nothing was changed. `.corrupted`: it was archived for recovery.
  private(set) var wordsLoadFailureAtLaunch: CustomWordsInitialLoadFailure?

  let suggestionService = WordSuggestionService()
  /// The reused on-device alias generator, exposed as the narrow protocol so the
  /// composition root can wire it into the contacts-import coordinator without
  /// naming a PostProcessing type (keeps the root's import surface minimal).
  var aliasSuggester: any AliasSuggesting { suggestionService }

  /// Called after any mutation so the former root state can sync words to pipelines.
  var onWordsChanged: (([CustomWord]) -> Void)?

  private let manager: CustomWordsManager

  init() {
    self.manager = CustomWordsManager()
    customWords = manager.load() ?? []
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
  }

  /// Test seam (#636): inject a temp-file-backed manager so hermetic tests of
  /// the contacts-import flow never touch the production custom-words file.
  // periphery:ignore - test seam
  package init(manager: CustomWordsManager) {
    self.manager = manager
    customWords = manager.load() ?? []
    wordsLoadFailureAtLaunch = manager.lastLoadFailure
  }

  @discardableResult
  func add(_ word: CustomWord) -> String? {
    do {
      try manager.add(word: word, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
  }

  /// Outcome of a reviewed Custom Words import (#1665). `.stale` is not a
  /// failure the user caused — the list changed while Review was open, so the
  /// sheet re-compares against the current list instead of writing.
  enum CustomWordsImportCommitOutcome: Sendable, Equatable {
    case committed(CustomWordsImportCommitReceipt)
    case stale
    case failed(message: String)
  }

  /// Re-read the saved words from disk and adopt them, reporting whether the
  /// list can now be trusted.
  ///
  /// One owner for "reload and adopt", used by both callers that need it: the
  /// stale-commit path (#1679) and the export guard (#1680). Reading without
  /// adopting is the trap — a readability check that discards what it read
  /// leaves the caller believing the list is good while it still holds the
  /// empty launch fallback, which is how export came to overwrite a real
  /// backup with an empty file (cloud review, #1682).
  ///
  /// Fails closed: an unreadable file returns `false` and leaves the current
  /// list untouched rather than substituting an empty one.
  @discardableResult
  func refreshFromDiskIfPossible() -> Bool {
    guard let refreshed = manager.load() else { return false }
    if refreshed != customWords {
      customWords = refreshed
      onWordsChanged?(customWords)
    }
    return true
  }

  /// Apply a reviewed import in one atomic write. Fires `onWordsChanged`
  /// exactly once, and only when something actually changed.
  func commitImport(_ plan: CustomWordsImportCommitPlan) -> CustomWordsImportCommitOutcome {
    do {
      let receipt = try manager.commitImport(plan, to: &customWords)
      if !plan.isEmpty {
        onWordsChanged?(customWords)
      }
      customWordError = nil
      return .committed(receipt)
    } catch CustomWordsImportCommitError.staleLibrary {
      // Stale means the on-disk list no longer matches what Review was built
      // from, and the commit threw WITHOUT touching `customWords` — so the
      // in-memory list is exactly the stale copy that caused this. Refresh it
      // from disk before returning, or the sheet rebuilds its comparison from
      // the same stale data, produces identical rows, and fails stale again on
      // the next confirm: a loop the user cannot escape (cloud review, #1679).
      //
      // Fail closed on an unreadable file: keep the current list rather than
      // clobbering it with an empty one. The commit still reports `.stale`,
      // which is honest either way — nothing was written.
      refreshFromDiskIfPossible()
      customWordError = nil
      return .stale
    } catch {
      customWordError = error.localizedDescription
      return .failed(message: error.localizedDescription)
    }
  }

  /// Bulk-add for the contacts import (#636). Returns the IDs actually created
  /// (for the import log), or nil on failure (check `customWordError`).
  func addBatch(_ words: [CustomWord]) -> [UUID]? {
    do {
      let created = try manager.addBatch(words, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return created
    } catch {
      customWordError = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func remove(id: UUID) -> String? {
    do {
      try manager.remove(id: id, from: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
  }

  /// Bulk-remove by ID (contacts-import pill, #636).
  @discardableResult
  func removeBatch(ids: [UUID]) -> String? {
    do {
      try manager.removeBatch(ids: ids, from: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
  }

  @discardableResult
  func update(_ word: CustomWord) -> String? {
    do {
      try manager.update(word: word, in: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
  }

  /// Bulk-update existing words (contacts-import alias enrichment, #636
  /// follow-up). One `onWordsChanged` for the whole batch so the corrector
  /// rebuilds once per flush, not once per word.
  @discardableResult
  func updateBatch(_ words: [CustomWord]) -> String? {
    do {
      try manager.updateBatch(words, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
  }
}
