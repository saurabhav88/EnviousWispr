import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// #3737 Casual mode: the LAST step of the dictation chain. Leaves off the full stop at the very end of
/// the take (`CasualEnding` owns which mark that is).
///
/// Last, after polish and emoji restore, so it holds with every engine and every polish provider: no
/// later step re-adds a final full stop. Before `SnippetFinalizer` (which runs after the runner): a take
/// that ends with a snippet ends with that snippet's sentinel here, so the snippet's own saved ending is
/// never touched.
///
/// Applied to `text` AND `polishedText` with the same inputs, so whichever one is delivered or stored
/// (`polishedText ?? text`, the empty-output floor, the snippet sentinel-loss fallback) ends the same way.
///
/// Live-mutable like the other Engine-page switches (filler, emoji, spoken punctuation): settings sync
/// writes `casualModeEnabled` on both kernel drivers; crash recovery replays the record-time value; file
/// import freezes it to off (an imported recording is a document, not a reply).
@MainActor
final class CasualEndingStep: TextProcessingStep {
  let name = "Casual Ending"

  var casualModeEnabled = false

  var isEnabled: Bool { casualModeEnabled }

  /// Pure string work on one character at the end; a runaway backstop, like `EmojiRestoreStep`.
  var maxDuration: Duration { .milliseconds(50) }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    var ctx = context
    ctx.text = CasualEnding.removingFinalFullStop(
      context.text, language: context.language, spokenFinalFullStop: context.spokenFinalFullStop)
    if let polished = context.polishedText {
      ctx.polishedText = CasualEnding.removingFinalFullStop(
        polished, language: context.language, spokenFinalFullStop: context.spokenFinalFullStop)
    }
    return ctx
  }
}
