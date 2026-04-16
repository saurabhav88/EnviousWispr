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

  func add(_ word: String) {
    do {
      try manager.add(canonical: word, to: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
    } catch {
      customWordError = error.localizedDescription
    }
  }

  func remove(id: UUID) {
    do {
      try manager.remove(id: id, from: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
    } catch {
      customWordError = error.localizedDescription
    }
  }

  func update(_ word: CustomWord) {
    do {
      try manager.update(word: word, in: &customWords)
      onWordsChanged?(customWords)
      customWordError = nil
    } catch {
      customWordError = error.localizedDescription
    }
  }
}
