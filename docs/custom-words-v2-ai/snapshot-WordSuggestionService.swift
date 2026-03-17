import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests categories and phonetic aliases for custom words using Apple Intelligence.
@MainActor
final class WordSuggestionService {

    /// Whether Apple Intelligence word suggestions are available on this system.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Hard timeout for suggestion calls (seconds).
    private static let suggestTimeoutSeconds = 5

    /// Suggest category and aliases for a custom word.
    /// Returns nil on timeout (5s) or if Apple Intelligence is unavailable.
    func suggest(for word: String) async -> WordSuggestions? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }

        // Hard timeout — FM can hang indefinitely on some inputs.
        // Runs the FM call off MainActor to avoid deadlocking the
        // continuation (suggest() itself is @MainActor-isolated).
        let once = SuggestionOnce()
        let wordCopy = word
        return await withCheckedContinuation { continuation in
            let cont = continuation

            Task.detached {
                let result = await self.suggestWithFoundationModels(for: wordCopy)
                if once.tryAcquire() { cont.resume(returning: result) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(Self.suggestTimeoutSeconds))
                if once.tryAcquire() {
                    Task { await AppLogger.shared.log(
                        "Word suggestion timed out after \(Self.suggestTimeoutSeconds)s for '\(wordCopy)'",
                        level: .info, category: "WordSuggestion"
                    ) }
                    cont.resume(returning: nil)
                }
            }
        }
        #else
        return nil
        #endif
    }

    // MARK: - Guided generation with @Generable

    #if canImport(FoundationModels) && hasAttribute(Generable)
    @Generable
    @available(macOS 26.0, *)
    struct WordSuggestionsResult {
        @Guide(description: "Category: general, person, brand, acronym, or domain")
        var category: String

        @Guide(description: "3 to 5 ways speech recognition might mishear this word. Include phonetic misspellings, word boundary errors, and homophones. Never return an empty list.")
        var suggestedAliases: [String]
    }

    @available(macOS 26.0, *)
    private func suggestWithFoundationModels(for word: String) async -> WordSuggestions? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        let session = LanguageModelSession(
            model: model,
            instructions: """
                You suggest how speech recognition might mishear a word.

                Examples:
                - "Kubernetes" → category: brand, aliases: ["kubernetties", "kuber net ease", "cube ernetes", "cooper net ease"]
                - "Saurabh" → category: person, aliases: ["sorab", "saw rob", "so rob", "saurav"]
                - "PostgreSQL" → category: brand, aliases: ["post gress", "postgres queue el", "post gray sequel"]

                Always provide 3-5 realistic aliases. Focus on how the word sounds when spoken aloud.
                """
        )

        do {
            let response = try await session.respond(
                to: "Word: \(word)\nCategory (general/person/brand/acronym/domain):\nAliases (3-5 common misrecognitions):",
                generating: WordSuggestionsResult.self
            )

            let category = WordCategory(rawValue: response.category.lowercased()) ?? .general
            let aliases = response.suggestedAliases.filter { !$0.isEmpty }

            Task { await AppLogger.shared.log(
                "Word suggestion for '\(word)': category=\(response.category), rawAliases=\(response.suggestedAliases), filtered=\(aliases)",
                level: .info, category: "WordSuggestion"
            ) }

            return WordSuggestions(category: category, suggestedAliases: aliases)
        } catch {
            Task { await AppLogger.shared.log(
                "Word suggestion failed: \(error.localizedDescription)",
                level: .info, category: "WordSuggestion"
            ) }
            return nil
        }
    }

    #elseif canImport(FoundationModels)
    // CLT builds without @Generable — return nil gracefully
    @available(macOS 26.0, *)
    private func suggestWithFoundationModels(for word: String) async -> WordSuggestions? {
        return nil
    }
    #endif
}

/// Result of an Apple Intelligence word suggestion.
struct WordSuggestions: Sendable {
    let category: WordCategory
    let suggestedAliases: [String]
}

/// Single-fire guard for suggestion timeout race.
private final class SuggestionOnce: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func tryAcquire() -> Bool {
        lock.withLock { fired in
            if fired { return false }
            fired = true
            return true
        }
    }
}
