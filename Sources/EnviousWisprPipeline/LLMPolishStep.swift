import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Polishes transcribed text using an LLM provider.
@MainActor
public final class LLMPolishStep: TextProcessingStep, CustomWordsConsumer {
  public let name = "LLM Polish"

  /// LLM polish failures are user-visible: surface them to `polishError` so
  /// the runner shows the "AI polish failed" banner. All other steps inherit
  /// the default `.swallow` from the protocol extension.
  internal var errorSurfacePolicy: ErrorSurfacePolicy { .surface }

  public var llmProvider: LLMProvider = .none
  public var llmModel: String = LLMProvider.defaultModel(for: .openAI)
  public var polishInstructions: PolishInstructions = .default
  public var useExtendedThinking: Bool = false
  public var customWords: [CustomWord] = []

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

  /// Minimum word count to send to the LLM (Latin/Cyrillic/Indic/Arabic etc).
  /// Transcripts at or below this threshold are passed through verbatim — LLMs
  /// hallucinate on ultra-short input (e.g., "Yeah" → a full essay). See ew-zr4.
  private static let minWordsForPolish = 3

  /// Minimum character count for CJK/Thai/Lao scripts which don't use spaces.
  /// Japanese/Chinese word-counting treats a 31-char sentence as 2 words,
  /// which would wrongly short-circuit polish. Character-count is the correct
  /// gate for non-whitespace-segmented scripts. 10 chars ≈ a short utterance.
  private static let minCharsForCJKPolish = 10

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    onWillProcess?()
    SentryBreadcrumb.add(
      stage: "polish", message: "LLM polish started",
      data: [
        "provider": llmProvider.rawValue,
        "model": llmModel,
      ])

    // Short-circuit: ultra-short transcripts get passed through verbatim.
    // LLMs treat 1-3 word inputs as prompts to respond to, not text to clean.
    // Language-aware: CJK/Thai/Lao scripts use char-count since they don't
    // segment words with whitespace (a 31-char Japanese utterance is 1-2
    // "words" by split, which would wrongly skip polish).
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
        var ctx = context
        ctx.polishedText = context.text
        return ctx
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
        var ctx = context
        ctx.polishedText = context.text
        return ctx
      }
    }

    Task {
      await AppLogger.shared.log(
        "LLM polish requested: provider=\(llmProvider.rawValue), model=\(llmModel)",
        level: .verbose, category: "LLM"
      )
    }

    let polisher: any TranscriptPolisher =
      switch llmProvider {
      case .openAI: OpenAIConnector(keychainManager: keychainManager)
      case .gemini: GeminiConnector(keychainManager: keychainManager)
      case .ollama: OllamaConnector()
      case .appleIntelligence: AppleIntelligenceConnector()
      case .none:
        SentryBreadcrumb.captureError(
          LLMError.providerUnavailable, category: .providerInitFailed, stage: "polish")
        throw LLMError.providerUnavailable
      }

    let keychainId: String? =
      switch llmProvider {
      case .openAI: KeychainManager.openAIKeyID
      case .gemini: KeychainManager.geminiKeyID
      default: nil
      }

    let (thinkingBudget, reasoningEffort) = resolveThinkingConfig()
    let maxTokens: Int = {
      if llmProvider == .ollama {
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
          OllamaSetupService.isThinkingCapableModel(llmModel)
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
      model: llmModel,
      apiKeyKeychainId: keychainId,
      maxTokens: maxTokens,
      temperature: 0,
      thinkingBudget: thinkingBudget,
      reasoningEffort: reasoningEffort,
      detectedLanguage: detectedLanguage
    )

    // Apple Intelligence: own prompt path (unchanged, out of scope for planner).
    if llmProvider == .appleIntelligence {
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
        SentryBreadcrumb.setPolishMode(
          routerMode: afmErr.routerMode, routerBasis: afmErr.routerBasis)
        throw afmErr.underlying
      }
      let llmEnd = CFAbsoluteTimeGetCurrent()
      logPolishCompletion(result: result, duration: llmEnd - llmStart)
      let validatedText = validatePolishOutput(
        polished: result.polishedText, original: context.text, mode: .message
      )
      var ctx = context
      ctx.polishedText = validatedText
      ctx.llmProvider = llmProvider.rawValue
      ctx.llmModel = llmModel
      ctx.polishMetadata = result.polishMetadata
      ctx.pipelineFellBackToRaw =
        (result.polishMetadata?.filterFellBackToRaw ?? false) || (validatedText == context.text)
      return ctx
    }

    // All other providers: PromptPlanner path.

    // Multilingual v1 (W3): snapshot the active vocabulary at construction
    // time so the planner/builders see a stable list even if the user edits
    // custom words mid-polish. Migration default: all entries tagged global.
    let vocabularySnapshot = PromptVocabulary.fromLegacy(customWords)

    let input = PromptBuildInput(
      transcript: context.text,
      provider: llmProvider,
      modelID: llmModel,
      appName: context.targetAppName,
      language: context.language,
      customWords: customWords,
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

    let family = DefaultPromptPlanner.family(for: llmProvider, modelID: llmModel)
    logPolishCompletion(
      result: result, duration: llmEnd - llmStart,
      extraData: [
        "polish_mode": plan.mode.rawValue,
        "prompt_family": family.rawValue,
      ])

    let validatedText = validatePolishOutput(
      polished: result.polishedText,
      original: context.text,
      mode: plan.mode
    )

    var ctx = context
    ctx.polishedText = validatedText
    ctx.llmProvider = llmProvider.rawValue
    ctx.llmModel = llmModel
    ctx.polishMetadata = result.polishMetadata
    ctx.pipelineFellBackToRaw =
      (result.polishMetadata?.filterFellBackToRaw ?? false) || (validatedText == context.text)
    return ctx
  }

  // MARK: - Output Validation

  /// Validate LLM polish output with mode-aware thresholds.
  /// Falls back to original text when the output looks like a hallucination,
  /// content drop, or question-to-answer conversion.
  func validatePolishOutput(polished: String, original: String, mode: PolishMode) -> String {
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
            + "(provider=\(llmProvider.rawValue), model=\(llmModel))",
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
            + "(mode=\(mode.rawValue)) — falling back (provider=\(llmProvider.rawValue), model=\(llmModel))",
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
            + "falling back (provider=\(llmProvider.rawValue), model=\(llmModel))",
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

  // MARK: - Apple Intelligence Prompt (Compressed Enrichment + Custom Vocab)

  /// Apple Intelligence uses a simplified on-device prompt (set in makeSession()).
  /// We append compressed enrichment (ASR awareness, tone preservation) and custom
  /// vocabulary. Full cloud-style enrichment is too verbose for the small on-device model.
  private func appleIntelligenceInstructions(
    _ base: PolishInstructions
  ) -> PolishInstructions {
    var systemPrompt = base.systemPrompt

    // Compressed enrichment for on-device model: key behavioral rules only.
    // Targets eval failures: false starts (#17), formality downgrade (#19).
    systemPrompt +=
      "\nThis is speech-to-text output. Remove false starts. "
      + "Preserve the speaker's tone and formality level. If unsure about a correction, leave unchanged."

    if !customWords.isEmpty {
      if let vocab = CustomVocabularyFormatter.render(customWords) {
        systemPrompt += "\n\n" + vocab
      }
    }

    return PolishInstructions(systemPrompt: systemPrompt)
  }

  // MARK: - Telemetry

  private func logPolishCompletion(
    result: LLMResult, duration: Double,
    extraData: [String: String] = [:]
  ) {
    var data: [String: String] = [
      "provider": llmProvider.rawValue,
      "model": llmModel,
      "duration_s": String(format: "%.3f", duration),
      "char_count": String(result.polishedText.count),
    ]
    data.merge(extraData) { _, new in new }

    SentryBreadcrumb.add(stage: "polish", message: "LLM polish completed", data: data)
    Task {
      await AppLogger.shared.log(
        "LLM polish complete: \(result.polishedText.count) chars in \(String(format: "%.3f", duration))s "
          + "(provider=\(llmProvider.rawValue), model=\(llmModel))",
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
