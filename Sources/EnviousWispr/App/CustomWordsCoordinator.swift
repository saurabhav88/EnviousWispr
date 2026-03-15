import Foundation
import Observation
import EnviousWisprCore
import EnviousWisprPostProcessing

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

    /// Convenience: remove by canonical string.
    func remove(canonical: String) {
        guard let match = customWords.first(where: { $0.canonical == canonical }) else { return }
        let matchID = match.id
        remove(id: matchID)
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
