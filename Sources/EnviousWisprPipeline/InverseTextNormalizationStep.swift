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
/// What one deadline-bounded unit of ITN work is asked to do (#2450).
///
/// ONE request type for BOTH routes, so the language-neutral route is no longer outside the injected
/// hook and a test that slows the work exercises the non-English deadline as well as the English one.
/// Everything the work needs is snapshotted into this value BEFORE the actor hop, so the closure never
/// reads mutable settings or a context.
struct ITNWorkRequest: Sendable {
  enum Route: Sendable, Equatable {
    /// The full English engine (`normalize`), exactly as before.
    case english
    /// The language-neutral subset, then, when `punctuationLanguage` is set, the start-word pass.
    case languageNeutral
  }

  let route: Route
  let input: String
  /// The whole setting as it stood when the run began. The English route reads only `.enabled`.
  let spokenPunctuation: SpokenPunctuationSettings
  /// Non-nil only when the start-word pass is ELIGIBLE for this take: a resolved base language that
  /// has a table, with the toggle on and no English veto.
  let punctuationLanguage: String?
  /// The start word to match for `punctuationLanguage`: the effective word, validated, or the
  /// language's default when the stored one fails validation.
  let startWord: String?
  /// The exact opaque tokens a fired snippet left in the text, from `protectedExpansions`.
  let protectedSentinels: [String]
}

/// What a unit of ITN work produced. `punctuationRulesFired` is nil when no punctuation pass ran.
struct ITNWorkResult: Sendable {
  let text: String
  let punctuationRulesFired: Int?
}

/// The closed vocabulary of `punctuation_status` on `dictation.completed` (#2450). A ROUTING fact:
/// it says what the start-word pass did, never whether a rewrite was right. English takes carry no
/// status. `ran_no_match` (the pass ran, nothing matched) and `timed_out` (the pass was abandoned)
/// are kept apart so a hung run can never read as an ordinary no-op.
enum SpokenPunctuationStatus: String, Sendable, CaseIterable {
  /// The toggle is off, so the pass was not attempted.
  case disabled
  /// No confident language (nil, a veto, or an LID backend that could not identify one).
  case unresolved
  /// A positively identified language that has no table. Never given another language's table.
  case unsupported
  case ranNoMatch = "ran_no_match"
  case rewrote
  case timedOut = "timed_out"
}

/// Where the start-word pass stands for one take, decided once from values the step already holds.
struct PunctuationPlan: Equatable, Sendable {
  /// Non-nil means the pass WILL be attempted for this language.
  let attemptLanguage: String?
  let startWord: String?
  /// The status to report when the pass is NOT attempted. Nil only when it is attempted.
  let notAttemptedStatus: SpokenPunctuationStatus?
}

@MainActor
final class InverseTextNormalizationStep: TextProcessingStep {
  let name = "Inverse Text Normalization"

  /// Always-on safety floor (#145, founder Gate-1 2026-06-02: ON for all, no toggle).
  var isEnabled: Bool { true }

  /// The step's own wall-clock budget, a function of length (#2770). Measured in
  /// production over 30 days (issue #2770, 2026-09-20): above 5k characters the
  /// normalizer runs at 13 to 16 µs per character at the p99/max tail, so a fixed
  /// 500 ms was exhausted by honest work at about 31k characters and a 43,449-
  /// character take lost its formatting at 511 ms. The floor stays 0.5 s: the
  /// sub-500-character outlier (459 ms, 17,966 µs/char) is the pathology this
  /// deadline exists to abandon. 40,000 chars/s is 25 µs/char, 1.6x the slowest
  /// measured tail rate. The 5 s cap covers file-import transcripts up to about
  /// 280k characters at the measured tail rate; 60-minute live takes remain below
  /// the cap. Named once so `withDeadline`, the `engine_started` comparison,
  /// `TimeoutError` and the runner backstop cannot drift apart (#2758).
  nonisolated static let floorSeconds: Double = 0.5
  nonisolated static let charsPerSecond: Double = 40_000
  nonisolated static let maxDeadlineSeconds: Double = 5

  nonisolated static func deadlineSeconds(forCharacterCount count: Int) -> Double {
    min(maxDeadlineSeconds, floorSeconds + Double(count) / charsPerSecond)
  }

  /// Runner-level runaway BACKSTOP only, 1.5 s above the step's own deadline so
  /// the runner never preempts the step (which owns the anomaly breadcrumb). The
  /// real cap is the step's own `withDeadline` in `process(...)`, a TRUE
  /// wall-clock bound that abandons a pathological `normalize` so the heart
  /// path's paste is never held.
  nonisolated static let backstopMarginSeconds: Double = 1.5
  var maxDuration: Duration {
    .seconds(Self.deadlineSeconds(forCharacterCount: 0) + Self.backstopMarginSeconds)
  }
  func maxDuration(for context: TextProcessingContext) -> Duration {
    .seconds(
      Self.deadlineSeconds(forCharacterCount: context.text.utf16.count)
        + Self.backstopMarginSeconds)
  }

  /// Spoken-punctuation sub-feature gate (#1794). Distinct from `isEnabled`, which
  /// stays `true`: the ITN limb keeps running either way, because numbers, currency,
  /// dates, times, phone, email, URL and ordinal formatting are unaffected by this
  /// setting. Only the nine bare mark rewrites and the backslash joiner are gated; the spoken
  /// slash is read in both switch positions (#3038, `InverseTextNormalizer.slashReading`).
  ///
  /// #2450: the whole setting as one value, the switch plus the per-language start words. This
  /// chunk reads only `enabled` (the English route is unchanged); the start words are carried so the
  /// routing chunk can use them without a second plumbing change.
  ///
  /// Default `.off` — the safe state for a step built in isolation (tests, and
  /// recovery before `applySettings` runs), and it matches the shipped product
  /// default. Seeded and live-updated through `KernelDictationDriver`'s façade.
  var spokenPunctuation: SpokenPunctuationSettings = .off

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
    /// True when the step changed the text. On a skipped take (`ran == false`) this is the
    /// language-neutral subset's answer (#3210, `normalizeLanguageNeutral`), which is the only
    /// thing a skipped take runs.
    let changed: Bool
    /// `nil` when it ran; otherwise the skip bucket (`non_english` / `lid_backend_nil`).
    let skipReason: String?
    /// Wall-clock of the engine call in milliseconds; on skip, of the language-neutral subset.
    let latencyMs: Double
    /// Character length before / after (edit size is allowed; #253 precedent).
    let lenBefore: Int
    let lenAfter: Int
    /// #2450: what the start-word pass did for this take. Nil on the English route (no pass exists
    /// there) and, by design, never inferred from `changed`, which also covers every other ITN
    /// conversion. Not a precision claim.
    let punctuationStatus: SpokenPunctuationStatus?
    /// #2450: the number of commands the start-word pass rewrote. Non-nil only for `rewrote` and
    /// `ran_no_match` (0). A `timed_out` run discards its count.
    let punctuationRulesFired: Int?
  }

  /// The most recent `process(...)` outcome. Read by `KernelFinalizationWiring`
  /// immediately after the chain runs (same actor, no race).
  private(set) var lastRun: RunOutcome?

  private let normalizer: InverseTextNormalizer
  /// The normalization work `withDeadline` runs, for BOTH routes. Production: `normalizer.normalize`
  /// on the English route; the language-neutral subset then the start-word pass otherwise (#2450).
  /// Tests inject slow work to exercise the length-scaled budget in milliseconds
  /// (#2770), the same seam shape as `SpeakerLabeler.makeAnalysisTask`.
  private let work: @Sendable (ITNWorkRequest) async -> ITNWorkResult
  /// Test seam only: observes the timeout breadcrumb's extra on THIS instance, so a
  /// test never installs the process-global `captureErrorDelegate`
  /// (`swift-patterns` RULE: tests-no-process-global-mutable-delegate). Production
  /// leaves it nil; the real capture below always runs.
  private let onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)?

  init(normalizer: InverseTextNormalizer = InverseTextNormalizer()) {
    self.normalizer = normalizer
    self.work = { request in
      switch request.route {
      case .english:
        return ITNWorkResult(
          text: normalizer.normalize(
            request.input, spokenPunctuation: request.spokenPunctuation.enabled),
          punctuationRulesFired: nil)
      case .languageNeutral:
        let neutral = normalizer.normalizeLanguageNeutral(request.input)
        guard let language = request.punctuationLanguage, let startWord = request.startWord else {
          return ITNWorkResult(text: neutral, punctuationRulesFired: nil)
        }
        let result = normalizer.applyStartWordPunctuation(
          neutral, language: language, startWord: startWord,
          protectedSentinels: request.protectedSentinels)
        return ITNWorkResult(text: result.text, punctuationRulesFired: result.rulesFired)
      }
    }
    self.onTimeoutForTesting = nil
  }

  /// Test seam only: `work` replaces the normalizer call under the same deadline.
  init(
    normalizer: InverseTextNormalizer = InverseTextNormalizer(),
    work: @escaping @Sendable (ITNWorkRequest) async -> ITNWorkResult,
    onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)? = nil
  ) {
    self.normalizer = normalizer
    self.work = work
    self.onTimeoutForTesting = onTimeoutForTesting
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let input = context.text
    let lenBefore = input.count
    // Budget from UTF-16 units, never below the grapheme count: the regex engine
    // walks storage, and a grapheme can span many units (a family emoji is one
    // grapheme and eleven units). `lenBefore` stays graphemes for telemetry.
    let deadline = Self.deadlineSeconds(forCharacterCount: input.utf16.count)
    // #2450: snapshot EVERYTHING the work needs, once, before any asynchronous hop. A settings edit
    // that lands mid-run applies to the NEXT take, and the whole value is read here in one place, so
    // a run can never see the old switch with new start words. The sentinels are the exact tokens
    // snippet expansion left in THIS take's text.
    let work = self.work
    let spokenPunctuationSnapshot = self.spokenPunctuation
    let protectedSentinels = context.protectedExpansions.map(\.sentinel)

    // Backend-aware language gate (plan §"What changes" #4). On skip, only the
    // language-neutral subset runs (#3210).
    if let skip = skipReason(
      language: context.language, englishVetoed: context.englishRulesVetoed)
    {
      // #3210: a take in another language still gets the subset that reads no English words:
      // digits joined by a spoken dot or dash word, unpadded dates, and addresses whose at-word
      // and dot-word belong to one language. Same off-main deadline as the full engine; a
      // timeout keeps the input.
      // #2450: the same off-main closure also runs the start-word pass when this take is eligible
      // (a resolved language with a table, the toggle on, no veto), so one deadline covers both and
      // a timeout discards BOTH, returning the whole pre-ITN text and never a neutral-only middle.
      let plan = Self.punctuationPlan(
        language: context.language, englishVetoed: context.englishRulesVetoed,
        settings: spokenPunctuationSnapshot)
      let request = ITNWorkRequest(
        route: .languageNeutral, input: input, spokenPunctuation: spokenPunctuationSnapshot,
        punctuationLanguage: plan.attemptLanguage, startWord: plan.startWord,
        protectedSentinels: protectedSentinels)
      let start = CFAbsoluteTimeGetCurrent()
      let converted = await withDeadline(seconds: deadline) {
        await work(request)
      }
      let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
      if converted == nil {
        // Same anomaly breadcrumb as the full engine's timeout below, marked with the route, so a
        // subset that hit the deadline is not read as an ordinary no-op (second-pass review).
        let timeoutExtra: [String: Any] = [
          "latency_ms": elapsedMs, "len_before": lenBefore, "deadline_ms": deadline * 1000,
          "route": "language_neutral",
        ]
        SentryBreadcrumb.captureError(
          TimeoutError(seconds: deadline),
          category: .inverseNormalizationTimeout,
          stage: "inverse_text_normalization",
          extra: timeoutExtra)
        onTimeoutForTesting?(timeoutExtra)
      }
      let output = converted?.text ?? input
      let punctuation = Self.punctuationOutcome(plan: plan, result: converted)
      lastRun = RunOutcome(
        ran: false, changed: output != input, skipReason: skip,
        latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: output.count,
        punctuationStatus: punctuation.status, punctuationRulesFired: punctuation.rulesFired)
      guard output != input else { return context }
      var ctx = context
      ctx.text = output
      return ctx
    }

    // Pure-CPU regex chain runs OFF the main actor with a TRUE wall-clock deadline.
    // `withDeadline` ABANDONS a pathological/hung `normalize` at the computed
    // length-scaled deadline (#2770) and resumes
    // immediately (unlike `withThrowingTimeout`, whose task-group scope awaits the
    // losing child — Codex r1 #1), so the heart path's paste is never held past the
    // cap. Snapshot the Sendable engine into a LOCAL first so the `@Sendable`
    // closure does not capture `self` across the actor boundary (Codex r2;
    // `swift-concurrency-patterns` snapshot rule; `withDeadline` precedent #832/#913 PR8).
    // The settings value and the work hook were snapshotted at the top of `process`, BEFORE the
    // actor hop: a toggle landing mid-run must not tear this take, which completes under the value
    // it started with (`swift-concurrency-patterns` telemetry-snapshot-not-shared-property).
    let englishRequest = ITNWorkRequest(
      route: .english, input: input, spokenPunctuation: spokenPunctuationSnapshot,
      punctuationLanguage: nil, startWord: nil, protectedSentinels: protectedSentinels)
    // `withDeadline` is a FIRST-CLAIM RACE on a shared executor, so a take still queued for a
    // cooperative thread can burn the budget without the engine ever running, and `latency_ms`
    // alone reads ~500 either way (#1946 measured that dependence for the ordered siblings).
    // Record when the closure ENTERS, relative to this call's start, so a timeout breadcrumb
    // carries at least that much instead of leaving the next occurrence as undiagnosable as the
    // last. What it CANNOT carry: `withDeadline` starts its relative sleep when its own timer
    // task is scheduled, not when this line runs, so the timer's decision instant is not
    // observable from here and the fields below are read against the NOMINAL budget instead.
    // `OSAllocatedUnfairLock` because the closure is `@Sendable`; the read happens after
    // `withDeadline` returns, back on this actor.
    let engineStart = OSAllocatedUnfairLock<Double?>(initialState: nil)
    let start = CFAbsoluteTimeGetCurrent()
    let maybeConverted = await withDeadline(seconds: deadline) {
      engineStart.withLock { $0 = CFAbsoluteTimeGetCurrent() }
      return await work(englishRequest)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    guard let converted = maybeConverted?.text else {
      // Read AFTER `withDeadline` returned, so a closure the timer already beat can still enter
      // and stamp itself — `operationTask.cancel()` cannot stop a synchronous body from being
      // scheduled. Compare the stamp against the NOMINAL BUDGET, not against `elapsedMs`:
      // `elapsedMs` is the caller's own resume time and on a loaded machine runs well past the
      // budget, so comparing against an 800 ms `elapsedMs` would accept a 600 ms entry even
      // though that entry missed the nominal budget (0.5 s floor, more for a long take, #2770).
      let engineStartMs = engineStart.withLock { $0 }.map { ($0 - start) * 1000 }
      let queueWaitMs = engineStartMs.flatMap { $0 <= deadline * 1000 ? $0 : nil }
      // Deadline hit — the (pathological) normalize was abandoned; the user gets
      // the pre-ITN text. Anomaly-only breadcrumb (Gemini: a slow run currently
      // looks like a fast no-op). Metadata only (`telemetry-privacy-boundary`).
      let timeoutExtra: [String: Any] = [
        "latency_ms": elapsedMs,
        "len_before": lenBefore,
        // #2770: the budget that applied to THIS take, so an event states its own bound.
        "deadline_ms": deadline * 1000,
        // `engine_started` = an entry stamp was observed WITHIN THE NOMINAL BUDGET. `false`
        // therefore covers both "never entered" and "entered late", and `queue_wait_ms` carries
        // the entry delay only for a qualifying start, -1 otherwise. Read as evidence, not as a
        // verdict: neither field establishes the state at the timer's own decision instant, nor
        // rules a slow `normalize` in or out, and `latency_ms` includes the caller's resumption
        // delay — so `latency_ms - queue_wait_ms` is NOT engine execution time. Timing the
        // engine itself needs a stamp at that decision, inside `withDeadline`.
        "engine_started": queueWaitMs != nil,
        "queue_wait_ms": queueWaitMs ?? -1,
      ]
      SentryBreadcrumb.captureError(
        TimeoutError(seconds: deadline),
        category: .inverseNormalizationTimeout,
        stage: "inverse_text_normalization",
        extra: timeoutExtra)
      onTimeoutForTesting?(timeoutExtra)
      lastRun = RunOutcome(
        ran: true, changed: false, skipReason: nil,
        latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: lenBefore,
        punctuationStatus: nil, punctuationRulesFired: nil)
      return context
    }

    let changed = converted != input
    lastRun = RunOutcome(
      ran: true, changed: changed, skipReason: nil,
      latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: converted.count,
      punctuationStatus: nil, punctuationRulesFired: nil)
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
    InverseTextNormalizationGate.skipReason(
      language: language, englishVetoed: englishVetoed, backendSupportsLID: backendSupportsLID)
  }
}

// MARK: - Spoken punctuation routing (#2450)

extension InverseTextNormalizationStep {

  /// Decide, from values the step already holds, whether the start-word pass runs for this SKIPPED
  /// (non-English-route) take, and which word it matches. Pure and static so the whole precedence
  /// table is one function a test can drive:
  ///
  /// | switch | veto | language | result |
  /// |---|---|---|---|
  /// | off | any | any | `disabled`, not attempted |
  /// | on | yes | any | `unresolved`, not attempted |
  /// | on | no | nil, empty or unrecognised | `unresolved`, not attempted |
  /// | on | no | resolved, no table | `unsupported`, not attempted |
  /// | on | no | resolved, has a table | attempted with the validated effective word |
  ///
  /// English never reaches here (the English route has no pass and reports no status). A positively
  /// identified language with no table is never given another language's table, and a nil language
  /// is never guessed.
  ///
  /// **A stored start word that fails validation does not widen matching.** The effective word is
  /// re-validated against the language's complete forms; if it is refused (an invalid programmatic
  /// override that bypassed `commitSpokenPunctuationStartWord`), the language's DEFAULT start word is
  /// used instead, never the invalid one.
  nonisolated static func punctuationPlan(
    language: String?, englishVetoed: Bool, settings: SpokenPunctuationSettings
  ) -> PunctuationPlan {
    func notAttempted(_ status: SpokenPunctuationStatus) -> PunctuationPlan {
      PunctuationPlan(attemptLanguage: nil, startWord: nil, notAttemptedStatus: status)
    }
    guard settings.enabled else { return notAttempted(.disabled) }
    if englishVetoed { return notAttempted(.unresolved) }
    guard let base = LanguageNormalizer.baseCode(language) else { return notAttempted(.unresolved) }
    guard let forms = SpokenPunctuationRules.spokenForms(for: base),
      let defaultWord = SpokenPunctuationRules.defaultStartWord(for: base)
    else { return notAttempted(.unsupported) }

    var startWord = defaultWord
    if let effective = SpokenPunctuationRules.effectiveStartWords(
      overrides: settings.startWordOverrides)[base],
      case .accepted(let validated) = SpokenPunctuationStartWord.validate(
        effective, language: base, spokenForms: forms)
    {
      startWord = validated
    }
    return PunctuationPlan(attemptLanguage: base, startWord: startWord, notAttemptedStatus: nil)
  }

  /// The status and count to report once the work has finished, or timed out (`result == nil`).
  /// "Not attempted", "attempted and matched nothing" and "attempted and abandoned" stay three
  /// different answers, and an abandoned run discards its count.
  nonisolated static func punctuationOutcome(plan: PunctuationPlan, result: ITNWorkResult?)
    -> (status: SpokenPunctuationStatus?, rulesFired: Int?)
  {
    guard plan.attemptLanguage != nil else { return (plan.notAttemptedStatus, nil) }
    guard let result else { return (.timedOut, nil) }
    let fired = result.punctuationRulesFired ?? 0
    return (fired > 0 ? .rewrote : .ranNoMatch, fired)
  }
}

/// The step's language gate as a pure function, public so a harness that claims to feed the
/// model what production feeds it (`scripts/eval/apple_runner --preclean`, #2844) asks THIS
/// predicate rather than carrying a copy that drifts. The step above is the only production
/// caller; the buckets and their order are documented on `skipReason` there.
public enum InverseTextNormalizationGate {
  public static func skipReason(language: String?, englishVetoed: Bool, backendSupportsLID: Bool)
    -> String?
  {
    if englishVetoed { return "language_vetoed" }
    let lang = language?.lowercased()
    if let lang, !lang.isEmpty {
      let isEnglish = lang == "en" || lang.hasPrefix("en-") || lang.hasPrefix("en_")
      return isEnglish ? nil : "non_english"
    }
    return backendSupportsLID ? "lid_backend_nil" : nil
  }
}
