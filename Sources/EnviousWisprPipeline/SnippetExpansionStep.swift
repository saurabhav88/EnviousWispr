import AppKit
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import OSLog

/// Reads the plain text of the user's clipboard, for a snippet that pastes it (#3018).
///
/// `@MainActor` because the only real implementation asks `ClipboardCleanup`, which owns clipboard
/// state on the main actor.
public typealias ClipboardTextReader = @MainActor () -> String?

/// Substitutes each fired snippet for a sentinel, FIRST in the post-ASR chain (#628).
///
/// **First on purpose, ahead of `WordCorrectionStep`.** A snippet trigger is matched literally,
/// so it has to be read off the raw ASR surface before the fuzzy corrector can alter one of its
/// words. Running after correction would make whether a snippet fires depend on the user's
/// unrelated custom-word list.
///
/// This step only MASKS. `SnippetFinalizer` — which is not a step, for reasons its own header
/// gives — resolves every sentinel after the runner. The pair exists so the user's saved text
/// never reaches a polish model. Saved text with fill-ins already resolved is restored after
/// processing, so AI Polish cannot rewrite it.
///
/// Limb semantics: string work, no model, no network. One read of the user's clipboard, and only
/// on a take where a snippet using the copied text actually fired (#3018). Disabled outright when
/// the frozen vocabulary cannot fire, so a user with no snippets takes a byte-identical chain.
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
  /// The runner's budget covers actor scheduling as well as processing. Fill-in processing cost
  /// depends on clipboard size and the saved snippets; the earlier literal-only suite timing does
  /// not bound this workload (#3018, measured). The FIRST step in the chain is the one that pays
  /// the hop: every later step is already on the main actor and hops for free.
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
  private let now: @Sendable () -> Date
  private let clipboardText: ClipboardTextReader

  /// The public entry point, unchanged in shape so every existing call site compiles as it was.
  ///
  /// The real seams live on the `package` initializer below rather than as default arguments
  /// here, because a `public` initializer's default argument is evaluated at the CALL SITE and so
  /// cannot name `ClipboardCleanup.userPlainText`, which is `internal`. An initializer BODY has no
  /// such restriction, so the pair reaches the internal reader without widening it
  /// (`swift-patterns.md` RULE: package-visibility-avoids-cross-module-unknown-default).
  public convenience init(expander: SnippetExpander = SnippetExpander()) {
    self.init(
      expander: expander,
      now: { Date() },
      clipboardText: { ClipboardCleanup.userPlainText(from: .general) })
  }

  /// Fully injected. `package` so the test module reaches it on a plain import, and so no seam
  /// becomes public surface.
  package init(
    expander: SnippetExpander,
    now: @escaping @Sendable () -> Date,
    clipboardText: @escaping ClipboardTextReader
  ) {
    self.expander = expander
    self.now = now
    self.clipboardText = clipboardText
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    // Frozen ONCE for the whole take, before the probe pass. `base(clipboard:)` varies the
    // clipboard and nothing else, so the two passes below cannot disagree about what time it is.
    let instant = now()
    let locale = Locale.current
    let timeZone = TimeZone.current
    func base(clipboard: String?) -> SnippetDynamicValues {
      SnippetDynamicValues(
        now: instant, locale: locale, timeZone: timeZone, clipboard: clipboard)
    }

    // **The clipboard is read only on a take where a clipboard snippet actually FIRED.**
    //
    // This step runs on every dictation, so deciding from the SAVED vocabulary would mean reading
    // the user's pasteboard on every take as soon as one clipboard snippet existed. Matching first
    // and reading second closes that outright rather than documenting it
    // (`code-design-rules.md` RULE: close-the-window-never-handle-it).
    //
    // The probe is not free and is not side-effect-free: minting a sentinel consumes the
    // candidate source. What is true, and is what this needs, is narrower — nothing the user or
    // the pipeline can observe changes, because only the SELECTED outcome updates the context,
    // appends records and emits the log.
    let dry = expander.expand(context.text, using: snippetVocabulary, values: base(clipboard: nil))
    guard dry.didFire else {
      // The NEGATIVE that Live UAT has to be able to see. Without it a take where a clipboard
      // snippet is saved but not spoken emits nothing at all, and "no read happened" would be
      // inferred from silence. A step the runner SKIPS is a different condition with its own
      // cause, and this line does not cover it.
      #if DEBUG
        Self.logger.info("Snippet expansion did not fire; clipboard_read=false")
      #endif
      return context
    }

    let needsClipboard = dry.usedPlaceholders.contains(.clipboard)
    let outcome =
      needsClipboard
      ? expander.expand(
        context.text, using: snippetVocabulary, values: base(clipboard: clipboardText()))
      : dry

    var updated = context
    updated.text = outcome.text
    // Appended rather than assigned: recovery and re-polish reuse a context, and silently
    // dropping an earlier run's records would strand a sentinel with nothing to resolve it.
    updated.protectedExpansions += outcome.records

    // Counts only, never a trigger and never an expansion — `CLAUDE.md` privacy boundary, and
    // the same shape-not-content rule the emoji and ITN stamps follow.
    //
    // `clipboard_read` is DEBUG-only and exists for Live UAT, which is the only instrument that
    // can prove the SHIPPED default reader stayed away from the pasteboard. It is never the oracle
    // for a test: the pre-merge suite runs Release, so a test reading this field would not execute
    // there. Tests assert through the injected `clipboardText` seam instead.
    #if DEBUG
      Self.logger.info(
        """
        Snippet expansion fired for \(outcome.records.count, privacy: .public) snippet(s)         clipboard_read=\(needsClipboard, privacy: .public)
        """)
    #else
      Self.logger.info(
        "Snippet expansion fired for \(outcome.records.count, privacy: .public) snippet(s)")
    #endif
    return updated
  }
}
