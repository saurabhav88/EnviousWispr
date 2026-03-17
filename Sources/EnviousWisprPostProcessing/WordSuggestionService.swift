import Foundation
import EnviousWisprCore

#if canImport(FoundationModels)
import FoundationModels
#endif

public final class WordSuggestionService: Sendable {
    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    public init() {}

    public func suggest(for word: String) async -> WordSuggestions? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *),
              case .available = SystemLanguageModel.default.availability else { return nil }

        // Hard 5s timeout — FM can hang on some inputs
        do {
            return try await withThrowingTimeout(seconds: 5) {
                await self.runSuggestion(for: word)
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static let suggestionInstructions = """
        You predict how speech-to-text engines (Whisper, Parakeet) misrecognize a spoken word.
        Focus on: wrong word boundaries ("par vati"), vowel/consonant swaps ("pavathi"), \
        phonetic spellings ("poor vati"), and homophones ("partee").
        Do NOT suggest honorifics, suffixes, or cultural variants — only ASR errors.
        Examples:
        - "Kubernetes" → category: brand, aliases: ["kuber netties", "cube ernetes", "cooper nettys"]
        - "Miyamoto" → category: person, aliases: ["me ya moto", "mia motto", "me amoto", "miyomoto"]
        - "Parvati" → category: person, aliases: ["par vati", "poor vati", "pavathi", "par vathy"]
        Always provide 3-5 realistic ASR misrecognitions.
        """

    // MARK: - Guided generation with @Generable (full Xcode toolchain)

#if canImport(FoundationModels) && hasAttribute(Generable)
    @Generable
    @available(macOS 26.0, *)
    struct WordSuggestionsResult {
        @Guide(description: "Category: general, person, brand, acronym, or domain")
        var category: String
        @Guide(description: "3 to 5 ways speech recognition might mishear this word")
        var suggestedAliases: [String]
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.suggestionInstructions
        )

        do {
            let response = try await session.respond(
                to: "Word: \(word)",
                generating: WordSuggestionsResult.self
            )
            let category = WordCategory(rawValue: response.category.lowercased()) ?? .general
            let aliases = response.suggestedAliases.filter { !$0.isEmpty }
            return WordSuggestions(category: category, suggestedAliases: aliases)
        } catch {
            return nil
        }
    }

    // MARK: - Dynamic schema fallback (CLT-only builds without macro plugin)

#elseif canImport(FoundationModels)
    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.suggestionInstructions
        )

        do {
            let dynamicSchema = DynamicGenerationSchema(
                name: "WordSuggestion",
                properties: [
                    DynamicGenerationSchema.Property(
                        name: "category",
                        schema: DynamicGenerationSchema(type: String.self)
                    ),
                    DynamicGenerationSchema.Property(
                        name: "suggestedAliases",
                        schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
                    ),
                ]
            )
            let schema = try GenerationSchema(root: dynamicSchema, dependencies: [])

            let response = try await session.respond(
                to: "Word: \(word)",
                schema: schema
            )
            let categoryStr = try response.content.value(String.self, forProperty: "category")
            let aliases = try response.content.value([String].self, forProperty: "suggestedAliases")

            let category = WordCategory(rawValue: categoryStr.lowercased()) ?? .general
            return WordSuggestions(category: category, suggestedAliases: aliases.filter { !$0.isEmpty })
        } catch {
            return nil
        }
    }
#endif
}

public struct WordSuggestions: Sendable {
    public let category: WordCategory
    public let suggestedAliases: [String]
}
