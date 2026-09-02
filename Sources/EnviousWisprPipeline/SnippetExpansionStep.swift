import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import OSLog

/// Substitutes each fired snippet for a sentinel, FIRST in the post-ASR chain (#628).
///
/// **First on purpose, ahead of `WordCorrectionStep`.** A snippet trigger is matched literally,
/// so it has to be read off the raw ASR surface before the fuzzy corrector can alter one of its
/// words. Running after correction would make whether a snippet fires depend on the user's
/// unrelated custom-word list.
///
/// This step only MASKS. `SnippetFinalizer` — which is not a step, for reasons its own header
/// gives — resolves every sentinel after the runner. The pair exists so the user's saved text
/// never reaches a polish model at all, which makes "delivered exactly as written" true by
/// construction rather than by an instruction in a prompt that nothing enforces.
///
/// Limb semantics: pure CPU string work, no model, no network. Disabled outright when the
/// frozen vocabulary cannot fire, so a user with no snippets takes a byte-identical chain.
@MainActor
public final class SnippetExpansionStep: TextProcessingStep {
  public let name = "Snippet Expansion"

  /// The frozen per-take vocabulary. Assigned by the wiring before the chain runs and never
  /// read live, so an edit in Settings cannot change the rule for a dictation already in
  /// flight — the same freeze `KernelFinalizationWiring` applies to `protectedSpellings`.
  public var snippetVocabulary: SnippetVocabulary = .empty

  /// Disabled rather than run as a no-op. `TextProcessingRunner` skips a disabled step
  /// entirely, so an empty store costs one boolean and the chain is identical to a build
  /// without this file — which is premise P4, and it has a test rather than a hope.
  public var isEnabled: Bool { snippetVocabulary.canFire }

  /// Pure string work over one utterance. A generous runaway BACKSTOP, not a real budget —
  /// mirrors `EmojiFormatterStep` and `EmojiRestoreStep`.
  public var maxDuration: Duration { .milliseconds(50) }

  private static let logger = Logger(
    subsystem: "com.enviouswispr.app", category: "SnippetExpansion")

  private let expander: SnippetExpander

  public init(expander: SnippetExpander = SnippetExpander()) {
    self.expander = expander
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let outcome = expander.expand(context.text, using: snippetVocabulary)
    guard outcome.didFire else { return context }

    var updated = context
    updated.text = outcome.text
    // Appended rather than assigned: recovery and re-polish reuse a context, and silently
    // dropping an earlier run's records would strand a sentinel with nothing to resolve it.
    updated.protectedExpansions += outcome.records

    // Counts only, never a trigger and never an expansion — `CLAUDE.md` privacy boundary, and
    // the same shape-not-content rule the emoji and ITN stamps follow.
    Self.logger.info(
      "Snippet expansion fired for \(outcome.records.count, privacy: .public) snippet(s)")
    return updated
  }
}
