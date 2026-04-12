import EnviousWisprCore

/// Default implementation of PromptPlanning.
/// Analyzes transcript, selects the appropriate builder, and produces a PolishPlan.
/// Never throws. Bad/missing inputs degrade gracefully.
public struct DefaultPromptPlanner: PromptPlanning {
    public init() {}

    public func plan(input: PromptBuildInput) -> PolishPlan {
        // legacyTemplate mode defaults to .message for validator thresholds
        let mode: PolishMode
        if input.customPromptMode == .legacyTemplate {
            mode = .message
        } else {
            mode = TranscriptAnalyzer.analyzeMode(
                transcript: input.transcript,
                appName: input.appName
            )
        }

        // Multilingual v1 (W3): filter custom vocabulary for the active
        // confidence tier + script guardrail BEFORE handing it to the builder.
        // Builders continue to read `input.customWords`, but the planner hands
        // them a tier-appropriate list.
        let filtered = applyVocabularyPolicy(to: input)

        let builder = Self.builder(for: input.provider, modelID: input.modelID)
        let envelope = builder.build(input: filtered, mode: mode)
        return PolishPlan(mode: mode, envelope: envelope)
    }

    /// Select builder by provider + model family, not just provider.
    /// Ollama running non-Gemma models gets OpenAI-style prose prompt.
    public static func builder(for provider: LLMProvider, modelID: String) -> any PromptBuilder {
        switch family(for: provider, modelID: modelID) {
        case .geminiPlain: return GeminiPromptBuilder()
        case .openAIProse: return OpenAIPromptBuilder()
        case .gemmaFewShot: return GemmaPromptBuilder()
        }
    }

    /// Map (provider, modelID) to a PromptFamily.
    public static func family(for provider: LLMProvider, modelID: String) -> PromptFamily {
        switch provider {
        case .gemini:
            return .geminiPlain
        case .openAI:
            return .openAIProse
        case .ollama:
            if modelID.lowercased().contains("gemma") {
                return .gemmaFewShot
            }
            return .openAIProse
        case .appleIntelligence, .none:
            // Should not reach planner. Fallback to openAI prose.
            return .openAIProse
        }
    }

    // MARK: - Multilingual v1 (W3): tiered vocabulary policy

    /// Apply the confidence-tiered + script-guardrail policy to the
    /// PromptBuildInput's vocabulary, returning a copy whose `customWords` list
    /// contains only the entries permitted by the active tier.
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
    ///   adopted the explicit field yet (TranscriptPolishService, tests).
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
            return input.withCustomWords([])
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
            input.customWords,
            tier: detection.tier,
            detectedLang: detection.lang,
            allowedStrings: Set(effectiveStrings)
        )
        return input.withCustomWords(filteredCustomWords)
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
        detectedLang: String?,
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
