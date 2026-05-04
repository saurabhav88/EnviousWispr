import EnviousWisprCore
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
  /// Connector-source-of-truth metadata for AFM dual-mode polish (#429).
  /// Cloud providers leave this nil.
  public var polishMetadata: PolishMetadata?
  /// Final pipeline-level fallback flag — true if EITHER the connector-side
  /// `EnviousOutputFilter` OR the post-step `validatePolishOutput` fell back
  /// to raw input. Computed in `LLMPolishStep` after validation; the connector
  /// cannot know this. Telemetry surfaces this as `fell_back_to_raw`.
  public var pipelineFellBackToRaw: Bool

  public init(text: String, language: String?) {
    self.text = text
    self.language = language
    self.pipelineFellBackToRaw = false
  }
}

/// Whether a step's thrown error should reach the user as `polishError`
/// (e.g. the "AI polish failed" banner) or be silently absorbed by the heart.
///
/// Default conformance is `.swallow`: limb failures stay invisible. Only
/// `LLMPolishStep` overrides to `.surface` today. Adding the property as a
/// protocol requirement (with a default extension) replaces the prior
/// string-literal branch on `step.name == "LLM Polish"`, so renaming a step
/// can never silently mute the user-visible failure path.
internal enum ErrorSurfacePolicy {
  case surface
  case swallow
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
  /// How `TextProcessingRunner` should treat an error thrown by `process`.
  /// Defaults to `.swallow` — only LLM polish overrides to `.surface`.
  var errorSurfacePolicy: ErrorSurfacePolicy { get }
}

extension TextProcessingStep {
  var errorSurfacePolicy: ErrorSurfacePolicy { .swallow }
}
