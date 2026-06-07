import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

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

  /// Runner-level runaway BACKSTOP only. The real cap is the step's own 0.5s
  /// `withDeadline` in `process(...)` — a TRUE wall-clock bound that abandons a
  /// pathological `normalize` so the heart path's paste is never held. This outer
  /// bound sits comfortably above 0.5s so the runner never preempts the step's
  /// own deadline (which also owns the anomaly breadcrumb).
  var maxDuration: Duration { .seconds(2) }

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
    if let skip = skipReason(language: context.language) {
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
    let normalizer = self.normalizer
    let start = CFAbsoluteTimeGetCurrent()
    let maybeConverted = await withDeadline(seconds: 0.5) {
      normalizer.normalize(input)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    guard let converted = maybeConverted else {
      // Deadline hit — the (pathological) normalize was abandoned; the user gets
      // the pre-ITN text. Anomaly-only breadcrumb (Gemini: a slow run currently
      // looks like a fast no-op). Metadata only (`telemetry-privacy-boundary`).
      SentryBreadcrumb.captureError(
        TimeoutError(seconds: 0.5),
        category: .inverseNormalizationTimeout,
        stage: "inverse_text_normalization",
        extra: ["latency_ms": elapsedMs, "len_before": lenBefore])
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
  /// - Explicit English language → run.
  /// - Explicit non-English language → skip (`non_english`).
  /// - No language (nil/empty): the live context carries only the locked-config
  ///   language else nil; Parakeet stamps "en" internally but it never reaches here.
  ///   Run for non-LID backends (Parakeet-class, legacy English); defensively skip
  ///   for LID backends (WhisperKit), where nil means "couldn't identify"
  ///   (`lid_backend_nil`).
  private func skipReason(language: String?) -> String? {
    let lang = language?.lowercased()
    if let lang, !lang.isEmpty {
      let isEnglish = lang == "en" || lang.hasPrefix("en-") || lang.hasPrefix("en_")
      return isEnglish ? nil : "non_english"
    }
    return backendSupportsLID ? "lid_backend_nil" : nil
  }
}
