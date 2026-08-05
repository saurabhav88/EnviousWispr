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
  /// #1846: which dictation this text belongs to, frozen by `TextProcessingRunner`
  /// at the start of the chain. Observation-only: never persisted, never `Codable`,
  /// and it never influences a processing decision.
  ///
  /// Optional because two real paths genuinely have no take: re-polish of an
  /// existing transcript, and crash recovery, which replays audio that outlived the
  /// session that produced it. Those emit no live polish telemetry anyway (both use
  /// the `.silent` seam presets), so nil here is honest rather than a gap.
  public var takeID: String?
  /// LLM provider used for polishing (e.g. "openai", "ollama").
  public var llmProvider: String?
  /// LLM model used for polishing (e.g. "gpt-4o-mini").
  public var llmModel: String?
  /// Target app display name (e.g. "Terminal"). Nil if unknown or re-polish path.
  public var targetAppName: String?
  /// Connector-source-of-truth metadata for AFM polish (#429; single-prompt since #1072).
  /// Cloud providers leave this nil.
  public var polishMetadata: PolishMetadata?
  /// Final pipeline-level fallback flag — true if EITHER the connector-side
  /// `EnviousOutputFilter` OR the post-step `validatePolishOutput` fell back
  /// to raw input. Computed in `LLMPolishStep` after validation; the connector
  /// cannot know this. Telemetry surfaces this as `fell_back_to_raw`.
  public var pipelineFellBackToRaw: Bool
  /// Honest reason the pipeline fell back to raw, disaggregating the single
  /// `pipelineFellBackToRaw` boolean (#1050). Nil when polish changed the text
  /// (not a fallback). One of `no_change` (model returned the input unchanged —
  /// benign), `guard_discard` (connector `EnviousOutputFilter` tripped — genuine
  /// misbehavior caught; `polishMetadata.filterTripped` names which),
  /// `validator_discard` (model differed but `validatePolishOutput` substituted
  /// the original — genuine catch the `filter_tripped` signal cannot see), or
  /// `empty_output_floor` (#1358 — the limb chain produced empty text and
  /// `KernelFinalizationWiring` delivered a deterministic raw floor; stamped by
  /// the wiring, not by `LLMPolishStep.polishFallbackReason`).
  /// Invariant: `(polishFallbackReason != nil) == pipelineFellBackToRaw`.
  public var polishFallbackReason: String?
  /// #1914: whether the Ollama daemon reported the polishing model as running on
  /// Ollama's servers. Stamped after generation and validation return.
  ///
  /// `true` means remote. `false` means the daemon did not report the model as
  /// remote. `nil` means no completed Ollama generation fact reached this
  /// context, including non-Ollama and pre-generation failure or bypass paths.
  /// Finalization may later clear a non-nil value when empty-output recovery
  /// reclassifies the generation as skipped. `false` is not independent proof
  /// of local execution.
  public var polishRanRemote: Bool?

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
  ///
  /// The FIXED policy for steps whose cost does not depend on the input. Five
  /// of the six steps declare only this; the runner always calls
  /// `maxDuration(for:)` below, whose default returns this value.
  var maxDuration: Duration { get }
  /// Maximum time this step may run, given the text it is about to process
  /// (#1770).
  ///
  /// Exists because LLM polish is the one step whose cost tracks input length:
  /// measured live, a 10-minute dictation polishes in 6.1s and the longest
  /// transcript we have recorded in 50.7s, against a former flat 5s budget that
  /// timed out both (visibly, for cloud providers — the user gets the "AI
  /// polish failed" notice). A single larger flat number is not the answer either
  /// — it would make a 20-word dictation wait far longer than today before its
  /// raw text appears.
  ///
  /// This is the SAME duration authority made context-aware, not a second one:
  /// the default below delegates to `maxDuration`, so a step opts in only by
  /// overriding.
  func maxDuration(for context: TextProcessingContext) -> Duration
  /// Process the text and return an updated context.
  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext
  /// How `TextProcessingRunner` should treat an error thrown by `process`.
  /// Defaults to `.swallow` — only LLM polish overrides to `.surface`.
  var errorSurfacePolicy: ErrorSurfacePolicy { get }
}

extension TextProcessingStep {
  var errorSurfacePolicy: ErrorSurfacePolicy { .swallow }
  /// Default: the step's cost does not depend on its input, so the fixed
  /// policy applies. Only `LLMPolishStep` overrides this.
  func maxDuration(for context: TextProcessingContext) -> Duration { maxDuration }
}
