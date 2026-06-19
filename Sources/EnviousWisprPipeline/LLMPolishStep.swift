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
  /// (e.g., `TranscriptPolishService`) that do not know the original ASR
  /// engine; the planner preserves legacy passthrough in that case.
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
    case .ollama: OllamaConnector()
    // #832/#913 PR8: the on-device output-safety classifier runs ONLY on Apple
    // Intelligence output (the path where AFM can compose artifacts). Injected
    // via init — fail-open when nil (not yet prewarmed / load failed).
    case .appleIntelligence: AppleIntelligenceConnector(classifier: classifier)
    case .none: nil
    }
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

  public var isEnabled: Bool {
    llmProvider != .none
  }

  /// Provider-aware timeout budget. Cloud providers respond in <2s so 5s is generous.
  /// Local models (Ollama 12B) generate ~18 tok/s and need 10-15s for long dictations.
  /// Apple Intelligence runs on-device with variable latency depending on model size.
  public var maxDuration: Duration {
    switch llmProvider {
    case .ollama: return .seconds(15)
    case .appleIntelligence: return .seconds(10)
    case .openAI, .gemini, .none: return .seconds(5)
    }
  }

  public init(keychainManager: KeychainManager) {
    self.keychainManager = keychainManager
  }

  /// Asks Ollama to unload the named model from memory (fire-and-forget).
  ///
  /// Called by `PipelineSettingsSync` when the user swaps away from an
  /// Ollama model, so the previous model doesn't linger in VRAM and
  /// starve CoreAudio (#286 root cause, #295 mitigation). No-op if
  /// `modelName` is empty. Swallows all errors; only logs.
  public func evictPreviousOllamaModel(_ modelName: String) async {
    guard !modelName.isEmpty else { return }
    await OllamaConnector().evictModel(modelName)
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
    return ctx
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    onWillProcess?()
    // #827 PR-8: snapshot the mutable provider/model at entry. process()
    // suspends at the polish await; a concurrent PipelineSettingsSync mutation
    // on the shared re-polish step would otherwise tear the post-await reads
    // (provider/model attribution in ctx, the family label, and the two
    // telemetry helpers). Mirrors WordCorrectionStep's entry snapshot. Every
    // read below uses these locals, never `self`, so reentrancy cannot tear it.
    let provider = llmProvider
    let model = llmModel
    SentryBreadcrumb.add(
      stage: "polish", message: "LLM polish started",
      data: [
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
        return Self.bypassedContext(context)
      }
    }

    Task {
      await AppLogger.shared.log(
        "LLM polish requested: provider=\(provider.rawValue), model=\(model)",
        level: .verbose, category: "LLM"
      )
    }

    guard let polisher = makePolisher(provider, keychainManager, outputClassifierHolder?.classifier)
    else {
      SentryBreadcrumb.captureError(
        LLMError.providerUnavailable, category: .providerInitFailed, stage: "polish")
      throw LLMError.providerUnavailable
    }

    let keychainId: String? =
      switch provider {
      case .openAI: KeychainManager.openAIKeyID
      case .gemini: KeychainManager.geminiKeyID
      default: nil
      }

    let (thinkingBudget, reasoningEffort) = resolveThinkingConfig()
    let maxTokens: Int = {
      if provider == .ollama {
        // Estimate tokens (~3 chars per token for English), add headroom.
        // For 921-char input: 921/3 + 100 = 407 tokens (~2x actual output of ~195).
        // The pipeline-level timeout (15s) caps runaway generation.
        //
        // Only thinking-capable families (Gemma4, qwen3, deepseek-r1,
        // gpt-oss) get the larger 2048-token floor — they emit reasoning
        // into `message.thinking` separately from `message.content`, and
        // that reasoning still counts against `num_predict` (#272). All
        // other Ollama models (weak or not) keep the tight 256 floor so
        // a rambly generation can't outrun the 15s pipeline timeout.
        // `done_reason=stop` ends generation early for short transcripts.
        let floor =
          OllamaSetupService.isThinkingCapableModel(model)
          ? LLMConstants.ollamaThinkingMaxTokens
          : LLMConstants.ollamaMaxTokens
        return max(context.text.count / 3 + 100, floor)
      }
      // OpenAI reasoning models include reasoning in max_completion_tokens — keep generous.
      if reasoningEffort != nil { return LLMConstants.defaultMaxTokens }
      // Character-based cap: ~1 token per 4 chars, so charCount ≈ 4× token estimate.
      // Using charCount directly as token cap gives ~4x headroom. Safe for CJK too.
      return max(context.text.count, LLMConstants.polishMaxTokensFloor)
    }()

    // Prefer live LID but fall back to the context's persisted language
    // so saved-transcript re-polish paths (e.g. TranscriptPolishService
    // which clears languageDetection) still hit the Apple Intelligence
    // preflight gate and language-aware prompt.
    let detectedLanguage = languageDetection?.lang ?? context.language

    let config = LLMProviderConfig(
      model: model,
      apiKeyKeychainId: keychainId,
      maxTokens: maxTokens,
      temperature: 0,
      thinkingBudget: thinkingBudget,
      reasoningEffort: reasoningEffort,
      detectedLanguage: detectedLanguage
    )

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
      // path (TextProcessingRunner) treats them as silent skips. The
      // saved-transcript re-polish path (TranscriptPolishService)
      // surfaces them to the user so they can retry with another
      // provider instead of the transcript being mislabeled AI-polished.
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
        SentryBreadcrumb.captureAFMPolishError(afmErr.underlying)
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
      backend: backend
    )
    let plan = promptPlanner.plan(input: input)

    let llmStart = CFAbsoluteTimeGetCurrent()
    let result = try await polisher.polish(
      envelope: plan.envelope,
      config: config,
      onToken: onToken
    )
    let llmEnd = CFAbsoluteTimeGetCurrent()

    let family = DefaultPromptPlanner.family(for: provider, modelID: model)
    logPolishCompletion(
      result: result, duration: llmEnd - llmStart,
      provider: provider, model: model,
      extraData: [
        "polish_mode": plan.mode.rawValue,
        "prompt_family": family.rawValue,
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

    // Mode-aware thresholds (from plan Appendix C)
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

    SentryBreadcrumb.add(stage: "polish", message: "LLM polish completed", data: data)
    Task {
      await AppLogger.shared.log(
        "LLM polish complete: \(result.polishedText.count) chars in \(String(format: "%.3f", duration))s "
          + "(provider=\(provider.rawValue), model=\(model))",
        level: .info, category: "PipelineTiming"
      )
    }
  }

  /// Resolve thinking/reasoning config based on provider, model, and user toggle.
  private func resolveThinkingConfig() -> (thinkingBudget: Int?, reasoningEffort: String?) {
    guard llmProvider.supportsReasoning(model: llmModel) else { return (nil, nil) }
    switch llmProvider {
    case .gemini:
      return (useExtendedThinking ? LLMConstants.defaultThinkingBudget : 0, nil)
    case .openAI:
      return (nil, useExtendedThinking ? "medium" : "low")
    case .ollama, .appleIntelligence, .none:
      return (nil, nil)
    }
  }
}
