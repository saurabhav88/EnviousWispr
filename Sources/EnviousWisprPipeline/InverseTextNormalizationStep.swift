import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import os

/// Deterministic inverse text normalization (spoken-form → written-form) as a post-ASR
/// limb: "two zero three nine five four…" → "203-954-8879", "twenty twenty six" → "2026",
/// "eighty million dollars" → "$80 million". The engine (`InverseTextNormalizer`) won the
/// #145 ITN bake-off; this is the thin pipeline wrapper around it.
///
/// Design contract + parity validation: `docs/feature-requests/issue-145-2026-06-02-itn-swift-port.md`.
/// Wiring + rollout: `docs/feature-requests/issue-145-2026-06-02-itn-wiring.md`.
///
/// Placement: runs in the limb chain BEFORE `LLMPolishStep`, so it doubles as the
/// raw-fallback floor — if polish is disabled/rejected/unavailable the user keeps the
/// formatted text instead of word-soup (the #949 contact-block incident).
///
/// Limb semantics (heart & limbs): never blocks the heart path. The engine is pure CPU,
/// so it runs OFF the main actor (the `WordCorrectionStep` pattern) and a no-op returns
/// the input context untouched. Founder Gate-1 (2026-06-02): always ON, no user toggle.
@MainActor
final class InverseTextNormalizationStep: TextProcessingStep {
  let name = "Inverse Text Normalization"

  /// Always-on safety floor (#145, founder Gate-1 2026-06-02: ON for all, no toggle).
  var isEnabled: Bool { true }

  /// The step's own wall-clock budget: the `withDeadline` in `process(...)`, the seconds the
  /// `TimeoutError` reports, and the line the timeout breadcrumb's `engine_started` is decided
  /// against. Named once so those three cannot drift apart (#2758).
  static let deadlineSeconds: Double = 0.5

  /// Runner-level runaway BACKSTOP only. The real cap is the step's own 0.5s
  /// `withDeadline` in `process(...)` — a TRUE wall-clock bound that abandons a
  /// pathological `normalize` so the heart path's paste is never held. This outer
  /// bound sits comfortably above 0.5s so the runner never preempts the step's
  /// own deadline (which also owns the anomaly breadcrumb).
  var maxDuration: Duration { .seconds(2) }

  /// Spoken-punctuation sub-feature gate (#1794). Distinct from `isEnabled`, which
  /// stays `true`: the ITN limb keeps running either way, because numbers, currency,
  /// dates, times, phone, email, URL and ordinal formatting are unaffected by this
  /// setting. Only the nine bare command rewrites are gated.
  ///
  /// Default `false` — the safe state for a step built in isolation (tests, and
  /// recovery before `applySettings` runs), and it matches the shipped product
  /// default. Seeded and live-updated through `KernelDictationDriver`'s façade.
  var spokenPunctuationEnabled: Bool = false

  /// Per-session capability hint wired by `KernelFinalizationWiring` from
  /// `adapter.capabilities.supportsLanguageDetection` — NOT an engine-identity
  /// literal (`EngineIdentityFreezeTests` bans identity reads at non-factory sites).
  /// Default `false` = legacy / Parakeet-class (run on English-or-unknown), the
  /// always-on intent for steps constructed in isolation (tests).
  var backendSupportsLID: Bool = false

  /// Per-run outcome the wiring reads after the chain runs to thread ITN fields onto
  /// `dictation.completed`. Metadata only (counts/lengths/latency/skip-reason) — never
  /// transcript text (`telemetry-privacy-boundary`).
  struct RunOutcome: Sendable {
    /// True when the engine actually ran (not gated out by language).
    let ran: Bool
    /// True when the engine changed the text.
    let changed: Bool
    /// `nil` when it ran; otherwise the skip bucket (`non_english` / `lid_backend_nil`).
    let skipReason: String?
    /// Wall-clock of the engine call in milliseconds (0 on skip).
    let latencyMs: Double
    /// Character length before / after (edit size is allowed; #253 precedent).
    let lenBefore: Int
    let lenAfter: Int
  }

  /// The most recent `process(...)` outcome. Read by `KernelFinalizationWiring`
  /// immediately after the chain runs (same actor, no race).
  private(set) var lastRun: RunOutcome?

  private let normalizer: InverseTextNormalizer

  init(normalizer: InverseTextNormalizer = InverseTextNormalizer()) {
    self.normalizer = normalizer
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let input = context.text
    let lenBefore = input.count

    // Backend-aware language gate (plan §"What changes" #4). On skip, no-op.
    if let skip = skipReason(
      language: context.language, englishVetoed: context.englishRulesVetoed)
    {
      lastRun = RunOutcome(
        ran: false, changed: false, skipReason: skip,
        latencyMs: 0, lenBefore: lenBefore, lenAfter: lenBefore)
      return context
    }

    // Pure-CPU regex chain runs OFF the main actor with a TRUE wall-clock deadline.
    // `withDeadline` ABANDONS a pathological/hung `normalize` at 0.5s and resumes
    // immediately (unlike `withThrowingTimeout`, whose task-group scope awaits the
    // losing child — Codex r1 #1), so the heart path's paste is never held past the
    // cap. Snapshot the Sendable engine into a LOCAL first so the `@Sendable`
    // closure does not capture `self` across the actor boundary (Codex r2;
    // `swift-concurrency-patterns` snapshot rule; `withDeadline` precedent #832/#913 PR8).
    // Snapshot the flag alongside the normalizer BEFORE the actor hop: a toggle
    // landing mid-run must not tear this take, which completes under the value it
    // started with (`swift-concurrency-patterns` telemetry-snapshot-not-shared-property).
    let normalizer = self.normalizer
    let spokenPunctuation = self.spokenPunctuationEnabled
    // `withDeadline` is a FIRST-CLAIM RACE on a shared executor, and the budget is spent from
    // THIS clock: an operation task still queued for a cooperative thread burns exactly the same
    // 0.5s a genuinely slow `normalize` does, and `latency_ms` alone reads ~500 either way. #1946
    // measured that dependence for the ordered siblings; the same one applies here. Stamp the
    // instant the closure actually BEGINS so a timeout breadcrumb says which of the two it was —
    // engine work, or a take that never got a thread — instead of leaving the next occurrence as
    // undiagnosable as the last. `OSAllocatedUnfairLock` because the closure is `@Sendable`; the
    // read below happens after `withDeadline` returns, back on this actor.
    let engineStart = OSAllocatedUnfairLock<Double?>(initialState: nil)
    let start = CFAbsoluteTimeGetCurrent()
    let maybeConverted = await withDeadline(seconds: Self.deadlineSeconds) {
      engineStart.withLock { $0 = CFAbsoluteTimeGetCurrent() }
      return normalizer.normalize(input, spokenPunctuation: spokenPunctuation)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    guard let converted = maybeConverted else {
      // Read AFTER `withDeadline` returned, so a closure the timer already beat can still enter
      // and stamp itself — `operationTask.cancel()` cannot stop a synchronous body from being
      // scheduled. Compare the stamp against the BUDGET, not against `elapsedMs`: `elapsedMs` is
      // the caller's own resume time and on a loaded machine runs well past the budget, so a
      // closure that entered at 600 ms would clear a 800 ms `elapsedMs` and be reported as having
      // been running when the timer won, which it was not.
      let engineStartMs = engineStart.withLock { $0 }.map { ($0 - start) * 1000 }
      let queueWaitMs = engineStartMs.flatMap { $0 <= Self.deadlineSeconds * 1000 ? $0 : nil }
      // Deadline hit — the (pathological) normalize was abandoned; the user gets
      // the pre-ITN text. Anomaly-only breadcrumb (Gemini: a slow run currently
      // looks like a fast no-op). Metadata only (`telemetry-privacy-boundary`).
      SentryBreadcrumb.captureError(
        TimeoutError(seconds: Self.deadlineSeconds),
        category: .inverseNormalizationTimeout,
        stage: "inverse_text_normalization",
        extra: [
          "latency_ms": elapsedMs,
          "len_before": lenBefore,
          // false = no closure entry was observed within the budget, so the deadline was spent
          // QUEUED rather than normalizing and nothing about the engine is implicated. True
          // carries the delay to closure ENTRY. Read the pair as "did the engine get a thread in
          // time, and how long did it wait" — `latency_ms` is the caller's own resume time and
          // overshoots the budget under load, so `latency_ms - queue_wait_ms` is NOT engine
          // execution time. Timing the engine itself needs a stamp at the timer's decision, which
          // is inside `withDeadline` and not available here.
          "engine_started": queueWaitMs != nil,
          "queue_wait_ms": queueWaitMs ?? -1,
        ])
      lastRun = RunOutcome(
        ran: true, changed: false, skipReason: nil,
        latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: lenBefore)
      return context
    }

    let changed = converted != input
    lastRun = RunOutcome(
      ran: true, changed: changed, skipReason: nil,
      latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: converted.count)
    // Per-step IN:/OUT: + PipelineTiming traces are emitted by `TextProcessingRunner`
    // for every step (DEBUG-gated, local-only) — no duplicate logging here.
    if !changed { return context }

    var ctx = context
    ctx.text = converted
    return ctx
  }

  /// Backend-aware language gate. Returns `nil` to RUN, or a skip-reason bucket.
  ///
  /// - The resolver vetoed English rules (#2614): skip (`language_vetoed`). First,
  ///   because a veto is only ever set on the nil-language abstention path, so a
  ///   locked or engine-resolved take can never reach it.
  /// - Explicit English language → run.
  /// - Explicit non-English language → skip (`non_english`).
  /// - No language (nil/empty): since #2614 the context carries the RESOLVED
  ///   language (lock, detecting engine, or the text at the resolver's floor), so
  ///   nil now means the resolver abstained without a veto. (Parakeet used to
  ///   stamp "en" on its result, which never reached here anyway; #1678 removed
  ///   that constant — it reports nil now.) Run for non-LID backends
  ///   (Parakeet-class, legacy English); defensively skip for LID backends
  ///   (WhisperKit), where nil means "couldn't identify" (`lid_backend_nil`).
  private func skipReason(language: String?, englishVetoed: Bool) -> String? {
    if englishVetoed { return "language_vetoed" }
    let lang = language?.lowercased()
    if let lang, !lang.isEmpty {
      let isEnglish = lang == "en" || lang.hasPrefix("en-") || lang.hasPrefix("en_")
      return isEnglish ? nil : "non_english"
    }
    return backendSupportsLID ? "lid_backend_nil" : nil
  }
}
