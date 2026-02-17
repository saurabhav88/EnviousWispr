/// Predefined prompt templates for LLM transcript polishing.
enum PromptTemplate: String, CaseIterable, Sendable {
    case grammarFix
    case summarize
    case reformat

    var displayName: String {
        switch self {
        case .grammarFix: return "Fix Grammar & Punctuation"
        case .summarize: return "Summarize"
        case .reformat: return "Reformat"
        }
    }

    var instructions: PolishInstructions {
        switch self {
        case .grammarFix:
            return .default
        case .summarize:
            return PolishInstructions(
                systemPrompt: """
                    Summarize the following transcript concisely.
                    Preserve key points and important details.
                    Return only the summary, no explanations.
                    """,
                removeFillerWords: true,
                fixGrammar: true,
                fixPunctuation: true
            )
        case .reformat:
            return PolishInstructions(
                systemPrompt: """
                    Reformat the following transcript into clear, readable paragraphs.
                    Fix grammar and punctuation.
                    Add paragraph breaks at natural topic transitions.
                    Return only the reformatted text, no explanations.
                    """,
                removeFillerWords: true,
                fixGrammar: true,
                fixPunctuation: true
            )
        }
    }
}
