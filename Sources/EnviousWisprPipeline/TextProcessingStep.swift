import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Context passed through the text processing chain after ASR transcription.
public struct TextProcessingContext: Sendable {
  /// The current text being processed. Steps modify this.
  public var text: String
  /// Optional polished/enhanced version of the text.
  public var polishedText: String?
  /// The RESOLVED dictation language (#2614): the user's lock, an engine that
  /// really detects, or the text itself at `DictationLanguageResolver`'s
  /// confidence floor — or nil when nothing established it. Seeded once by
  /// `TextProcessingRunner` from the caller's `LanguageEvidence`; every step
  /// reads this one answer (the ITN gate, filler protection, polish). Before
  /// #2614 this carried only the locked code, so Automatic on the default
  /// engine ran English-only rules over every language (issue #2259).
  public let language: String?
  /// Which rung of the resolver answered `language` (#2614). `nil` means the
  /// resolution was never attempted — a context built directly by a test or a
  /// future caller — and consumers keep their legacy nil-language behaviour.
  /// Every production runner call records a non-nil source, `.none` included.
  /// `package` because `Resolution.Source` is `package`.
  package var languageSource: DictationLanguageResolver.Resolution.Source?
  /// The text rung's confidence bucket for telemetry (#2614). Nil when never
  /// attempted; `.none` when the answer came from a lock or an engine.
  package var languageConfidenceBucket: DictationLanguageResolver.Resolution.Bucket?
  /// #2614: the resolver abstained but its top hypothesis was confidently NOT
  /// English, so English-only cleanup rules must stand down. See
  /// `DictationLanguageResolver.Resolution.englishVeto`. Read by the ITN gate
  /// and the filler protection set; nothing else.
  public var englishRulesVetoed: Bool = false
  /// #996: `DictationLanguageResolver.Resolution.learnLanguage`, the language
  /// the learn-from-edits gate may use for this take. Forwarded, never
  /// re-derived from `language` or `englishRulesVetoed`: the resolver owns
  /// that ladder. Nil when never resolved, and nil under the non-English veto.
  package var learnLanguage: String?
  /// #3111: `DictationLanguageResolver.Resolution.textLanguage` for this take —
  /// what the raw ASR text alone says at the resolver's floor, read on every
  /// rung because the runner asks for it. Nil means the text was unsure, or the
  /// context never went through the runner. Read only by EG-1's language naming.
  package var textLanguage: String?
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
  /// #3038: which `validatePolishOutput` guard discarded the model's output (`expansion`,
  /// `content_drop`, `question_flip`, `symbol_drop`); nil when the output stood or when the
  /// fallback came from somewhere else (a sentinel loss in `SnippetFinalizer`, the empty-output
  /// floor in finalization), which must not claim a validator guard.
  public var polishValidatorGuard: String?
  /// #3038: the number of `/word` and `\word` tokens the deterministic text carried when
  /// Guard 4 ran (zero is a measurement); nil when polish did not reach Guard 4.
  public var symbolTokens: Int?
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

  /// True when `LLMPolishStep` DECLINED to send this text — a bypass, not a
  /// failure (#2648).
  ///
  /// **Written by the step that decides, because nothing downstream can tell the
  /// two apart.** A bypass and a silent failure both arrive as "no polished text
  /// and no error", so a reader guessing from that shape marked a passage the
  /// pipeline deliberately skipped — one at most three words long, say — as one
  /// the app had failed to clean. The rule that decides eligibility lives in the
  /// step; re-deriving it anywhere else would be a copy that agrees today.
  ///
  /// Defaults to false, so every existing reader is unchanged.
  public var polishWasBypassed = false

  /// The `PromptFamily` the planner selected for this polish (#1948). Stamped by
  /// `LLMPolishStep` from `PolishPlan.family` on the success path only, so it is nil for a
  /// skip, a failure, a bypass, and for Apple Intelligence (whose branch returns earlier).
  ///
  /// Carried rather than re-derived. `EmojiRestoreStep` needs to know whether THIS polish
  /// used the local fixed prompt, and deriving that from `(provider, model, polishRanRemote)`
  /// downstream would rebuild the planner's decision in a second place — the exact
  /// duplication #1948 removed from the telemetry stamp.
  ///
  /// Typed, not a rawValue string, and `internal` rather than `public`: nothing outside this
  /// module reads it, and a stringly-typed receipt is what let the first version of the
  /// emoji gate accept a family from the wrong provider.
  var promptFamily: PromptFamily?

  /// Snippet expansions owed to the user (#628): each sentinel standing in the text, and the
  /// saved text that must replace it before anything is stored, shown or pasted.
  ///
  /// Written ONLY by `SnippetExpansionStep` and read ONLY by `SnippetFinalizer` — one writer,
  /// one reader, so "which spans must survive the chain byte-for-byte" has a single authority.
  ///
  /// Deliberately NOT folded into `KernelFinalizationWiring`'s `protectedSpellings`, which
  /// looks adjacent and is not: that set is custom-word canonicals, its only consumer is
  /// `CursorInsertionRepair`, and it vetoes LEADING RECASING alone. It carries words; this
  /// carries positioned spans, and it must survive a different stage.
  ///
  /// Non-`Codable` and never persisted: a sentinel is meaningless outside the run that minted
  /// it, and a stored one would be a live token pointing at nothing.
  public var protectedExpansions: [SnippetExpansionRecord] = []

  /// #3124: the spelling in force for this take, seeded by `TextProcessingRunner` from the
  /// caller's `LanguageEvidence`. `.american` for a context built directly (tests, future callers):
  /// the spelling steps then do nothing.
  public var englishSpelling: EnglishSpelling = .american

  /// #3124: lowercased Custom Words the spelling steps must never respell: each single-word
  /// canonical and every word of a multi-word one. Seeded ONCE by `TextProcessingRunner` before any
  /// step runs, so both spelling passes read one set even if the vocabulary changes mid-take, and
  /// a pass that times out cannot take the set with it.
  public var spellingProtectedWords: Set<String> = []

  /// #3124: swaps made by the spelling passes the runner ACCEPTED, summed. `nil` means no pass ran
  /// on this take (not British, not English, table missing, or timed out); `0` means a pass ran
  /// and found nothing to change. Carried in the context so a discarded pass takes its count with
  /// it. Neither value proves the delivered text is British.
  public var englishSpellingSwaps: Int?

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
  /// The FIXED policy for steps whose cost does not depend on the input. Most
  /// steps declare only this; the runner always calls `maxDuration(for:)`
  /// below, whose default returns this value.
  var maxDuration: Duration { get }
  /// Maximum time this step may run, given the text it is about to process
  /// (#1770).
  ///
  /// Exists because LLM polish was the first step whose cost tracks input length
  /// (inverse text normalization joined it in #2770):
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
  /// policy applies. `LLMPolishStep` (#1770) and `InverseTextNormalizationStep`
  /// (#2770) override this.
  func maxDuration(for context: TextProcessingContext) -> Duration { maxDuration }
}
