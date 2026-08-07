import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// Restores emoji a small local polish model stripped (#761), as the FINAL limb in the
/// post-ASR chain — after `LLMPolishStep`. The deterministic `EmojiFormatterStep` inserts
/// glyphs BEFORE polish; Apple on-device (AFM) then drops ~70-90% of them, and #1948
/// measured local Ollama dropping them on 45 of 98 emoji-bearing corpus cases
/// (`qwen2.5:3b`) and 92 of 98 (`llama3.2`). This step compares the pre-polish text (`context.text`, emoji-bearing)
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
/// flag was wrong: if the user flips emoji OFF mid-polish (~1s on Apple Intelligence,
/// longer on a local Ollama model) — after
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
  /// path so a dictation on a non-restoring path emits no emoji telemetry (#1948: the
  /// restoring paths are Apple Intelligence and local Ollama, not Apple Intelligence alone).
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

  /// The most recent RESTORING-provider `process(...)` outcome (Apple Intelligence or
  /// Ollama since #1948; nil on every other provider). Read by `KernelFinalizationWiring`
  /// immediately after the chain runs (same actor, no race).
  private(set) var lastRun: RunOutcome?

  /// Alignment-token ceiling above which restoration is skipped rather than run, counted
  /// with `EmojiRestorer.alignmentTokenCount` so the guard and the allocation measure the
  /// same thing. See the measurement table at the guard site; 1,000 is where the real
  /// restorer crosses this step's own declared 50 ms `maxDuration` budget.
  static let maxAlignmentTokens = 1_000

  private let restorer: EmojiRestorer

  init(restorer: EmojiRestorer = EmojiRestorer()) {
    self.restorer = restorer
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    // Clear a prior dictation's stamp; only an AFM run below re-stamps it.
    lastRun = nil

    // Restore for the two paths whose model measurably strips emoji, and ONLY those.
    //
    // #1948 added the local Ollama prompt, MEASURED rather than assumed. Replaying this exact
    // restorer over the 98 emoji-bearing corpus cases and the stored L3 outputs: `qwen2.5:3b`
    // went from 53/98 cases keeping every input emoji to **98/98** (55 dropped, 55 restored)
    // and `llama3.2` from 6/98 to **98/98** (115 dropped, 115 restored), with **zero**
    // already-complete cases disturbed. The algorithm was never AFM-specific — it LCS-aligns
    // word streams and re-inserts only deletions — so the old gate was scope, not a
    // constraint.
    //
    // Keyed on the PROMPT FAMILY, not the provider. Cloud review caught that gating on
    // `provider == .ollama` silently included HOSTED Ollama and EG-1-served-through-Ollama,
    // because `LLMPolishStep` stamps every Ollama success with the same provider rawValue —
    // so the code included two paths the comment beside it claimed to exclude. Neither is
    // measured here: hosted models take the fixed v6 prompt that already instructs emoji
    // preservation, and EG-1 takes its training prompt. `promptFamily` is the planner's own
    // decision carried on the context, so this reads the answer rather than rebuilding it
    // from `(provider, model, polishRanRemote)`.
    //
    // Widening later is cheap and should stay evidence-led: add the family, bring the numbers.
    // AFM returns before the family stamp, so it is matched by provider and has no family.
    let isAppleIntelligence = context.llmProvider == LLMProvider.appleIntelligence.rawValue
    // BOTH must hold. `.localFixed` is only reachable through Ollama today, but a gate that
    // relies on that stays correct only by accident — and the first version of this gate was
    // wrong precisely because it trusted one field to imply the other.
    let isLocalOllama =
      context.llmProvider == LLMProvider.ollama.rawValue
      && context.promptFamily == .localFixed
    guard isAppleIntelligence || isLocalOllama else { return context }
    // Polish produced no distinct output (disabled / too-short bypass #1022 /
    // provider `.none`): delivery uses the emoji-bearing `ctx.text`, nothing to do.
    guard let polished = context.polishedText else { return context }

    // BLANK polish is a SIGNAL, not something to decorate (#1948, cloud review r6).
    // `KernelFinalizationWiring` (`:349`) treats an empty `polishedText` as the trigger for
    // its empty-output recovery floor, which delivers the intact deterministic text. Writing
    // a lone emoji into that empty string makes the result non-empty, so the floor never
    // fires and the user receives "🙏" INSTEAD OF THEIR WHOLE SENTENCE. Verified end to end:
    // a model returning "" or whitespace with an emoji-bearing input restores to exactly
    // "🙏". Reachable because `OllamaConnector` accepts a whitespace response as success and
    // trims it to "", and `validatePolishOutput` has no empty guard below 10 input words
    // (the same two facts the recovery floor's own comment names).
    //
    // Returning before the `lastRun` stamp is deliberate: no restore happened, so the
    // telemetry must not claim one.
    guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return context
    }

    // LENGTH CAP (#1948, cloud review r7). `EmojiRestorer.alignWords` allocates an
    // (n+1)x(m+1) `[[Int]]` LCS table and runs synchronously on the main actor, so its cost
    // is quadratic in dictation length. The AFM path was bounded incidentally by Apple's
    // 4096-token context (polish is skipped above it, so `polishedText` is nil and this step
    // no-ops). Local Ollama has no such ceiling and its output cap SCALES with input
    // (`LLMPolishStep` `outputTokenPolicy`), so widening the gate exposed lengths the
    // algorithm was never asked to handle.
    //
    // Measured against the real restorer on this machine: 200 words 3.6 ms / <1 MB;
    // 1,000 words 54 ms / 8 MB; 3,000 words 484 ms / 69 MB; 6,000 words 1.9 s / 275 MB;
    // 9,000 words 4.3 s / 618 MB. The app caps recording at 60 minutes (#1060), which is
    // roughly 9,000 words at a brisk pace, so the top of that table is reachable.
    //
    // The cap is set at the step's OWN declared budget rather than an invented number:
    // `maxDuration` is 50 ms, and 1,000 words is where the measurement crosses it. Above
    // that the step declines, the user keeps the polished text unchanged, and the only cost
    // is that emoji dropped from a very long dictation stay dropped. A multi-second main-
    // actor stall and hundreds of megabytes is the worse trade by a wide margin.
    //
    // A linear-space alignment (Hirschberg) would remove the cap, but that is a real change
    // to a tuned, shipped algorithm and does not belong in this PR.
    // Measured with the restorer's OWN tokenizer, not by splitting on whitespace. Cloud
    // review r7 caught that a whitespace count does not bound this: `a,b,c,...` or a long
    // URL is ONE whitespace chunk and many alignment tokens, so a whitespace guard passes
    // precisely the pathological inputs it exists to reject. The unit has to match the
    // quantity being bounded.
    //
    // SCOPED TO THE NEWLY WIDENED PATH (cloud review r8). Apple Intelligence restored emoji
    // for EVERY successful polish before #1948, bounded incidentally by Apple's own
    // 4096-token preflight — roughly 3,000 words, ~484 ms by the table above. Applying this
    // cap to AFM as well would silently withdraw restoration from long AFM dictations, which
    // is a behaviour change on a path this change is not about. Ollama has no equivalent
    // ceiling and its output cap SCALES with input, which is the exposure being bounded.
    if isLocalOllama {
      let preTokens = EmojiRestorer.alignmentTokenCount(context.text)
      let postTokens = EmojiRestorer.alignmentTokenCount(polished)
      guard max(preTokens, postTokens) <= Self.maxAlignmentTokens else { return context }
    }

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
///
/// `internal` (widened from `private` in #1525 PR H, only after measuring —
/// widening first would have corrupted the baseline). A `private`-or-narrower
/// type's bridged domain falls back to the bare simple type name
/// (`SentryBreadcrumb.structuredDescriptor`'s `(unknown context at ...)`
/// branch), never the module-qualified name — so this widening never changes
/// what was already shipping.
enum EmojiRestoreAnomaly: Error {
  case underRestore
}

// MARK: - Sentry identity

/// Pins the Sentry grouping key to the exact string this type has been
/// sending in production (#1525 PR H), mirroring `HeartPathError`'s shipped
/// pattern (#1524). Fresh 90-day Sentry search found no matching issue, so
/// this pin carries zero re-grouping risk against that window. The switch is
/// exhaustive (Codex grounded review r1), so a future second case cannot
/// silently compile in and inherit `.underRestore`'s identity.
extension EmojiRestoreAnomaly: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .underRestore: return "EmojiRestoreAnomaly#0"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .underRestore: return "emoji.restore_under_restore"
    }
  }
}
