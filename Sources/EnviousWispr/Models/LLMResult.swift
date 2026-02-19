import Foundation

/// LLM provider for post-processing.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case gemini
    case none
}

/// Result from LLM transcript polishing.
struct LLMResult: Sendable {
    let polishedText: String
    let provider: LLMProvider
    let model: String
}

/// Configuration for an LLM provider.
struct LLMProviderConfig: Codable, Sendable {
    let provider: LLMProvider
    let model: String
    let apiKeyKeychainId: String
    let maxTokens: Int
    let temperature: Double
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
    let removeFillerWords: Bool
    let fixGrammar: Bool
    let fixPunctuation: Bool

    static let `default` = PolishInstructions(
        systemPrompt: """
            You are an expert transcript editor specializing in cleaning up speech-to-text output. \
            Apply ALL of the following corrections:

            1. PUNCTUATION & GRAMMAR: Add proper sentence boundaries (periods, commas, question marks). \
            Fix subject-verb agreement, tense consistency, and capitalization.

            2. MISHEARD WORDS: Correct words that were likely misheard by the speech recognizer based on \
            surrounding context (e.g., "their" vs "there", "would of" -> "would have", homophones, \
            and phonetically similar substitutions).

            3. FILLER WORDS: Remove verbal fillers — um, uh, er, ah, like (when used as filler), \
            you know, I mean, sort of, kind of (when used as hedging), basically, actually (when unnecessary), \
            and repeated false starts or stutters.

            4. SENTENCE BOUNDARIES: Break run-on sentences into clear, properly punctuated sentences. \
            Add paragraph breaks only at major topic shifts.

            5. PRESERVE INTENT: Keep the speaker's original meaning, tone, vocabulary level, and style. \
            Do NOT rephrase, summarize, expand, or add any content that was not spoken.

            Return ONLY the cleaned transcript text. No preamble, no explanations, no commentary.
            """,
        removeFillerWords: true,
        fixGrammar: true,
        fixPunctuation: true
    )
}
