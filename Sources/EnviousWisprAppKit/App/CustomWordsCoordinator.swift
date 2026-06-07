import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// Manages custom word state, CRUD operations, and persistence.
@MainActor @Observable
final class CustomWordsCoordinator {
  var customWords: [CustomWord] = []
  var customWordError: String?
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
  }

  /// Test seam (#636): inject a temp-file-backed manager so hermetic tests of
  /// the contacts-import flow never touch the production custom-words file.
  package init(manager: CustomWordsManager) {
    self.manager = manager
    customWords = manager.load() ?? []
  }

  @discardableResult
  func add(_ word: String) -> String? {
    do {
      try manager.add(canonical: word, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
      return nil
    } catch {
      customWordError = error.localizedDescription
      return customWordError
    }
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
