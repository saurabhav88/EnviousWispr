import Foundation

/// Context passed through the text processing chain after ASR transcription.
@MainActor
struct TextProcessingContext {
    /// The current text being processed. Steps modify this.
    var text: String
    /// Optional polished/enhanced version of the text.
    var polishedText: String?
    /// The original unmodified ASR output (read-only reference).
    let originalASRText: String
    /// Detected language from ASR.
    let language: String?
    /// LLM provider used for polishing (e.g. "openai", "ollama").
    var llmProvider: String?
    /// LLM model used for polishing (e.g. "gpt-4o-mini").
    var llmModel: String?
}

/// A single step in the post-ASR text processing chain.
///
/// Steps run in order after transcription. Each step receives the context
/// from the previous step and returns a modified context.
@MainActor
protocol TextProcessingStep {
    /// Human-readable name for logging.
    var name: String { get }
    /// Whether this step should run. Checked before each invocation.
    var isEnabled: Bool { get }
    /// Process the text and return an updated context.
    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext
}
