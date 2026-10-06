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
    /// A take whose language has a vetted rule set (#1677). None exist in production yet; carried so
    /// a request always names the route the gate chose.
    case language(String)
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
  /// #2450: the whole setting is snapshotted before asynchronous work. The English route reads
  /// only `enabled`; eligible non-English routes also use the validated effective start word.
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
    /// True when the take was ADMITTED to the full English route or to a vetted language route,
    /// including one that then timed out. False on the neutral route (a language-neutral subset
    /// only). It states which route the take took, not that an engine finished: a timeout still
    /// reads true here and is told apart by `changed == false` plus the timeout breadcrumb.
    let ran: Bool
    /// True when the step changed the text. On the neutral route this is the language-neutral
    /// subset's answer (#3210, `normalizeLanguageNeutral`) plus any eligible start-word rewrite
    /// (#2450). Compares the final text with the input, so an equal-length replacement is a change.
    let changed: Bool
    /// `nil` on the English and language routes; otherwise the neutral route's skip bucket
    /// (`non_english` / `lid_backend_nil` / `language_vetoed`).
    let skipReason: String?
    /// Wall-clock of the whole work operation in milliseconds, on every route.
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
    /// #2450: the language this take's punctuation routing used: `en` on the English route, the
    /// resolved base code otherwise, nil when unresolved. Not always `cleanup_language`: the
    /// preserved English route for a nil language on a non-LID engine runs English while the
    /// resolved language is still nil.
    let punctuationLanguage: String?
    /// #2450: which resolver rung answered (`locked`, `engine`, `dictation`, `document`, `none`),
    /// read from the context, never a second resolver.
    let punctuationResolutionSource: String?
  }

  /// The most recent `process(...)` outcome. Read by `KernelFinalizationWiring`
  /// immediately after the chain runs (same actor, no race).
  private(set) var lastRun: RunOutcome?

  private let normalizer: InverseTextNormalizer
  /// The rule-set registry the route AND the rule lookup both read, once per take (#1677).
  /// Production is `.production`, statically empty until the generator PR adds vetted rows; a
  /// test injects its own immutable value through the package initializer, never a global.
  private let registry: LanguageRuleRegistry
  /// Test seam: REPLACES the whole work operation (on every route) under `process`'s deadline.
  /// Production leaves it nil. Signature kept from #2770 so existing budget tests still compile.
  private let workOverride: (@Sendable (String, Bool) async -> String)?
  /// Package test seam: builds the work from the route and rule snapshot `process` prepared
  /// BEFORE its actor hop, returning the same two-argument work type. Production leaves it nil.
  private let workFactory:
    (
      @Sendable (InverseTextNormalizationGate.Route, LanguageRuleSet?) ->
        @Sendable (String, Bool) async -> String
    )?
  /// #2450 test seam: REPLACES the whole work operation with one that sees the full request
  /// (route, the settings snapshot, the start-word plan and the snippet sentinels) and may report a
  /// rules-fired count. The two-argument seams above cannot carry either, so the routing tests use
  /// this one. Production leaves it nil; it takes precedence over the other two.
  private let requestWorkOverride: (@Sendable (ITNWorkRequest) async -> ITNWorkResult)?
  /// Test seam only: observes the timeout breadcrumb's extra on THIS instance, so a
  /// test never installs the process-global `captureErrorDelegate`
  /// (`swift-patterns` RULE: tests-no-process-global-mutable-delegate). Production
  /// leaves it nil; the real capture below always runs.
  private let onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)?

  init(normalizer: InverseTextNormalizer = InverseTextNormalizer()) {
    self.normalizer = normalizer
    self.registry = .production
    self.workOverride = nil
    self.workFactory = nil
    self.requestWorkOverride = nil
    self.onTimeoutForTesting = nil
  }

  /// Test seam only: `work` replaces the whole operation under the same deadline.
  init(
    normalizer: InverseTextNormalizer = InverseTextNormalizer(),
    work: @escaping @Sendable (String, Bool) async -> String,
    onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)? = nil
  ) {
    self.normalizer = normalizer
    self.registry = .production
    self.workOverride = work
    self.workFactory = nil
    self.requestWorkOverride = nil
    self.onTimeoutForTesting = onTimeoutForTesting
  }

  /// #2450 test seam: `requestWork` replaces the whole operation under the same deadline and sees the
  /// full request, so a test can drive and read the punctuation routing on both routes.
  init(
    normalizer: InverseTextNormalizer = InverseTextNormalizer(),
    requestWork: @escaping @Sendable (ITNWorkRequest) async -> ITNWorkResult,
    onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)? = nil
  ) {
    self.normalizer = normalizer
    self.registry = .production
    self.workOverride = nil
    self.workFactory = nil
    self.requestWorkOverride = requestWork
    self.onTimeoutForTesting = onTimeoutForTesting
  }

  /// Package test seam (#1677): an injected immutable registry and an optional work factory that
  /// receives the prepared route and rule snapshot. No setter, no global, no public registration.
  package init(
    normalizer: InverseTextNormalizer = InverseTextNormalizer(),
    registry: LanguageRuleRegistry,
    workFactory: (
      @Sendable (InverseTextNormalizationGate.Route, LanguageRuleSet?) ->
        @Sendable (String, Bool) async -> String
    )? = nil,
    onTimeoutForTesting: (@MainActor ([String: Any]) -> Void)? = nil
  ) {
    self.normalizer = normalizer
    self.registry = registry
    self.workOverride = nil
    self.workFactory = workFactory
    self.requestWorkOverride = nil
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
    let spokenPunctuationSnapshot = self.spokenPunctuation
    let protectedSentinels = context.protectedExpansions.map(\.sentinel)

    // ONE route for every take (#1677). Everything the off-main work needs is read HERE, before
    // any suspension, from the SAME immutable registry value that selected the route: the route,
    // the matching rule-set snapshot, the normalizer, the punctuation flag and the work itself.
    // A settings toggle or a registry change landing mid-run cannot tear this take, and nothing
    // inside the deadline reads `self`, the registry or the language again
    // (`swift-concurrency-patterns` telemetry-snapshot-not-shared-property; the `withDeadline`
    // precedent #832/#913 PR8). The route switch below is exhaustive on purpose.
    let route = InverseTextNormalizationGate.route(
      language: context.language, englishVetoed: context.englishRulesVetoed,
      backendSupportsLID: backendSupportsLID, registry: registry)
    let rules: LanguageRuleSet?
    let admitted: Bool
    let skipReason: String?
    let routeLabel: String
    let requestRoute: ITNWorkRequest.Route
    let punctuationLanguage: String?
    // #2450: the start-word pass belongs to the NEUTRAL route, and to the ENGLISH route only while the
    // user has given English a start word (its default is none: bare words, no pass, no status). A
    // vetted language route (none in production yet) owns its own passes.
    let plan: PunctuationPlan?
    switch route {
    case .english:
      rules = nil
      admitted = true
      skipReason = nil
      routeLabel = "english"
      requestRoute = .english
      punctuationLanguage = "en"
      plan = Self.englishPunctuationPlan(settings: spokenPunctuationSnapshot)
    case .language(let code):
      rules = registry.ruleSet(forLanguage: context.language)
      admitted = true
      skipReason = nil
      routeLabel = "language:\(code)"
      requestRoute = .language(code)
      punctuationLanguage = code
      plan = nil
    case .neutral(let reason):
      rules = nil
      admitted = false
      skipReason = reason
      routeLabel = "neutral"
      requestRoute = .languageNeutral
      punctuationLanguage = LanguageNormalizer.baseCode(context.language)
      plan = Self.punctuationPlan(
        language: context.language, englishVetoed: context.englishRulesVetoed,
        settings: spokenPunctuationSnapshot)
    }
    // With an English start word the bare English words must NOT convert, so the normalizer is told the
    // plain switch is off for this take and the start-word pass below does the converting.
    var normalizerSettings = spokenPunctuationSnapshot
    if case .english = route, plan != nil { normalizerSettings.enabled = false }
    let request = ITNWorkRequest(
      route: requestRoute, input: input, spokenPunctuation: normalizerSettings,
      punctuationLanguage: plan?.attemptLanguage, startWord: plan?.startWord,
      protectedSentinels: protectedSentinels)
    let work: @Sendable (ITNWorkRequest) async -> ITNWorkResult
    if let requestWorkOverride {
      work = requestWorkOverride
    } else if let workOverride {
      work = { request in
        ITNWorkResult(
          text: await workOverride(request.input, request.spokenPunctuation.enabled),
          punctuationRulesFired: nil)
      }
    } else if let workFactory {
      let built = workFactory(route, rules)
      work = { request in
        ITNWorkResult(
          text: await built(request.input, request.spokenPunctuation.enabled),
          punctuationRulesFired: nil)
      }
    } else {
      let normalizer = self.normalizer
      work = { request in
        // The text work for every route is the gate's single implementation (#1677).
        let text = InverseTextNormalizationGate.execute(
          request.input, route: route, rules: rules, normalizer: normalizer,
          spokenPunctuation: request.spokenPunctuation.enabled)
        // #2450: when this take has a plan (neutral route, or English with a start word), the
        // start-word pass runs INSIDE the same closure, so one deadline covers both and a timeout
        // discards both, returning the whole pre-ITN text.
        guard let language = request.punctuationLanguage,
          let startWord = request.startWord
        else { return ITNWorkResult(text: text, punctuationRulesFired: nil) }
        let result = normalizer.applyStartWordPunctuation(
          text, language: language, startWord: startWord,
          protectedSentinels: request.protectedSentinels)
        return ITNWorkResult(text: result.text, punctuationRulesFired: result.rulesFired)
      }
    }

    // Pure-CPU regex chain runs OFF the main actor with a TRUE wall-clock deadline, the SAME one
    // for every route: neutral and language work share this single budget, there is no nested
    // timeout and no intermediate committed output. `withDeadline` ABANDONS a pathological or
    // hung operation at the computed length-scaled deadline (#2770) and resumes immediately
    // (unlike `withThrowingTimeout`, whose task-group scope awaits the losing child — Codex r2
    // #1), so the heart path's paste is never held past the cap.
    //
    // `withDeadline` is a FIRST-CLAIM RACE on a shared executor, so a take still queued for a
    // cooperative thread can burn the budget without the work ever running, and `latency_ms`
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
    let maybeResult = await withDeadline(seconds: deadline) {
      engineStart.withLock { $0 = CFAbsoluteTimeGetCurrent() }
      return await work(request)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    // "Not attempted", "attempted and matched nothing" and "attempted and abandoned" stay three
    // different answers, and an abandoned run discards its count. The language routes, and the English
    // route without a start word, have no start-word pass, so they report neither a status nor a count.
    let punctuation: (status: SpokenPunctuationStatus?, rulesFired: Int?) =
      plan.map { Self.punctuationOutcome(plan: $0, result: maybeResult) } ?? (nil, nil)
    guard let converted = maybeResult?.text else {
      // Read AFTER `withDeadline` returned, so a closure the timer already beat can still enter
      // and stamp itself — `operationTask.cancel()` cannot stop a synchronous body from being
      // scheduled. Compare the stamp against the NOMINAL BUDGET, not against `elapsedMs`:
      // `elapsedMs` is the caller's own resume time and on a loaded machine runs well past the
      // budget, so comparing against an 800 ms `elapsedMs` would accept a 600 ms entry even
      // though that entry missed the nominal budget (0.5 s floor, more for a long take, #2770).
      let engineStartMs = engineStart.withLock { $0 }.map { ($0 - start) * 1000 }
      let queueWaitMs = engineStartMs.flatMap { $0 <= deadline * 1000 ? $0 : nil }
      // Deadline hit — the (pathological) work was abandoned and the user gets the ENTIRE
      // pre-ITN text, never a partial neutral or language result. Anomaly-only breadcrumb
      // (Gemini: a slow run currently looks like a fast no-op). `route` classifies which route
      // timed out. Metadata only (`telemetry-privacy-boundary`).
      let timeoutExtra: [String: Any] = [
        "latency_ms": elapsedMs,
        "len_before": lenBefore,
        // #2770: the budget that applied to THIS take, so an event states its own bound.
        "deadline_ms": deadline * 1000,
        // `engine_started` = an entry stamp was observed WITHIN THE NOMINAL BUDGET. `false`
        // therefore covers both "never entered" and "entered late", and `queue_wait_ms` carries
        // the entry delay only for a qualifying start, -1 otherwise. Read as evidence, not as a
        // verdict: neither field establishes the state at the timer's own decision instant, nor
        // rules a slow operation in or out, and `latency_ms` includes the caller's resumption
        // delay — so `latency_ms - queue_wait_ms` is NOT execution time. Timing the work itself
        // needs a stamp at that decision, inside `withDeadline`.
        "engine_started": queueWaitMs != nil,
        "queue_wait_ms": queueWaitMs ?? -1,
        // `english`, `neutral` or `language:<canonical base code>`; replaces the old
        // `language_neutral` value, which only the neutral path carried.
        "route": routeLabel,
      ]
      SentryBreadcrumb.captureError(
        TimeoutError(seconds: deadline),
        category: .inverseNormalizationTimeout,
        stage: "inverse_text_normalization",
        extra: timeoutExtra)
      onTimeoutForTesting?(timeoutExtra)
      lastRun = RunOutcome(
        ran: admitted, changed: false, skipReason: skipReason,
        latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: lenBefore,
        punctuationStatus: punctuation.status, punctuationRulesFired: punctuation.rulesFired,
        punctuationLanguage: punctuationLanguage,
        punctuationResolutionSource: context.languageSource?.rawValue)
      return context
    }

    let changed = converted != input
    lastRun = RunOutcome(
      ran: admitted, changed: changed, skipReason: skipReason,
      latencyMs: elapsedMs, lenBefore: lenBefore, lenAfter: converted.count,
      punctuationStatus: punctuation.status, punctuationRulesFired: punctuation.rulesFired,
      punctuationLanguage: punctuationLanguage,
      punctuationResolutionSource: context.languageSource?.rawValue)
    // Per-step IN:/OUT: + PipelineTiming traces are emitted by `TextProcessingRunner`
    // for every step (DEBUG-gated, local-only) — no duplicate logging here.
    if !changed { return context }

    var ctx = context
    ctx.text = converted
    return ctx
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
      overrides: settings.startWordOverrides)[base]
    {
      if effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // The user chose NO start word: the pass reads this language's command words bare.
        startWord = ""
      } else if case .accepted(let validated) = SpokenPunctuationStartWord.validate(
        effective, language: base, spokenForms: forms)
      {
        startWord = validated
      }
    }
    return PunctuationPlan(attemptLanguage: base, startWord: startWord, notAttemptedStatus: nil)
  }

  /// The English route's plan: `nil` (the bare English words, no pass, no status, exactly as before)
  /// unless the switch is on AND English has a start word. A stored English word that fails validation
  /// does not widen anything: it falls back to the default, no start word.
  nonisolated static func englishPunctuationPlan(settings: SpokenPunctuationSettings)
    -> PunctuationPlan?
  {
    guard settings.enabled, let forms = SpokenPunctuationRules.startWordForms(for: "en"),
      let effective = SpokenPunctuationRules.effectiveStartWords(
        overrides: settings.startWordOverrides)["en"],
      !effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      case .accepted(let validated) = SpokenPunctuationStartWord.validate(
        effective, language: "en", spokenForms: forms)
    else { return nil }
    return PunctuationPlan(attemptLanguage: "en", startWord: validated, notAttemptedStatus: nil)
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

/// The step's language route and text execution as pure functions, public so a harness that claims
/// to feed the model what production feeds it (`scripts/eval/apple_runner --preclean`, #2844, #1677)
/// asks THIS owner rather than carrying a copy that drifts. The step above is the only production
/// caller of `route(...)` and `execute(...)`; the legacy buckets and their order are documented on
/// `skipReason`, which `route` consults first and never reimplements.
public enum InverseTextNormalizationGate {
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

  /// Which cleanup a take receives (#1677). The single answer the step and the eval harness both
  /// ask, instead of each deciding "is this English?" for itself.
  public enum Route: Sendable, Equatable {
    /// The English engine runs, exactly as before.
    case english
    /// The take's explicit non-English language has a vetted rule set: the language-neutral subset
    /// plus that language's passes, never the English lexicon. Carries the canonical base code.
    case language(String)
    /// The language-neutral subset only, with the legacy skip bucket
    /// (`language_vetoed`, `non_english`, `lid_backend_nil`) that telemetry already reports.
    case neutral(String)
  }

  /// Pure routing over the shipped (currently EMPTY) rule-set registry.
  ///
  /// **Precedence is the legacy gate's, not a second predicate:** `skipReason` decides first and
  /// stays the only owner of veto-first, the exact lowercase `en` / `en-` / `en_` English test, the
  /// treatment of every explicit non-English value (including one `LanguageNormalizer.baseCode`
  /// rejects), and the fact that only raw nil or empty consults `backendSupportsLID`. The registry
  /// is consulted ONLY for an explicit non-English value (`non_english`); a veto, a missing language
  /// and an English value can never become `.language`. A missing registry entry fails closed to
  /// `.neutral("non_english")`.
  public static func route(language: String?, englishVetoed: Bool, backendSupportsLID: Bool)
    -> Route
  {
    route(
      language: language, englishVetoed: englishVetoed, backendSupportsLID: backendSupportsLID,
      registry: .production)
  }

  /// The same route over an injected registry, for tests. `package` so no caller outside this
  /// package can register a language.
  package static func route(
    language: String?, englishVetoed: Bool, backendSupportsLID: Bool,
    registry: LanguageRuleRegistry
  ) -> Route {
    guard
      let skip = skipReason(
        language: language, englishVetoed: englishVetoed, backendSupportsLID: backendSupportsLID)
    else { return .english }
    if skip == "non_english", let set = registry.ruleSet(forLanguage: language) {
      return .language(set.baseCode)
    }
    return .neutral(skip)
  }

  /// The ONE text-execution implementation for every route (#1677): the step's production work
  /// and the eval harness both run it, so no second dispatch switch exists. It takes an
  /// already-selected route plus the immutable rule snapshot; it never resolves language and
  /// never reproduces the route's precedence.
  ///
  /// `.language` executes only with a snapshot whose base code matches the route. A forged or
  /// missing snapshot fails CLOSED to the neutral subset; it never force-unwraps and never falls
  /// through to the English lexicon.
  package static func execute(
    _ text: String, route: Route, rules: LanguageRuleSet?, normalizer: InverseTextNormalizer,
    spokenPunctuation: Bool
  ) -> String {
    switch route {
    case .english:
      return normalizer.normalize(text, spokenPunctuation: spokenPunctuation)
    case .neutral:
      return normalizer.normalizeLanguageNeutral(text)
    case .language(let code):
      guard let rules, rules.baseCode == code else {
        return normalizer.normalizeLanguageNeutral(text)
      }
      return normalizer.normalize(text, language: rules)
    }
  }

  /// Public execution facade for callers outside this package.
  ///
  /// **Why this one member is public:** the eval harness (`scripts/eval/apple_runner`) is a separate
  /// package and cannot call a `package` member, and it must run the SAME text execution as
  /// production instead of carrying its own copy (the #2844 drift this gate already exists to
  /// prevent). It accepts a route the caller already selected with `route(...)`; it does not
  /// resolve language or copy the precedence. For `.language` it obtains the production rule-set
  /// snapshot before executing synchronously, so a route with no vetted production snapshot (which
  /// is every route today, the registry being empty) runs the neutral subset.
  public static func normalize(
    _ text: String, route: Route, normalizer: InverseTextNormalizer, spokenPunctuation: Bool
  ) -> String {
    let rules: LanguageRuleSet?
    if case .language(let code) = route {
      rules = LanguageRuleRegistry.production.ruleSet(forLanguage: code)
    } else {
      rules = nil
    }
    return execute(
      text, route: route, rules: rules, normalizer: normalizer,
      spokenPunctuation: spokenPunctuation)
  }
}
