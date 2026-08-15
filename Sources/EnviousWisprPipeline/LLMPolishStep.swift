import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Polishes transcribed text using an LLM provider.
///
/// Phase 0 (#640) — receives the polish lane (built-in + user terms only;
/// pack terms NEVER reach this step). Adopts `PolishVocabularyConsumer`
/// instead of the prior `CustomWordsConsumer`. Bible §2.2.
@MainActor
public final class LLMPolishStep: TextProcessingStep, PolishVocabularyConsumer {
  public let name = "LLM Polish"

  /// LLM polish failures are user-visible: surface them to `polishError` so
  /// the runner shows the "AI polish failed" banner. All other steps inherit
  /// the default `.swallow` from the protocol extension.
  internal var errorSurfacePolicy: ErrorSurfacePolicy { .surface }

  public var llmProvider: LLMProvider = .none
  public var llmModel: String = LLMProvider.defaultModel(for: .openAI)
  public var polishInstructions: PolishInstructions = .default
  public var useExtendedThinking: Bool = false
  public var polishVocabulary: PolishVocabulary = .empty

  // MARK: - Multilingual v1 (W3)

  /// Language detection outcome from the autodetect stack. Set by
  /// `WhisperKitPipeline` after the detector runs, before finalization.
  /// Nil for the Parakeet highway or pre-W2 callsites. The planner falls
  /// back to legacy (locked-equivalent) behavior when nil.
  public var languageDetection: LanguageDetectionResult?

  /// Active ASR backend for this polish step. Set at init time by the
  /// owning pipeline (Parakeet or WhisperKit) so the prompt planner can
  /// dispatch on explicit engine identity rather than inferring it from
  /// the absence of `languageDetection`. Nil for standalone callsites
  /// (e.g. crash-recovery's `RecoveryTextProcessor`, #1063) that do not know
  /// the original ASR engine; the planner preserves legacy passthrough then.
  public var backend: ASRBackendType?

  /// Injectable prompt planner. DefaultPromptPlanner in production, mockable in tests.
  public var promptPlanner: any PromptPlanning = DefaultPromptPlanner()

  /// Injectable polisher factory (#827 PR-8). Default reproduces the per-provider
  /// connector switch; returns nil for `.none` so the call site owns the
  /// breadcrumb plus throw. Tests inject a controllable polisher to exercise the
  /// post-await settings snapshot. Mirrors `promptPlanner` above; `internal`
  /// because only the same-module factory and `@testable` tests reach it.
  typealias PolisherFactory = @MainActor (LLMProvider, KeychainManager, OutputClassifierProtocol?)
    ->
    (any TranscriptPolisher)?
  var makePolisher: PolisherFactory = { provider, keychain, classifier in
    switch provider {
    case .openAI: OpenAIConnector(keychainManager: keychain)
    case .gemini: GeminiConnector(keychainManager: keychain)
    case .claude: ClaudeConnector(keychainManager: keychain)
    case .ollama: OllamaConnector()
    // #832/#913 PR8: the on-device output-safety classifier runs ONLY on Apple
    // Intelligence output (the path where AFM can compose artifacts). Injected
    // via init — fail-open when nil (not yet prewarmed / load failed).
    case .appleIntelligence: AppleIntelligenceConnector(classifier: classifier)
    // #1271: the EG-1 connector needs the live server endpoint, which this
    // three-argument seam does not carry. `process()` routes `.egOne`
    // through `makeEGOnePolisher` + `egOneRuntime` BEFORE consulting this
    // factory; reaching this case means no runtime handle was injected —
    // return nil and let the call site's `.egOne` branch throw the silent
    // bypass (never the surfaced `providerUnavailable`).
    case .egOne: nil
    case .none: nil
    }
  }

  /// EG-1 runtime handle (#1271), injected by the composition root through
  /// `KernelDictationDriverFactory` / `RecoveryTextProcessor` — same
  /// threading as `keychainManager`. Nil (standalone callsites, tests, or
  /// pre-wiring) means every `.egOne` polish silently skips.
  public var egOneRuntime: (any EGOneEndpointProviding)?

  /// Test seam for `.egOne` (mirrors `makePolisher` for the other
  /// providers): production builds the localhost connector from the live
  /// endpoint; tests substitute a spy without a real server.
  var makeEGOnePolisher: @MainActor (EGOneEndpoint) -> any TranscriptPolisher = {
    EGOneConnector(endpoint: $0)
  }

  /// #1305 test seam (mirrors `makeEGOnePolisher`): the Ollama readiness
  /// preflight consulted by the `.ollama` entry gate in `process()`.
  /// Production probes the real connector (one GET /api/tags on the same base
  /// URL polish would use, ~1s hard ceiling); tests inject a fixed answer so
  /// the gate is exercised without a live server.
  var ollamaReadinessProbe: @MainActor (String) async -> OllamaReadiness = { model in
    await OllamaConnector().preflightReadiness(model: model)
  }

  /// Holds the app-owned output-safety classifier (#832/#913 PR8). Read LAZILY
  /// at polish time (not at build time) so the value set after async prewarm is
  /// picked up by the next polish. Nil for standalone callsites without one.
  public var outputClassifierHolder: OutputClassifierHolder?

  /// Called before LLM processing starts (pipeline uses this to set .polishing state).
  public var onWillProcess: (() -> Void)?

  /// Streaming token callback — invoked with each text fragment as it arrives from the LLM.
  public var onToken: (@Sendable (String) -> Void)?

  private let keychainManager: KeychainManager
  private let telemetry: TelemetrySeams

  /// Every telemetry signal this step owns, as ONE value (#1461) — mirrors
  /// `TextProcessingRunner.TelemetrySeams` exactly (struct-of-closures,
  /// `.live`/`.silent` static presets, memberwise init), deliberately kept as
  /// a SEPARATE type: the two gate different call sites and different
  /// failure domains, so merging them would couple unrelated owners.
  ///
  /// Before this type, `RecoveryTextProcessor` could silence the runner's own
  /// three seams via `TextProcessingRunner.TelemetrySeams.silent` but had no
  /// way to reach this step's own emitters (5 pre-existing, plus the too-short
  /// skip event this plan adds) — they fired identically on a live take and a
  /// recovered replay. This seam closes that gap.
  struct TelemetrySeams {
    let limbFailureObserved: @MainActor (String, String, String, String, Int?) -> Void
    let breadcrumbStarted: @MainActor (String, [String: Any]?) -> Void
    let captureProviderInitError: @MainActor (any Error & StableSentryErrorIdentity) -> Void
    let captureAFMPolishError: @MainActor (any Error) -> Void
    let breadcrumbCompleted: @MainActor (String, [String: Any]?) -> Void
    /// The too-short bypass's own emit — this path returns from `process()`
    /// before `TextProcessingRunner` ever sees it, so the step must own this
    /// emission itself (#1448). Every OTHER skip reason (the AFM trio,
    /// EG-1, context-window, Ollama preflight) remains the runner's
    /// responsibility, routed through its own, separate `recordPolishSkipped`
    /// seam — this field does not duplicate that.
    /// `takeID` (#1846) is the LIVE in-flight take — polish runs before the session
    /// terminal, so the concluded key is not yet stamped.
    let recordPolishSkipped: @MainActor (String, String, String?) -> Void

    static let live = TelemetrySeams(
      limbFailureObserved: { limb, op, result, cat, dur in
        TelemetryService.shared.limbFailureObserved(
          limb: limb, operation: op, result: result, errorCategory: cat, durationMs: dur)
      },
      breadcrumbStarted: { message, data in
        SentryBreadcrumb.add(stage: "polish", message: message, data: data)
      },
      captureProviderInitError: { error in
        SentryBreadcrumb.captureError(error, category: .providerInitFailed, stage: "polish")
      },
      captureAFMPolishError: { error in
        SentryBreadcrumb.captureAFMPolishError(error)
      },
      breadcrumbCompleted: { message, data in
        SentryBreadcrumb.add(stage: "polish", message: message, data: data)
      },
      recordPolishSkipped: { provider, reason, takeID in
        TelemetryService.shared.polishSkipped(provider: provider, reason: reason, takeID: takeID)
      })

    /// Returns a seam that discards every signal unconditionally — `seams` is
    /// intentionally unused by the discarding closures, so the guarantee does
    /// not depend on what's wrapped. Defaulted to `.live` so production call
    /// sites keep the old `.silent` shape (`telemetry: .silent()`); this is
    /// the ONLY definition of "silent" (#1593) — there is no separate hardcoded
    /// no-op constant a future edit could let drift out of sync with it, and
    /// a test can inject a spy-backed seam here and assert the spy recorded
    /// zero calls, proving the discard mechanism itself rather than only
    /// reading the closure bodies below by eye.
    static func silent(wrapping seams: TelemetrySeams = .live) -> TelemetrySeams {
      TelemetrySeams(
        limbFailureObserved: { _, _, _, _, _ in },
        breadcrumbStarted: { _, _ in },
        captureProviderInitError: { _ in },
        captureAFMPolishError: { _ in },
        breadcrumbCompleted: { _, _ in },
        recordPolishSkipped: { _, _, _ in })
    }
  }

  public var isEnabled: Bool {
    llmProvider != .none
  }

  /// Provider-aware timeout budget for providers whose cost does not scale here.
  /// (#1770 corrected an older claim on this line that "cloud providers respond
  /// in <2s so 5s is generous": false for Gemini on the measured long
  /// dictations (11,324 chars took 6.12s, 66,896 took 50.65s), and #158 already
  /// measured a 9.16s Claude call. Gemini now
  /// scales via `maxDuration(for:)` below; the rest keep fixed budgets, and
  /// OpenAI/Claude are #1833.)
  /// Local models (Ollama 12B) generate ~18 tok/s and need 10-15s for long dictations.
  /// Apple Intelligence runs on-device with variable latency depending on model size.
  public var maxDuration: Duration {
    switch llmProvider {
    case .ollama: return .seconds(15)
    // #1271: EG-1 runs the same class of local generation as Ollama (a 4B
    // model at local token rates on long dictations) — same 15 s budget,
    // precedent-cited from the `.ollama` line above. A timeout is a SILENT
    // skip for this provider (TextProcessingRunner), never a surfaced error.
    case .egOne: return .seconds(15)
    case .appleIntelligence: return .seconds(10)
    // #158 pre-merge latency receipt (30 real calls, Haiku + Sonnet 4.6,
    // short/medium/long): observed max 7.47s (Sonnet, long bucket), with
    // two Haiku calls over 4.6s. The shared 5 s backstop below would
    // truncate that real tail. The picker offers every live-discovered
    // model, including several Opus tiers the bucketed receipt never
    // measured — the separate all-models sweep recorded a real successful
    // claude-opus-4-5-20251101 call at 9.16s (Codex r10), which would leave
    // almost no margin under a 10s deadline before TextProcessingRunner
    // cancels a valid in-flight polish and silently falls back to raw text.
    // 15s matches Ollama/EG-1's existing local-generation precedent above
    // rather than inventing a new number, with real headroom over the
    // worst real value measured across every offered model so far.
    case .claude: return .seconds(15)
    case .openAI, .gemini, .none: return .seconds(5)
    }
  }

  /// Gemini's budget scales with the transcript; every other provider keeps its
  /// fixed one (#1770).
  ///
  /// A fixed 5 s was timing out long dictations. Measured live against
  /// real dictations, Gemini in fast mode: 1,709 chars -> 1.33 s, 4,605 -> 2.69 s,
  /// 11,324 (a 10-minute dictation) -> 6.12 s, 66,896 (the longest transcript we
  /// have recorded) -> 50.65 s. The last measurement under the old 5 s budget was
  /// 4,605 chars at 2.69 s, so the crossing lies between 4,605 and 11,324 chars;
  /// the measured long cases lost their polish and showed the failure notice. Production corroborates it: Gemini's
  /// `llm_seconds` maxes at 5.05 s against the 5 s cap — a censored distribution.
  ///
  /// A larger FIXED number is not the fix. It would make a 20-word dictation
  /// wait far longer than today before its raw text appears, degrading the
  /// common case (p50 is 8 seconds of speech) to rescue the 0.1% tail.
  ///
  /// So: `base + inputChars / 500`. Throughput measured 1,285 / 1,712 / 1,850 /
  /// 1,320 chars per second across those four long buckets, so budgeting 500
  /// chars/second leaves ~2.6x margin on the variable part alone. Headroom
  /// lands at 6x / 6x / 4.5x / 2.7x across the table above.
  ///
  /// `base` is 5 s normally — preserving today's short-dictation failure speed
  /// almost exactly (110 chars -> 5.22 s) — and 60 s when the resolved request
  /// carries a deep-thinking value, because deep mode spends a measured
  /// 42.2-42.4 s thinking BEFORE the first byte, a fixed cost rather than a
  /// per-character one. It keys off the resolved `ThinkingControl`, not the raw
  /// toggle: an `.unsupported` model sends no thinking field at all, so it must
  /// not inherit the deep base merely because the toggle is on.
  ///
  /// Capped at 180 s to match `URLSession`'s `timeoutIntervalForResource`
  /// (`LLMNetworkSession`): beyond that the transport terminates the attempt
  /// anyway, so a larger logical budget buys another long attempt rather than
  /// preserving the first response.
  ///
  /// Transport liveness is NOT reimplemented here — the shared session already
  /// provides a 60 s inter-data idle timer and the 180 s resource cap.
  /// Reads `llmProvider` / `llmModel` / `useExtendedThinking` live, exactly as
  /// the existing `maxDuration` above already reads `llmProvider` live at this
  /// same call site. Safe because `PipelineSettingsSync` deliberately does NOT
  /// mirror these three onto a live step — `.llmProvider` ("live steps are
  /// seeded per recording, so nothing to mirror here") and `.useExtendedThinking`
  /// ("Frozen per recording") are explicit no-ops there, and the values are
  /// frozen into `DictationSessionConfig` at record start. The only writers are
  /// session start and `RecoveryTextProcessor.applySettings`, neither of which
  /// runs while a `process()` is in flight.
  ///
  /// KNOWN LIMIT, recorded rather than engineered around: this is an invariant
  /// held elsewhere, not a guarantee of this function. If mirroring is ever
  /// added for these fields, the budget and the request could be computed for
  /// different settings — a deep request could inherit the 5 s fast budget.
  /// Closing that properly means giving the runner and the step one shared
  /// snapshot, which is a change to the execution boundary and not warranted
  /// for a window no current code can open.
  public func maxDuration(for context: TextProcessingContext) -> Duration {
    guard llmProvider == .gemini else { return maxDuration }
    let control = llmProvider.modelCapabilities(model: llmModel).thinkingControl
    let isDeep = useExtendedThinking && control != .unsupported
    let base = isDeep ? Self.geminiDeepBaseSeconds : Self.geminiFastBaseSeconds
    let scaled = base + Double(context.text.count) / Self.geminiCharsPerSecond
    return .seconds(min(Self.geminiMaxBudgetSeconds, scaled))
  }

  /// Fast-mode base: preserves today's 5 s short-dictation failure speed.
  private static let geminiFastBaseSeconds: Double = 5
  /// Deep-mode base: covers the measured 42.2-42.4 s of pre-first-byte thinking.
  private static let geminiDeepBaseSeconds: Double = 60
  /// Budgeted throughput, ~2.6x slower than the slowest measured rate.
  private static let geminiCharsPerSecond: Double = 500
  /// Matches `URLSession.timeoutIntervalForResource`; beyond it the transport
  /// kills the attempt regardless.
  private static let geminiMaxBudgetSeconds: Double = 180

  public init(keychainManager: KeychainManager) {
    self.keychainManager = keychainManager
    self.telemetry = .live
  }

  /// Internal-only overload (#1461) — used solely by `RecoveryTextProcessor`
  /// to construct with `.silent`. Not `public`: no external caller should be
  /// able to silence this step's telemetry, so the public API surface stays
  /// exactly what it was before this plan.
  init(keychainManager: KeychainManager, telemetry: TelemetrySeams) {
    self.keychainManager = keychainManager
    self.telemetry = telemetry
  }

  /// Test seam (round 6/7 grounded review) — `evictPreviousOllamaModel`
  /// directly constructed a real `OllamaConnector()`, making a limb-failure
  /// test's outcome depend on whether a local Ollama process happened to be
  /// running. Defaulted to the real call so production is byte-identical;
  /// tests inject a fixed `OllamaEvictOutcome`.
  typealias EvictOllamaModel = @MainActor (String) async -> OllamaEvictOutcome
  var evictOllamaModel: EvictOllamaModel = { modelName in
    await OllamaConnector().evictModel(modelName)
  }

  /// Asks Ollama to unload the named model from memory (fire-and-forget).
  ///
  /// Called by `PipelineSettingsSync` when the user swaps away from an
  /// Ollama model, so the previous model doesn't linger in VRAM and
  /// starve CoreAudio (#286 root cause, #295 mitigation). No-op if
  /// `modelName` is empty. Swallows all errors; only logs.
  ///
  /// #2061: gated on the daemon's own answer before the unload is attempted.
  /// The eviction tracker is seeded from CONFIGURATION — `ollamaModel` defaults
  /// to `qwen2.5:3b` for every install, so merely SELECTING Ollama in the
  /// provider picker armed an eviction for a model the user never installed,
  /// let alone loaded. Switching back out then fired an unload at a daemon that
  /// was never running. Measured over 90 days: 133 users hit
  /// `NSURLErrorCannotConnectToHost` and 39 hit `http_404`, against 27 users who
  /// have ever polished with Ollama at all — and that noise sat at the top of
  /// every "what is failing most" query, burying the genuine stuck-model case
  /// this eviction exists to catch.
  public func evictPreviousOllamaModel(_ modelName: String) async {
    guard !modelName.isEmpty else { return }

    // Reuses the #1305 readiness authority rather than adding a second one.
    // Probed fresh, never cached: the user can quit or start Ollama at any
    // moment.
    //
    // The gate SKIPS ONLY ON PROOF that nothing can be resident, and treats
    // every ambiguous answer as "evict". That asymmetry is the whole safety
    // argument, and it is the same default `PipelineSettingsSync` already
    // applies to an unknown model: a needless unload costs one localhost
    // request, while a skipped real one leaves a model in VRAM, which is the
    // #286 Bluetooth-audio regression.
    //
    // - `.daemonUnreachable` — nothing is listening, so no process holds
    //   weights. Proof. Skip.
    // - `.modelMissing` — the daemon answered and the model is not installed, so
    //   it cannot be loaded. Proof. Skip.
    // - `.noModelSelected` — nothing armed (already handled by the guard above).
    // - `.serverDown` — something IS listening and did not answer usefully: a
    //   non-2xx, an unparseable body, or a blown 1s deadline. NOT proof, and a
    //   busy daemon is exactly the state a large resident model produces, so
    //   this must still evict (cloud review, PR #2071).
    // - `.ready` — installed, so possibly resident. Evict.
    let readiness = await ollamaReadinessProbe(modelName)
    if Self.evictionIsProvablyUnnecessary(readiness) {
      await AppLogger.shared.log(
        "Ollama eviction skipped: model=\(modelName) reason=\(Self.evictionSkipReason(readiness))",
        level: .info, category: "Ollama")
      return
    }

    let outcome = await evictOllamaModel(modelName)
    // #1177 (Telemetry Bible Phase 8): observe a quiet eviction FAILURE — a model that
    // won't unload lingers in VRAM and has disrupted CoreAudio BT audio (#286). The
    // eviction itself stays fire-and-forget; this only reports the outcome. @MainActor
    // step → direct emit. Fire only on failure (success/skip are non-events). Not
    // reachable from crash-recovery replay (`process()` never calls this), but
    // still routed through the same `.live`/`.silent` seam for consistency.
    if outcome.result == "failed" {
      telemetry.limbFailureObserved(
        "ollama", "evict", "failed", outcome.reason, outcome.durationMs)
    }
  }

  /// Log label for a skipped eviction (#2061). A closed set over the readiness
  /// enum, exhaustive by construction so a future readiness case has to name
  /// itself here rather than silently joining an existing bucket.
  static func evictionSkipReason(_ readiness: OllamaReadiness) -> String {
    switch readiness {
    case .ready: return "ready"
    case .daemonUnreachable: return "daemon_unreachable"
    case .serverDown: return "daemon_answered_unusably"
    case .modelMissing: return "model_not_installed"
    case .noModelSelected: return "no_model_armed"
    }
  }

  /// Is skipping the unload PROVABLY safe (#2061)?
  ///
  /// True only for the two answers that establish no weights can be resident.
  /// Exhaustive with no `default`, so a new `OllamaReadiness` case has to state
  /// which side it falls on rather than silently inheriting "safe to skip" —
  /// which is the direction that costs a #286 regression.
  static func evictionIsProvablyUnnecessary(_ readiness: OllamaReadiness) -> Bool {
    switch readiness {
    case .daemonUnreachable, .modelMissing, .noModelSelected:
      return true
    case .ready, .serverDown:
      return false
    }
  }

  /// Warm the configured LLM provider for the upcoming session — parity
  /// with the old Parakeet pipeline (TP:708-713) which warmed polish
  /// while ASR was still running so the post-ASR polish step did not
  /// pay the cold-start penalty. The app-level warm at launch /
  /// foreground (`AppLifecycleCoordinator.swift:200`/256) is enough on
  /// short-idle sessions; this per-session refresh restores parity for
  /// long-idle paths. No-op when polish is disabled.
  public func preWarm() {
    guard isEnabled else { return }
    LLMNetworkSession.shared.preWarmModel(
      provider: llmProvider,
      model: llmModel,
      keychainManager: keychainManager
    )
  }

  /// Minimum word count to send to the LLM (Latin/Cyrillic/Indic/Arabic etc).
  /// Transcripts at or below this threshold are passed through verbatim — LLMs
  /// hallucinate on ultra-short input (e.g., "Yeah" → a full essay). See ew-zr4.
  private static let minWordsForPolish = 3

  /// Minimum character count for CJK/Thai/Lao scripts which don't use spaces.
  /// Japanese/Chinese word-counting treats a 31-char sentence as 2 words,
  /// which would wrongly short-circuit polish. Character-count is the correct
  /// gate for non-whitespace-segmented scripts. 10 chars ≈ a short utterance.
  private static let minCharsForCJKPolish = 10

  /// The too-short skip's return value: text untouched, AI fields nil (#1022).
  private static func bypassedContext(_ context: TextProcessingContext) -> TextProcessingContext {
    var ctx = context
    ctx.polishedText = nil
    ctx.llmProvider = nil
    ctx.llmModel = nil
    // #1914: nothing polished, so there is no completed remoteness fact to carry.
    // Cleared rather than left alone because this returns the CALLER's context,
    // and a value arriving here could otherwise ride a bypass into telemetry.
    ctx.polishRanRemote = nil
    // #1948: same reasoning for the route receipt. A stale family riding a bypass would tell
    // `EmojiRestoreStep` that a polish it never saw used the local prompt.
    ctx.promptFamily = nil
    return ctx
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    onWillProcess?()
    // #827 PR-8: snapshot the mutable provider/model at entry. process()
    // suspends at the polish await, so every read after it must come from
    // these locals or the post-await reads could tear
    // (provider/model attribution in ctx, the family label, and the two
    // telemetry helpers). Mirrors WordCorrectionStep's entry snapshot. Every
    // read below uses these locals, never `self`, so reentrancy cannot tear it.
    let provider = llmProvider
    let model = llmModel
    let extendedThinking = useExtendedThinking
    telemetry.breadcrumbStarted(
      "LLM polish started",
      [
        "provider": provider.rawValue,
        "model": model,
      ])

    // Short-circuit: ultra-short transcripts get passed through verbatim.
    // LLMs treat 1-3 word inputs as prompts to respond to, not text to clean.
    // Language-aware: CJK/Thai/Lao scripts use char-count since they don't
    // segment words with whitespace (a 31-char Japanese utterance is 1-2
    // "words" by split, which would wrongly skip polish).
    //
    // The skip is a Bypass (llm-contract): no polish output, no provider
    // stamp — `polishedText != nil` is the UI's "AI was applied" signal
    // (history badge, Enhance visibility), so the bypass must leave it nil
    // (#1022). Fields cleared explicitly so the contract holds even for a
    // caller entering with stale AI fields set.
    let lang = languageDetection?.lang ?? context.language
    let useCharCount = lang.map(LanguageTypes.isUnsegmentedScript) ?? false
    if useCharCount {
      let charCount = context.text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
      if charCount < Self.minCharsForCJKPolish {
        Task {
          await AppLogger.shared.log(
            "LLM polish skipped: transcript too short (\(charCount) chars, minimum \(Self.minCharsForCJKPolish), lang=\(lang ?? "?"))",
            level: .info, category: "LLM"
          )
        }
        let skipReason = PolishSkipReason.tooShort(provider)
        telemetry.recordPolishSkipped(
          skipReason.provider.rawValue, skipReason.telemetryTag, context.takeID)
        return Self.bypassedContext(context)
      }
    } else {
      let wordCount = context.text.split(whereSeparator: \.isWhitespace).count
      if wordCount <= Self.minWordsForPolish {
        Task {
          await AppLogger.shared.log(
            "LLM polish skipped: transcript too short (\(wordCount) words, minimum \(Self.minWordsForPolish + 1))",
            level: .info, category: "LLM"
          )
        }
        let skipReason = PolishSkipReason.tooShort(provider)
        telemetry.recordPolishSkipped(
          skipReason.provider.rawValue, skipReason.telemetryTag, context.takeID)
        return Self.bypassedContext(context)
      }
    }

    Task {
      await AppLogger.shared.log(
        "LLM polish requested: provider=\(provider.rawValue), model=\(model)",
        level: .verbose, category: "LLM"
      )
    }

    // #1305: Ollama readiness preflight — mirror of the `.egOne` gate below,
    // sitting exactly where "a polish attempt for this provider is about to
    // start" is knowable and BEFORE any polisher construction or connector
    // retry loop. Not-ready is a SURFACED SKIP (notice yes, Sentry no —
    // TextProcessingRunner owns that policy), so the user gets raw text
    // essentially instantly instead of ~4s of doomed retries (#1305 root
    // symptom). The probe uses the entry-snapshot `model`, so a mid-polish
    // settings change cannot tear it; the answer is per-attempt truth, never
    // cached across dictations.
    // #1914: the probe's `.ready` carries the daemon's own facts about THIS
    // model. Bound explicitly rather than matched with a bare `case .ready:` —
    // Swift permits ignoring an associated value, so nothing in the compiler
    // notices if this binding is dropped and every model silently falls back to
    // the tight budget again. `OllamaReadinessGateTests` is what catches that,
    // and its mutation control was run to prove it does.
    //
    // Scoped to this one attempt and never cached: `preflightReadiness`'s own
    // contract forbids reuse across dictations, because the user can sign out of
    // Ollama or swap a model at any time.
    //
    // Deliberately a NON-OPTIONAL `let` with no default. An optional plus `??
    // false` would reintroduce the exact defect this chunk removes: drop the
    // binding and every model silently falls back to the tight budget, compiling
    // cleanly. Here Swift's definite-initialization makes that a COMPILE error
    // instead — every path that reaches the polish request must have assigned
    // it, and the three not-ready paths throw before they get there.
    //
    // #1914 Chunk 7: `ollamaRemote` rides the SAME binding, for the same reason.
    // It is `Bool?` rather than `Bool` because its third state is real: a
    // non-Ollama attempt has no daemon to ask, and saying `false` there would
    // make the metric mean "local" in one place and "not Ollama" in another.
    let ollamaThinks: Bool?
    let ollamaRemote: Bool?
    if provider == .ollama {
      switch await ollamaReadinessProbe(model) {
      case .ready(let facts):
        ollamaThinks = facts.thinks
        ollamaRemote = facts.isRemote
      case .serverDown, .daemonUnreachable:
        // #2061 split these for the EVICTION path, which must know whether
        // weights can still be resident. Polish does not care why the daemon
        // failed to answer — either way there is nothing to polish with — so
        // both keep the single `providerUnreachable` sentence the user already
        // sees. Listed explicitly rather than via `default` so a future case has
        // to be decided here.
        throw LLMError.localPolishNotReady(.providerUnreachable)
      case .modelMissing:
        throw LLMError.localPolishNotReady(.modelUnavailable)
      case .noModelSelected:
        // #1914: distinct from `.modelMissing` all the way to the pill. The
        // user has no selection, so telling them to download a model would send
        // them to fix something that is not broken.
        throw LLMError.localPolishNotReady(.noModelSelected)
      }
    } else {
      // Explicit, not defaulted: a non-Ollama attempt has no daemon to ask, and
      // both values reach only the `.ollama` branches of the two policies below
      // (`outputTokenPolicy` switches on provider; `ollamaThinking` is called
      // only under `provider == .ollama`).
      //
      // `nil`, not `false`, for the same reason `ollamaRemote` is nil here: a
      // reported `false` and "nobody was asked" are different facts, and the
      // three-state on `OllamaModelFacts.thinks` only works if every producer
      // respects the distinction.
      ollamaThinks = nil
      ollamaRemote = nil
    }

    // #1271: EG-1 resolves its polisher from the live server endpoint, not
    // the keychain-shaped factory. Every unavailability here is a SILENT
    // bypass (`egOneSkipped`), never the surfaced `providerUnavailable` —
    // a local limb that is not ready must degrade to raw text quietly.
    let polisher: any TranscriptPolisher
    if provider == .egOne {
      guard let runtime = egOneRuntime else {
        throw LLMError.egOneSkipped(.notReady)
      }
      guard let endpoint = await runtime.activeEndpoint() else {
        throw LLMError.egOneSkipped(.notReady)
      }
      // Context preflight: polish whole or skip whole, never a silent
      // truncation. WORST-CASE on both sides (Codex r15+r16): input at
      // ~1 token/char (true for unsegmented CJK; a 3x overestimate for
      // Latin) plus the SAME output cap the request later sends
      // (`max(text.count, 256)`, r14) plus prompt overhead. Conservative
      // by design — it bounds polishable dictations at ~8k chars, well
      // past the product's 5-minute dictation target; anything longer
      // silently pastes raw rather than risking truncated polish.
      let outputBudget = max(context.text.count, LLMConstants.ollamaMaxTokens)
      if context.text.count + outputBudget + 256 > endpoint.contextTokens {
        throw LLMError.egOneSkipped(.inputTooLong)
      }
      polisher = makeEGOnePolisher(endpoint)
    } else if let made = makePolisher(
      provider, keychainManager, outputClassifierHolder?.classifier)
    {
      polisher = made
    } else {
      telemetry.captureProviderInitError(LLMError.providerUnavailable)
      throw LLMError.providerUnavailable
    }

    let keychainId: String? =
      switch provider {
      case .openAI: KeychainManager.openAIKeyID
      case .gemini: KeychainManager.geminiKeyID
      case .claude: KeychainManager.claudeKeyID
      default: nil
      }

    // Resolved from the ENTRY snapshot, never from `self` — this function's
    // own contract above ("every read below uses these locals") applies to the
    // thinking value too, so the request, the deadline and the telemetry all
    // describe one model. (#1770 verified that no production code mutates
    // these three on a live step: PipelineSettingsSync no-ops all of them and
    // the values are frozen per recording. The discipline is kept because
    // internal consistency should not depend on an invariant held elsewhere.)
    //
    // #1914: Ollama is the one provider whose thinking answer is OBSERVED per
    // attempt rather than looked up. `LLMModelCapabilities` is documented
    // "Static knowledge, deliberately" and keys off a model NAME, so a live
    // `/api/tags` fact has no business in it — the daemon's answer is routed
    // straight from the attempt's facts to the request instead. Every other
    // provider keeps the static resolution unchanged.
    let thinking: ResolvedThinking? =
      provider == .ollama
      ? Self.ollamaThinking(thinks: ollamaThinks)
      : Self.resolveThinking(
        control: provider.modelCapabilities(model: model).thinkingControl,
        useExtendedThinking: extendedThinking
      )
    let outputTokens = Self.outputTokenPolicy(
      provider: provider, model: model, textCount: context.text.count,
      thinks: ollamaThinks)

    // Prefer live LID but fall back to the context's persisted language so
    // standalone callers that clear `languageDetection` (crash-recovery's
    // `RecoveryTextProcessor`, #1063) still hit the Apple Intelligence preflight
    // gate and language-aware prompt. LOAD-BEARING — do not remove this fallback
    // (the only previous caller was the deleted re-polish service, but recovery
    // relies on the same path).
    let detectedLanguage = languageDetection?.lang ?? context.language

    let config = LLMProviderConfig(
      model: model,
      apiKeyKeychainId: keychainId,
      outputTokens: outputTokens,
      temperature: 0,
      thinking: thinking,
      detectedLanguage: detectedLanguage
    )

    // #1710 request-shape receipt for Live UAT: policy only, never content.
    // #1770 makes the DIALECT visible here — which wire key we chose, not just
    // its value — because sending the wrong dialect is the defect this receipt
    // now has to be able to prove absent.
    let thinkingReceipt = Self.thinkingReceipt(thinking)
    Task {
      await AppLogger.shared.log(
        "LLM request budget: provider=\(provider.rawValue), model=\(model), "
          + "output_tokens=\(outputTokens), thinking=\(thinkingReceipt)",
        level: .info, category: "LLM"
      )
    }

    // Apple Intelligence: own prompt path (unchanged, out of scope for planner).
    if provider == .appleIntelligence {
      let enriched = appleIntelligenceInstructions(polishInstructions)
      var resolvedInstructions = enriched
      var userText = context.text
      if enriched.systemPrompt.contains("${transcript}") {
        resolvedInstructions = PolishInstructions(
          systemPrompt: enriched.systemPrompt.replacingOccurrences(
            of: "${transcript}", with: context.text
          )
        )
        userText = ""
      }
      // Let `LLMError.unsupportedInputLanguage` and
      // `LLMError.outputLanguageDrift` propagate. The live dictation
      // path (TextProcessingRunner) treats them as silent skips; standalone
      // callers (crash-recovery's RecoveryTextProcessor, #1063) catch and fall
      // back to raw. Either way the transcript is never mislabeled AI-polished.
      let llmStart = CFAbsoluteTimeGetCurrent()
      let result: LLMResult
      do {
        result = try await polisher.polish(
          text: userText,
          instructions: resolvedInstructions,
          config: config,
          onToken: onToken
        )
      } catch let afmErr as AFMPolishError {
        // #1448/#1461: some AFM errors classified silent by TextProcessingRunner
        // (outputLanguageDrift always; frameworkUnavailable when it reaches this
        // wrapped path via AppleIntelligenceConnector.makeSession's defensive
        // re-check) were STILL raising a live alerting Sentry event here,
        // unconditionally, contradicting their own "silent" classification. Same
        // check the runner uses (PolishSkipReason.init?(silentLLMError:)) — one
        // authority, two readers — so this cannot drift out of agreement with the
        // runner's classification the way a second hardcoded special case would.
        if let llmError = afmErr.underlying as? LLMError,
          PolishSkipReason(silentLLMError: llmError) != nil
        {
          throw llmError
        }
        telemetry.captureAFMPolishError(afmErr.underlying)
        throw afmErr.underlying
      }
      let llmEnd = CFAbsoluteTimeGetCurrent()
      logPolishCompletion(
        result: result, duration: llmEnd - llmStart, provider: provider, model: model)
      let validatedText = validatePolishOutput(
        polished: result.polishedText, original: context.text, mode: .message,
        provider: provider, model: model
      )
      var ctx = context
      ctx.polishedText = validatedText
      ctx.llmProvider = provider.rawValue
      ctx.llmModel = model
      ctx.polishMetadata = result.polishMetadata
      ctx.pipelineFellBackToRaw =
        (result.polishMetadata?.filterFellBackToRaw ?? false) || (validatedText == context.text)
      // #1050: honest disaggregation of the boolean above. Invariant:
      // (reason != nil) == pipelineFellBackToRaw (the existing line is left
      // untouched — `pipelineFellBackToRaw` also feeds `itnFloorDelivered`).
      ctx.polishFallbackReason = Self.polishFallbackReason(
        filterFellBackToRaw: result.polishMetadata?.filterFellBackToRaw ?? false,
        postFilterOutput: result.polishedText,
        validatedText: validatedText,
        originalText: context.text)
      return ctx
    }

    // All other providers: PromptPlanner path.

    // Multilingual v1 (W3): snapshot the active vocabulary at construction
    // time so the planner/builders see a stable list even if the user edits
    // custom words mid-polish. Migration default: all entries tagged global.
    let vocabularySnapshot = PromptVocabulary.fromLegacy(polishVocabulary.terms)

    let input = PromptBuildInput(
      transcript: context.text,
      provider: provider,
      modelID: model,
      appName: context.targetAppName,
      language: context.language,
      polishVocabulary: polishVocabulary,
      focusSnapshot: nil,  // PR 3
      customVocabulary: vocabularySnapshot,
      languageDetection: languageDetection,
      backend: backend,
      // #1948: the daemon-reported execution location decides which Ollama prompt is sent.
      // Already captured for this attempt at the readiness probe above; nil for every
      // non-Ollama provider, which routes nothing.
      ollamaIsRemote: ollamaRemote
    )
    let plan = promptPlanner.plan(input: input)

    // #1948 content-free routing receipt. `prompt_family` otherwise exists only inside the
    // Sentry breadcrumb below, which Live UAT cannot read — so without this line the UAT
    // verdict for "did this model get the right prompt" is unobservable. Policy and sizes
    // only, never transcript or prompt content.
    let systemChars =
      plan.envelope.messages.first(where: { $0.role == .system })?.content.count ?? 0
    Task {
      await AppLogger.shared.log(
        "LLM prompt route: provider=\(provider.rawValue), model=\(model), "
          + "prompt_family=\(plan.family.rawValue), system_chars=\(systemChars)",
        level: .info, category: "LLM"
      )
    }

    let llmStart = CFAbsoluteTimeGetCurrent()
    let result = try await polisher.polish(
      envelope: plan.envelope,
      config: config,
      onToken: onToken
    )
    let llmEnd = CFAbsoluteTimeGetCurrent()

    logPolishCompletion(
      result: result, duration: llmEnd - llmStart,
      provider: provider, model: model,
      extraData: [
        "polish_mode": plan.mode.rawValue,
        // #1948: read the family the planner actually used. This used to re-derive it from
        // (provider, model), which could report a family that was never sent.
        "prompt_family": plan.family.rawValue,
      ])

    let validatedText = validatePolishOutput(
      polished: result.polishedText,
      original: context.text,
      mode: plan.mode,
      provider: provider, model: model
    )

    var ctx = context
    ctx.polishedText = validatedText
    ctx.llmProvider = provider.rawValue
    ctx.llmModel = model
    ctx.polishMetadata = result.polishMetadata
    ctx.pipelineFellBackToRaw =
      (result.polishMetadata?.filterFellBackToRaw ?? false) || (validatedText == context.text)
    // #1050: see the AFM path above. Cloud providers leave `polishMetadata` nil,
    // so this reason is nil-degraded downstream in `KernelFinalizationWiring`
    // exactly like `pipelineFellBackToRaw` — kept here only for path symmetry.
    ctx.polishFallbackReason = Self.polishFallbackReason(
      filterFellBackToRaw: result.polishMetadata?.filterFellBackToRaw ?? false,
      postFilterOutput: result.polishedText,
      validatedText: validatedText,
      originalText: context.text)
    // #1914: the only positive stamp site. It sits after `polisher.polish`
    // returned and after `validatePolishOutput`. Every earlier exit leaves the
    // field nil.
    //
    // Finalization owns one later correction: if empty-output recovery clears
    // `polishedText` and reclassifies the result as skipped, it clears this field
    // too. Apple Intelligence cannot reach this stamp because its branch returns
    // above.
    ctx.polishRanRemote = ollamaRemote
    // #1948: same stamp site, same reasoning — set only after a real polish returned.
    ctx.promptFamily = plan.family
    return ctx
  }

  // MARK: - Fallback Reason (#1050)

  /// Disaggregate the conflated `pipelineFellBackToRaw` boolean into an honest
  /// reason for telemetry. Pure + static so it is directly unit-testable
  /// (mirrors the `KernelFinalizationWiring.itnFloorDelivered` precedent).
  ///
  /// - nil → polish CHANGED the text (NOT a fallback; `pipelineFellBackToRaw == false`).
  /// - `guard_discard` → the connector `EnviousOutputFilter` tripped (genuine
  ///   misbehavior caught; `polishMetadata.filterTripped` names which guard).
  /// - `no_change` → the model returned the input unchanged (benign no-op — the
  ///   ~75%-of-fallbacks majority that inflated the headline rate).
  /// - `validator_discard` → the model differed but `validatePolishOutput`
  ///   substituted the original (genuine catch the `filter_tripped` signal cannot see).
  ///
  /// Invariant (locked by a parametric test): `(reason != nil)` equals the real
  /// `filterFellBackToRaw || (validatedText == originalText)`, so this NEVER
  /// changes `pipelineFellBackToRaw` — it only labels it.
  ///
  /// `postFilterOutput` is `result.polishedText`: post-connector-filter,
  /// post-leading-marker-repair, PRE-`validatePolishOutput` (not the raw model
  /// output). On a filter trip it equals the input, so `guard_discard` MUST be
  /// checked first.
  static func polishFallbackReason(
    filterFellBackToRaw: Bool,
    postFilterOutput: String,
    validatedText: String,
    originalText: String
  ) -> String? {
    if filterFellBackToRaw { return "guard_discard" }
    guard validatedText == originalText else { return nil }
    return postFilterOutput == originalText ? "no_change" : "validator_discard"
  }

  // MARK: - Output Validation

  /// Validate LLM polish output with mode-aware thresholds.
  /// Falls back to original text when the output looks like a hallucination,
  /// content drop, or question-to-answer conversion.
  func validatePolishOutput(
    polished: String, original: String, mode: PolishMode,
    provider: LLMProvider, model: String
  ) -> String {
    guard !original.isEmpty else { return polished }

    // Mode-aware thresholds (from plan Appendix C).
    //
    // #1948: ONLY `.message` is reachable in production. `DefaultPromptPlanner` forces it for
    // every family now that `TranscriptAnalyzer` is deleted, and the Apple Intelligence path
    // passes `.message` literally (`:648`), so `.inline` / `.structured` / `.edit` are inert.
    // They are kept rather than deleted because `PolishMode` is a public Core type and the
    // switch must stay exhaustive — not because a caller still selects them. The cost of
    // moving the former `.structured` inputs onto `.message` thresholds was measured before
    // the change rather than assumed: +11 extra fallbacks of 1,690 on `qwen2.5:3b`, +6 on
    // `llama3.2`. If you are here to tune a threshold, tune `.message`; the others describe
    // transcript shapes nothing classifies any more.
    let expansionThreshold: Int
    let contentDropFraction: (numerator: Int, denominator: Int)
    switch mode {
    case .inline:
      expansionThreshold = max(original.count * 3, 150)
      contentDropFraction = (2, 5)  // 40% retention minimum
    case .message:
      expansionThreshold = max(original.count * 3, 200)
      contentDropFraction = (2, 5)
    case .structured:
      expansionThreshold = max(original.count * 4, 300)
      contentDropFraction = (1, 3)  // 33% retention minimum (more aggressive cleanup ok)
    case .edit:
      expansionThreshold = max(original.count * 4, 300)
      contentDropFraction = (1, 3)
    }

    // Guard 1: Expansion hallucination
    if polished.count > expansionThreshold {
      Task {
        await AppLogger.shared.log(
          "LLM polish validator: expansion \(polished.count)/\(original.count) chars "
            + "exceeds \(expansionThreshold) (mode=\(mode.rawValue)) — falling back "
            + "(provider=\(provider.rawValue), model=\(model))",
          level: .info, category: "LLM"
        )
      }
      return original
    }

    // Guard 2: Content drop
    let originalWords = original.split(whereSeparator: \.isWhitespace)
    let polishedWords = polished.split(whereSeparator: \.isWhitespace)
    let dropThreshold =
      (originalWords.count * contentDropFraction.numerator + contentDropFraction.denominator - 1)
      / contentDropFraction.denominator
    if originalWords.count >= 10 && polishedWords.count < dropThreshold {
      Task {
        await AppLogger.shared.log(
          "LLM polish validator: content drop \(polishedWords.count)/\(originalWords.count) words "
            + "(mode=\(mode.rawValue)) — falling back (provider=\(provider.rawValue), model=\(model))",
          level: .info, category: "LLM"
        )
      }
      return original
    }

    // Guard 3: Question-to-answer conversion (unchanged across modes)
    if looksLikeQuestion(original) && !looksLikeQuestion(polished) {
      Task {
        await AppLogger.shared.log(
          "LLM polish validator: question-to-answer conversion detected — "
            + "falling back (provider=\(provider.rawValue), model=\(model))",
          level: .info, category: "LLM"
        )
      }
      return original
    }

    return polished
  }

  /// Conservative question detection using strong signals only.
  /// Returns true if the text contains `?` or starts with an interrogative pattern.
  /// Leading fillers and common preambles are stripped before checking.
  private func looksLikeQuestion(_ text: String) -> Bool {
    if text.contains("?") { return true }

    // Strip leading fillers to find the real sentence start.
    let fillers: Set<String> = ["um", "uh", "so", "like", "well", "okay", "ok"]
    var words = text.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    while let first = words.first,
      fillers.contains(first.trimmingCharacters(in: .punctuationCharacters))
    {
      words.removeFirst()
    }
    guard let firstWord = words.first else { return false }

    // Modal/auxiliary verbs at sentence start are always interrogative.
    let auxiliaryStarts: Set<String> = [
      "should", "can", "do", "does", "did", "is", "are", "could", "would",
      "has", "have", "will",
    ]
    if auxiliaryStarts.contains(firstWord) { return true }

    // Wh-words need a following auxiliary to be a question.
    // "How do we..." = question. "How we handle this..." = declarative.
    let whWords: Set<String> = ["how", "what", "where", "when", "who", "why"]
    if whWords.contains(firstWord) {
      let secondWord = words.count > 1 ? words[1] : ""
      let followedByAuxiliary =
        auxiliaryStarts.contains(secondWord)
        || ["many", "much", "long", "often"].contains(secondWord)  // "how many", "how long"
      if followedByAuxiliary { return true }
    }

    // Check for common indirect question preambles.
    let joined = words.prefix(5).joined(separator: " ")
    let indirectPreambles = [
      "i was wondering if",
      "i'm wondering if",
      "wondering if",
      "whether we should",
      "do you know if",
      "is there a",
      "are we",
    ]
    return indirectPreambles.contains { joined.hasPrefix($0) }
  }

  // MARK: - Apple Intelligence Prompt (Compressed Enrichment)

  /// Apple Intelligence uses a simplified on-device prompt (set in makeSession()).
  /// We append compressed enrichment (ASR awareness, tone preservation); full
  /// cloud-style enrichment is too verbose for the small on-device model.
  ///
  /// Custom words are deliberately NOT injected here (#1084). The deterministic
  /// `WordCorrector` lane runs BEFORE polish and already applies the user's terms,
  /// and an eval (ci151 tier-bench, reps=3) showed the on-device vocab block was
  /// net-negative — it distracted the small model into dropping sentence openers
  /// and capitalization for no reliable gain. The cloud planner path (see
  /// `process()` building `PromptBuildInput.polishVocabulary`) still injects vocab;
  /// this drop is on-device only. `internal` (not `private`) so the regression test
  /// can assert the assembled prompt stays vocab-free.
  func appleIntelligenceInstructions(
    _ base: PolishInstructions
  ) -> PolishInstructions {
    var systemPrompt = base.systemPrompt

    // Compressed enrichment for on-device model: key behavioral rules only.
    // Targets eval failures: false starts (#17), formality downgrade (#19).
    systemPrompt +=
      "\nThis is speech-to-text output. Remove false starts. "
      + "Preserve the speaker's tone and formality level. If unsure about a correction, leave unchanged."

    return PolishInstructions(systemPrompt: systemPrompt)
  }

  // MARK: - Telemetry

  private func logPolishCompletion(
    result: LLMResult, duration: Double,
    provider: LLMProvider, model: String,
    extraData: [String: String] = [:]
  ) {
    var data: [String: String] = [
      "provider": provider.rawValue,
      "model": model,
      "duration_s": String(format: "%.3f", duration),
      "char_count": String(result.polishedText.count),
    ]
    data.merge(extraData) { _, new in new }

    telemetry.breadcrumbCompleted("LLM polish completed", data)
    Task {
      await AppLogger.shared.log(
        "LLM polish complete: \(result.polishedText.count) chars in \(String(format: "%.3f", duration))s "
          + "(provider=\(provider.rawValue), model=\(model))",
        level: .info, category: "PipelineTiming"
      )
    }
  }

  /// #1710 output-token policy: cloud providers that permit it send NO
  /// client ceiling (`.providerDefault`) — the provider's own per-model
  /// maximum applies, so a stale client cap can never truncate a healthy
  /// polish. Local engines and Claude keep explicit caps. Static and pure
  /// for fixture testing.
  nonisolated static func outputTokenPolicy(
    provider: LLMProvider, model: String, textCount: Int, thinks: Bool?
  ) -> OutputTokenPolicy {
    switch provider {
    case .ollama:
      // Estimate tokens (~3 chars per token for English), add headroom.
      // For 921-char input: 921/3 + 100 = 407 tokens (~2x actual output of ~195).
      // The pipeline-level timeout (15s) caps runaway generation.
      //
      // #1914: `thinks` is the daemon's OWN answer for this model, taken from
      // the attempt's `/api/tags` facts. It replaces a hand-authored list of
      // four family names, which was a prediction about models other people
      // install and mis-budgeted every thinking model outside it. The model
      // NAME no longer affects this decision at all.
      //
      // A thinking model emits reasoning into `message.thinking`, which still
      // counts against `num_predict` (#272), so it needs the larger floor.
      // Measured 2026-08-01: at deep thinking a 256 cap returned zero content
      // with `done_reason=length`; at 2048 the same request completed. Shallow
      // thinking fits the tight cap comfortably, which is why the first attempt
      // to reproduce that starvation failed — the depth is load-bearing.
      //
      // Non-thinking models keep the tight 256 floor so a rambly generation
      // can't outrun the 15s pipeline timeout. `done_reason=stop` ends
      // generation early for short transcripts.
      //
      // Note the floor only binds on SHORT dictations: above ~5,844 characters
      // `textCount / 3 + 100` already exceeds 2048 and dominates.
      // ONLY a REPORTED not-thinking earns the tight floor. `nil` means the
      // daemon did not report capabilities, and that case takes the larger
      // floor so it reproduces pre-#1914 `main` for the four families the
      // retired prefix list covered, instead of silently downgrading them
      // (PR #1949 cloud review). See `OllamaModelFacts.thinks`.
      let floor =
        thinks == false
        ? LLMConstants.ollamaMaxTokens
        : LLMConstants.ollamaThinkingMaxTokens
      return .capped(max(textCount / 3 + 100, floor))
    case .egOne:
      // #1271: character-count cap, CJK-safe shape (Codex r14) — the
      // Ollama-style `count/3` estimate assumes spaced Latin text and
      // under-budgets unsegmented scripts (a 3,000-char Japanese dictation
      // needs ~3,000 output tokens, not ~1,100), letting llama-server stop
      // at the cap and paste a TRUNCATED polish. Latin gets ~4x headroom;
      // the tight 256 floor stays (fixed-prompt instruct tune, no thinking
      // tokens) and the 15 s budget bounds wall-clock.
      return .capped(max(textCount, LLMConstants.ollamaMaxTokens))
    case .claude:
      // The Anthropic API requires `max_tokens`; fixed generous value.
      return .capped(LLMConstants.claudeMaxOutputTokens)
    case .openAI, .gemini, .appleIntelligence, .none:
      // Apple Intelligence ignores the field (computes its own budget).
      return .providerDefault
    }
  }

  /// Shape-only receipt of the resolved thinking value for the debug log
  /// (#1770). Names the dialect as well as the value, since sending the wrong
  /// KEY is the failure this line exists to make visible. No user content.
  private static func thinkingReceipt(_ thinking: ResolvedThinking?) -> String {
    switch thinking {
    case .none: return "none"
    case .budget(let v): return "budget=\(v)"
    case .level(let v): return "level=\(v)"
    case .effort(let v): return "effort=\(v)"
    }
  }

  /// Resolve the thinking value for this request from the per-model capability
  /// authority and the user's toggle (#1770).
  ///
  /// This function knows NO model ids. Providers disagree on both the wire key
  /// and the legal values per model — Gemini 2.5 wants an integer budget,
  /// Gemini 3 wants a string level and rejects budget 0 — and encoding that
  /// here is what shipped `thinkingBudget: 0` to models that refuse it. The
  /// dialect and its fast/deep values live together in
  /// `LLMModelCapabilities.thinkingControl`; this only picks which of the two.
  ///
  /// Static and fed from `process()`'s entry snapshot, never from `self`, so a
  /// concurrent settings change cannot tear it away from the model the rest of
  /// the request was built for.
  /// #1914: Ollama's thinking value, resolved from the attempt's observed facts.
  ///
  /// A thinking model gets an explicit `"low"`, never an omitted field and never
  /// a boolean. Omission means the model's DEFAULT depth, which is what produced
  /// the empty output in ENVIOUSWISPR-4M; `"low"` addresses the cause while the
  /// enlarged budget accommodates what remains. Measured 2026-08-01: `"low"` was
  /// ~3x faster than `"high"` at identical output length.
  ///
  /// `think: false` is FORBIDDEN and this is confirmed on three models —
  /// `gpt-oss:120b-cloud` and `gemma4:latest` both ignored it and emitted
  /// reasoning anyway, while `nemotron-3-super:cloud` honoured it. A value two of
  /// three models silently ignore cannot be a control, so a non-thinking model
  /// sends no field at all rather than an explicit false.
  ///
  /// Three-state. Readiness always resolves before a polish attempt, so a
  /// missing ANSWER is impossible here — but a daemon that never reported
  /// `capabilities` leaves the FACT unknown, and `nil` says so.
  ///
  /// Only a reported `true` sends a thinking level. Unknown sends no `think`
  /// key, exactly as pre-#1914 `main` did for every model, so a daemon without
  /// the undocumented field cannot receive a dialect it may not understand.
  private static func ollamaThinking(thinks: Bool?) -> ResolvedThinking? {
    thinks == true ? .level("low") : nil
  }

  private static func resolveThinking(
    control: LLMModelCapabilities.ThinkingControl,
    useExtendedThinking: Bool
  ) -> ResolvedThinking? {
    switch control {
    case .unsupported: return nil
    case .budget(let fast, let deep): return .budget(useExtendedThinking ? deep : fast)
    case .level(let fast, let deep): return .level(useExtendedThinking ? deep : fast)
    case .effort(let fast, let deep): return .effort(useExtendedThinking ? deep : fast)
    }
  }
}
