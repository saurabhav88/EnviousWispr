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

  /// The active vocabulary, assigned by the wiring and re-assigned whenever the user saves.
  ///
  /// NOT a per-take freeze, and an earlier version of this comment said it was. The App layer
  /// replaces this on every save, so a snippet edited while a dictation is in flight applies to
  /// that take. Same behaviour custom words already have — `KernelFinalizationWiring` says so at
  /// its `protectedSpellings` snapshot, which exists precisely because the vocabulary behind it
  /// is NOT frozen. Nothing is delivered wrongly; the newest snippet simply wins.
  public var snippetVocabulary: SnippetVocabulary = .empty

  /// Disabled rather than run as a no-op. `TextProcessingRunner` skips a disabled step
  /// entirely, so an empty store costs one boolean and the chain is identical to a build
  /// without this file — which is premise P4, and it has a test rather than a hope.
  ///
  /// The property is unchanged since starter snippets landed; the population it covers is
  /// smaller. A fresh install is no longer an empty store, because `SnippetStarters` are
  /// written on the first launch, so this now reads false only for someone who deleted them
  /// all. Examples that fire are worth the step running, and a decorative example nobody can
  /// try is a screenshot.
  public var isEnabled: Bool { snippetVocabulary.canFire }

  /// One second, and the number is a measurement rather than a preference.
  ///
  /// The work here is microseconds — the same call runs 55 unit tests in 0.15s. But the runner's
  /// budget covers the actor HOP as well as the work, and the FIRST step in the chain is the one
  /// that pays it: every later step is already on the main actor and hops for free.
  ///
  /// Measured on the real app, two consecutive live dictations, with the 50ms backstop this file
  /// originally copied from `EmojiFormatterStep`:
  ///   `Snippet Expansion timed out after 51.7ms — skipping`
  ///   `Snippet Expansion timed out after 51.8ms — skipping`
  /// Consistent, so not a cold start; and every other step in the same take completed, so not a
  /// stalled main actor. The step simply never got to run inside its own budget, and the user's
  /// snippet silently did not fire.
  ///
  /// 50ms was wrong because it was copied from a step that runs LATE. `WordCorrectionStep` — the
  /// step that was first before this one — declares 3 seconds, and had been absorbing this cost
  /// invisibly for everyone.
  ///
  /// Still a runaway backstop, not a latency budget: nothing here should approach it, and if a
  /// future change makes it does, the timeout is the right outcome.
  public var maxDuration: Duration { .seconds(1) }

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
