import EnviousWisprCore

/// Default implementation of PromptPlanning.
/// Analyzes transcript, selects the appropriate builder, and produces a PolishPlan.
/// Never throws. Bad/missing inputs degrade gracefully.
public struct DefaultPromptPlanner: PromptPlanning {
  /// Which EG-1 prompt THIS app build serves. Read from the bundled `eg1-manifest.json`'s
  /// `promptTemplateID`, because the artifact and its prompt are one contract — a model may
  /// only ever be sent the instruction it was tuned on — and one app build ships exactly one
  /// manifest. Held as a value rather than re-read per polish so the decision is made once,
  /// and injectable so a test can drive a template id this build does not ship.
  let egOneFamily: PromptFamily

  public init() { self.init(egOneFamily: Self.bundledEGOneFamily) }

  init(egOneFamily: PromptFamily) { self.egOneFamily = egOneFamily }

  /// The bundled manifest's declared family, resolved once.
  ///
  /// The `.egOneFixed` fallback keeps this total; it is not a behaviour anyone reaches.
  /// `EGOneManifest.loadBundled` throws only when the resource is absent, and
  /// `activationBlockers()` already refuses to activate EG-1 on an unknown
  /// `promptTemplateID`, so a build that cannot answer this question cannot have EG-1 as
  /// its active provider either.
  static let bundledEGOneFamily: PromptFamily =
    (try? EGOneManifest.loadBundled())?.promptFamily ?? .egOneFixed

  public func plan(input: PromptBuildInput) -> PolishPlan {
    // #1255: the cloud providers use one fixed, modeless prompt. Force the plan mode to
    // `.message` so the builder (which ignores mode), the downstream output validator
    // (`LLMPolishStep` passes `plan.mode` into `validatePolishOutput`), and the
    // `polish_mode` telemetry all share ONE consistent policy that matches the eval mirror.
    // #1269: EG-1 is modeless the same way.
    // #1948: local Ollama joined them. Every family is now modeless, so there is one policy
    // rather than a switch — `TranscriptAnalyzer` and its per-transcript selection are gone.
    // The validator's thresholds are the only remaining consumer of `mode`, and the cost of
    // moving the former `.structured` inputs onto `.message` thresholds was measured before
    // the change: +11 fallbacks of 1,690 on `qwen2.5:3b`, +6 on `llama3.2`.
    let family = Self.family(
      for: input.provider,
      modelID: input.modelID,
      ollamaIsRemote: input.ollamaIsRemote,
      egOneFamily: egOneFamily
    )
    let mode: PolishMode = .message

    // Multilingual v1 (W3): filter polish vocabulary for the active
    // confidence tier + script guardrail BEFORE handing it to the builder.
    // Builders read `input.polishVocabulary.terms`; the planner hands them a
    // tier-appropriate list. Phase 0 (#640) renamed `customWords` →
    // `polishVocabulary` so pack terms can never reach this path.
    let filtered = applyVocabularyPolicy(to: input)

    let builder = Self.builder(for: family)
    let envelope = builder.build(input: filtered, mode: mode)
    return PolishPlan(mode: mode, envelope: envelope, family: family)
  }

  /// Select builder for an already-computed family (single family computation in `plan`).
  static func builder(for family: PromptFamily) -> any PromptBuilder {
    switch family {
    case .cloudFixed: return CloudFixedPromptBuilder()
    case .localFixed: return LocalFixedPromptBuilder()
    case .egOneFixed: return EGOnePromptBuilder()
    case .egOneEnvelope: return EGOneEnvelopePromptBuilder()
    }
  }

  /// Map (provider, model identity, execution location) to a `PromptFamily`.
  ///
  /// Non-public and called from exactly one place — `plan()`. Before #1948 the pipeline
  /// called a public version a second time purely to stamp telemetry; `PolishPlan.family`
  /// now carries the result so the decision cannot be re-derived differently.
  static func family(
    for provider: LLMProvider,
    modelID: String,
    ollamaIsRemote: Bool?,
    egOneFamily: PromptFamily
  ) -> PromptFamily {
    switch provider {
    case .openAI, .gemini, .claude:
      // Strong cloud models: one fixed prompt, no per-transcript mode selection (#1255).
      return .cloudFixed
    case .ollama:
      // EG-1 (our tuned model, #1269) first: explicit precedence for the first-party model
      // over execution location. An EG-1 served from anywhere still needs its exact
      // training prompt. Single first-party definition shared with telemetry:
      // `OllamaSetupService.isFirstPartyModel`.
      if OllamaSetupService.isFirstPartyModel(modelID) {
        // KNOWN LIMIT, stated rather than hidden: an EG-1 pulled through Ollama carries no
        // manifest, so the app cannot learn which revision those bytes are and holds the
        // 1.1 prompt. A user who sideloads 1.2 this way gets 1.1's instruction. The native
        // `.egOne` path above is the supported one and does know.
        return .egOneFixed
      }
      // #1948: the daemon's own report decides it — never the model's name or size.
      // A HOSTED model runs on Ollama's servers and is frontier-class, so it gets the
      // prompt already validated for frontier models. Everything else runs on the user's
      // Mac and gets the one local prompt, whatever it is called and however large it is.
      //
      // `nil` (no daemon asked) falls to local with `false`, deliberately: see
      // `PromptBuildInput.ollamaIsRemote` for why local is the fail-safe direction.
      return ollamaIsRemote == true ? .cloudFixed : .localFixed
    case .egOne:
      // Native EG-1 (#1271): the bundled first-party server always runs the model's
      // training prompt. WHICH training prompt is the manifest's answer, not a constant —
      // 1.1 and 1.2 were tuned on different text, and serving either model the other's
      // instruction is the drift the hot-swap contract exists to prevent. Model identity
      // is manifest-enforced by `EGOneRuntime` (activation refuses a name/template
      // mismatch), so no per-model-id heuristics apply here.
      return egOneFamily
    case .appleIntelligence, .none:
      // Should not reach the planner — Apple Intelligence has its own prompt path
      // (`LLMPolishStep` branches before planning). Fall back to the fixed cloud prompt,
      // which is provider-agnostic and mode-independent.
      return .cloudFixed
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
