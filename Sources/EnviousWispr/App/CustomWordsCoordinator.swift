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

  /// Called after any mutation so AppState can sync words to pipelines.
  var onWordsChanged: (([CustomWord]) -> Void)?

  private let manager = CustomWordsManager()

  init() {
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
}
