import Foundation

/// LLM provider for post-processing.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case gemini
    case ollama
    case appleIntelligence
    case none
}

extension LLMProvider {
    var displayName: String {
        switch self {
        case .openAI:            return "OpenAI"
        case .gemini:            return "Gemini"
        case .ollama:            return "Ollama"
        case .appleIntelligence: return "Apple Intelligence"
        case .none:              return "None"
        }
    }
}

/// Result from LLM transcript polishing.
struct LLMResult: Sendable {
    let polishedText: String
}

/// Configuration for an LLM provider.
struct LLMProviderConfig: Codable, Sendable {
    let model: String
    let apiKeyKeychainId: String?
    let maxTokens: Int
    let temperature: Double
    let thinkingBudget: Int?
    let reasoningEffort: String?
}

/// A discoverable LLM model with availability status.
struct LLMModelInfo: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    var isAvailable: Bool
}

/// Instructions for how the LLM should polish the transcript.
struct PolishInstructions: Codable, Sendable {
    let systemPrompt: String

    static let `default` = PolishInstructions(
        systemPrompt: """
            Clean up this speech-to-text transcript. Make minimal changes:
            - Fix punctuation, capitalization, and grammar
            - Correct misheard words based on context
            - Remove filler words (um, uh, like, you know) and false starts
            - Break run-on sentences; paragraph breaks only at topic shifts
            Do NOT rephrase, expand, or add content. Output ONLY the corrected transcript.
            """
    )
}

extension PolishInstructions {
    /// Build a PolishInstructions using a user-supplied system prompt.
    static func custom(systemPrompt: String) -> PolishInstructions {
        PolishInstructions(systemPrompt: systemPrompt)
    }
}

/// Built-in prompt presets the user can apply with one click.
enum PromptPreset: String, CaseIterable, Identifiable, Sendable {
    case cleanUp = "Clean Up"
    case formal  = "Formal"
    case casual  = "Casual"

    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .cleanUp:
            return PolishInstructions.default.systemPrompt
        case .formal:
            return """
                You are a professional editor. Rewrite the following speech-to-text transcript \
                in a formal, polished tone suitable for business correspondence. \
                Fix all grammar, punctuation, and spelling errors. \
                Remove filler words and false starts. \
                Preserve the speaker's original meaning exactly — do not add, remove, or \
                summarize content. \
                Return only the rewritten text with no commentary.
                """
        case .casual:
            return """
                You are a friendly editor. Clean up the following speech-to-text transcript \
                while keeping a natural, conversational tone. \
                Fix obvious errors but keep contractions, informal phrasing, and the speaker's \
                personality. Remove only the most distracting filler words (um, uh, like). \
                Return only the cleaned text with no commentary.
                """
        }
    }
}
