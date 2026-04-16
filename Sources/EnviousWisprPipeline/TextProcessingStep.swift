import Foundation

/// Context passed through the text processing chain after ASR transcription.
public struct TextProcessingContext: Sendable {
  /// The current text being processed. Steps modify this.
  public var text: String
  /// Optional polished/enhanced version of the text.
  public var polishedText: String?
  /// Detected language from ASR.
  public let language: String?
  /// LLM provider used for polishing (e.g. "openai", "ollama").
  public var llmProvider: String?
  /// LLM model used for polishing (e.g. "gpt-4o-mini").
  public var llmModel: String?
  /// Target app display name (e.g. "Terminal"). Nil if unknown or re-polish path.
  public var targetAppName: String?

  public init(text: String, language: String?) {
    self.text = text
    self.language = language
  }
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
  /// Maximum time this step may run before being skipped.
  var maxDuration: Duration { get }
  /// Process the text and return an updated context.
  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext
}
