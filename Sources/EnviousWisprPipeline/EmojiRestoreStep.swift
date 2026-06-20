import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// Restores emoji the Apple on-device (AFM) polish step stripped (#761), as the
/// FINAL limb in the post-ASR chain — after `LLMPolishStep`. The deterministic
/// `EmojiFormatterStep` inserts glyphs BEFORE polish; AFM then drops ~70-90% of
/// them. This step compares the pre-polish text (`context.text`, emoji-bearing)
/// against the polish output (`context.polishedText`, stripped) and re-inserts
/// the dropped glyphs at their anchor word via the pure `EmojiRestorer`.
///
/// Placement: runs AFTER `llmPolish` so both strings are co-located on the same
/// `TextProcessingContext` (`LLMPolishStep` sets only `polishedText`, never
/// `text`). It mutates `polishedText`, which `KernelFinalizationWiring` delivers
/// and stores as `ctx.polishedText ?? ctx.text`.
///
/// Limb semantics (heart & limbs): never blocks the heart path. Pure CPU
/// (~0.01ms), no model, no network, the restorer never throws, and every guard
/// below is a return-context-unchanged no-op. AFM-ONLY: cloud / Ollama / none
/// keep their own emoji behavior untouched.
///
/// ALWAYS-ON, data-driven — NOT gated on the emoji-converter toggle. The restore
/// is coupled to "did THIS dictation carry emoji that polish dropped" (a count
/// diff), never to the live setting. Gating on the live `emojiFormatterEnabled`
/// flag was wrong: if the user flips emoji OFF during the ~1s AFM polish — after
/// the converter already inserted a glyph — a toggle-gated step would be skipped
/// and the glyph would be lost, the exact #761 bug it exists to fix. When the
/// converter is off there is simply no emoji in `context.text`, so this step
/// no-ops (zero dropped). Mirrors `InverseTextNormalizationStep`'s always-on shape.
@MainActor
final class EmojiRestoreStep: TextProcessingStep {
  let name = "Emoji Restore"

  /// Always-on (#761): the restore must run whenever a dictation MIGHT have lost
  /// emoji, independent of the live converter toggle. A no-op when nothing was
  /// dropped, so always running it costs ~0.02ms on emoji-free dictations.
  var isEnabled: Bool { true }

  /// Pure ~0.01ms string work, so this is a generous runaway BACKSTOP — NOT a
  /// real wall-clock deadline (no `withDeadline` machinery, unlike ITN). Mirrors
  /// `EmojiFormatterStep`'s 50ms.
  var maxDuration: Duration { .milliseconds(50) }

  /// Per-run outcome the wiring reads after the chain to thread `emoji_*` fields
  /// onto `dictation.completed`. Metadata only (counts/latency) — never glyphs
  /// or transcript text (`telemetry-privacy-boundary`). Set ONLY on an AFM run
  /// with polish output; `nil` clears a prior dictation's stamp on every other
  /// path so a non-AFM dictation emits no emoji telemetry.
  struct RunOutcome: Sendable {
    /// True when the AFM-gated restore actually executed.
    let ran: Bool
    /// Emoji clusters in the pre-polish text (volume signal).
    let emojiInInput: Int
    /// Clusters AFM stripped (the restore targets).
    let dropped: Int
    /// Clusters re-inserted. Equals `dropped` by construction.
    let restored: Int
    /// `restored < dropped` — an anomaly that should never fire.
    let incomplete: Bool
    /// Wall-clock of the restore call in milliseconds.
    let latencyMs: Double
  }

  /// The most recent AFM `process(...)` outcome. Read by `KernelFinalizationWiring`
  /// immediately after the chain runs (same actor, no race).
  private(set) var lastRun: RunOutcome?

  private let restorer: EmojiRestorer

  init(restorer: EmojiRestorer = EmojiRestorer()) {
    self.restorer = restorer
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    // Clear a prior dictation's stamp; only an AFM run below re-stamps it.
    lastRun = nil

    // AFM-only gate (`appleIntelligence` rawValue, set by `LLMPolishStep`).
    guard context.llmProvider == LLMProvider.appleIntelligence.rawValue else { return context }
    // Polish produced no distinct output (disabled / too-short bypass #1022 /
    // provider `.none`): delivery uses the emoji-bearing `ctx.text`, nothing to do.
    guard let polished = context.polishedText else { return context }

    let start = CFAbsoluteTimeGetCurrent()
    let result = restorer.restore(polished: polished, prePolish: context.text)
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

    let incomplete = result.restored < result.dropped
    lastRun = RunOutcome(
      ran: true,
      emojiInInput: result.emojiInInput,
      dropped: result.dropped,
      restored: result.restored,
      incomplete: incomplete,
      latencyMs: elapsedMs)

    if incomplete {
      // Should be impossible — every dropped glyph is re-inserted by
      // construction. Counts-only breadcrumb so a regression is visible without
      // ever carrying a glyph or transcript text (`telemetry-privacy-boundary`).
      // The user still got the polished text plus whatever was restored.
      SentryBreadcrumb.captureError(
        EmojiRestoreAnomaly.underRestore,
        category: .emojiRestoreIncomplete,
        stage: "emoji_restore",
        extra: [
          "emoji_in_input": result.emojiInInput,
          "dropped": result.dropped,
          "restored": result.restored,
        ])
    }

    // Nothing dropped → leave the polished text byte-for-byte (never disturb the
    // emoji or whitespace the model kept).
    guard result.dropped > 0 else { return context }

    var ctx = context
    ctx.polishedText = result.text
    return ctx
  }
}

/// Marker for the under-restore Sentry anomaly. The `EmojiRestorer` is pure and
/// never throws, so this is the step's only error signal — surfaced as a
/// counts-only breadcrumb, never thrown out of `process`.
private enum EmojiRestoreAnomaly: Error {
  case underRestore
}
