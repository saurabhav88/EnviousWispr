import EnviousWisprCore

/// Default implementation of PromptPlanning.
/// Analyzes transcript, selects the appropriate builder, and produces a PolishPlan.
/// Never throws. Bad/missing inputs degrade gracefully.
public struct DefaultPromptPlanner: PromptPlanning {
  public init() {}

  public func plan(input: PromptBuildInput) -> PolishPlan {
    // #1255: the cloud providers (OpenAI/Gemini) use one fixed, modeless prompt. Force their
    // plan mode to `.message` so the builder (which ignores mode), the downstream output
    // validator (`LLMPolishStep` passes `plan.mode` into `validatePolishOutput`), and the
    // `polish_mode` telemetry all share ONE consistent policy that matches the eval mirror.
    // #1269: EG-1 (via Ollama) is modeless the same way — same forced `.message` policy.
    // Other Ollama models keep the analyzer's mode because their builders format by mode.
    let family = Self.family(for: input.provider, modelID: input.modelID)
    let mode: PolishMode
    switch family {
    case .cloudFixed, .egOneFixed:
      mode = .message
    case .openAIProse, .gemmaFewShot:
      mode = TranscriptAnalyzer.analyzeMode(
        transcript: input.transcript,
        appName: input.appName
      )
    }

    // Multilingual v1 (W3): filter polish vocabulary for the active
    // confidence tier + script guardrail BEFORE handing it to the builder.
    // Builders read `input.polishVocabulary.terms`; the planner hands them a
    // tier-appropriate list. Phase 0 (#640) renamed `customWords` →
    // `polishVocabulary` so pack terms can never reach this path.
    let filtered = applyVocabularyPolicy(to: input)

    let builder = Self.builder(for: family)
    let envelope = builder.build(input: filtered, mode: mode)
    return PolishPlan(mode: mode, envelope: envelope)
  }

  /// Select builder by provider + model family, not just provider.
  /// Ollama running non-Gemma models gets OpenAI-style prose prompt.
  public static func builder(for provider: LLMProvider, modelID: String) -> any PromptBuilder {
    builder(for: family(for: provider, modelID: modelID))
  }

  /// Select builder for an already-computed family (single family computation in `plan`).
  static func builder(for family: PromptFamily) -> any PromptBuilder {
    switch family {
    case .cloudFixed: return CloudFixedPromptBuilder()
    case .openAIProse: return OpenAIPromptBuilder()
    case .gemmaFewShot: return GemmaPromptBuilder()
    case .egOneFixed: return EGOnePromptBuilder()
    }
  }

  /// Map (provider, modelID) to a PromptFamily.
  public static func family(for provider: LLMProvider, modelID: String) -> PromptFamily {
    switch provider {
    case .openAI, .gemini, .claude:
      // Strong cloud models: one fixed prompt, no per-transcript mode selection (#1255).
      return .cloudFixed
    case .ollama:
      // EG-1 (our tuned model, #1269) first: explicit precedence for the first-party
      // model over the generic family heuristics below. Single first-party definition
      // shared with telemetry: `OllamaSetupService.isFirstPartyModel`.
      if OllamaSetupService.isFirstPartyModel(modelID) {
        return .egOneFixed
      }
      if modelID.lowercased().contains("gemma") {
        return .gemmaFewShot
      }
      return .openAIProse
    case .egOne:
      // Native EG-1 (#1271): the bundled first-party server always runs the
      // model's training prompt. Model identity is manifest-enforced by
      // `EGOneRuntime` (activation refuses a name/template mismatch), so no
      // per-model-id heuristics apply here.
      return .egOneFixed
    case .appleIntelligence, .none:
      // Should not reach planner. Fallback to openAI prose.
      return .openAIProse
    }
  }

  // MARK: - Multilingual v1 (W3): tiered vocabulary policy

  /// Apply the confidence-tiered + script-guardrail policy to the
  /// PromptBuildInput's vocabulary, returning a copy whose
  /// `polishVocabulary.terms` list contains only the entries permitted by the
  /// active tier.
  ///
  /// Dispatch is driven by the explicit `backend` field so engine identity is
  /// never inferred from `languageDetection == nil`:
  ///
  /// - `backend == .parakeet`: force legacy English path (Parakeet is
  ///   English-only; ignore any `languageDetection` even if set).
  /// - `backend == .whisperKit` + populated detection: tier-gated,
  ///   language-aware policy (W3 behavior).
  ///   - `.locked` or `.highAuto`: global + perLanguage[detected]
  ///   - `.mediumAuto`: global only (no perLanguage)
  ///   - `.lowAuto` or `.abstain`: no lexical injection
  /// - `backend == .whisperKit` + nil detection: defensive
  ///   formatting-only path (treat as low confidence — prevents English
  ///   contamination when the detector is bypassed).
  /// - `backend == nil`: safety-net passthrough for callsites that have not
  ///   adopted the explicit field yet (crash-recovery `RecoveryTextProcessor`, tests).
  private func applyVocabularyPolicy(to input: PromptBuildInput) -> PromptBuildInput {
    // Parakeet: force legacy (English-centric) behavior regardless of any
    // language detection that may have leaked into the input. Parakeet
    // never runs the LID stack, but a caller bug could still populate it.
    if input.backend == .parakeet {
      return input
    }

    // WhisperKit without detection: treat as low confidence. No lexical
    // injection. Defensive: a future WhisperKit codepath that forgets the
    // detector must not silently fall through to the English-centric
    // legacy prompt and corrupt non-English output.
    if input.backend == .whisperKit, input.languageDetection == nil {
      return input.withPolishVocabulary(
        PolishVocabulary(terms: [], generation: input.polishVocabulary.generation)
      )
    }

    guard let detection = input.languageDetection else {
      // backend == nil safety net: untouched callsites (no detection
      // wired, no explicit backend) preserve their existing behavior.
      return input
    }

    let effectiveStrings = input.customVocabulary.effectiveTerms(
      detectedLang: detection.lang,
      tier: detection.tier
    )
    let filteredCustomWords = Self.filterCustomWords(
      input.polishVocabulary.terms,
      tier: detection.tier,
      allowedStrings: Set(effectiveStrings)
    )
    return input.withPolishVocabulary(
      PolishVocabulary(terms: filteredCustomWords, generation: input.polishVocabulary.generation)
    )
  }

  /// Filter the legacy `[CustomWord]` list to match the tier policy.
  /// Aliases and priority from the original entries survive for any word
  /// whose canonical form remains in the allowed set (lets builders still
  /// render "(may be misheard as: ...)" blocks for surviving entries).
  /// If a permitted term came from `perLanguage` (no CustomWord peer), a
  /// synthetic CustomWord is appended with just the canonical and no aliases.
  static func filterCustomWords(
    _ customWords: [CustomWord],
    tier: LanguageConfidenceTier,
    allowedStrings: Set<String>
  ) -> [CustomWord] {
    switch tier {
    case .lowAuto, .abstain:
      return []
    case .mediumAuto, .locked, .highAuto:
      // Keep CustomWord entries whose canonical is allowed.
      var kept = customWords.filter { allowedStrings.contains($0.canonical) }
      // Append synthetic entries for allowed strings that did not come
      // from a CustomWord (i.e., perLanguage-only terms).
      let keptCanonicals = Set(kept.map(\.canonical))
      for term in allowedStrings where !keptCanonicals.contains(term) {
        kept.append(CustomWord(canonical: term))
      }
      return kept
    }
  }
}
