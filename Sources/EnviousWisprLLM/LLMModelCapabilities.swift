import EnviousWisprCore
import Foundation

/// Per-model request-shape capabilities for cloud LLM providers (#1330).
///
/// One authority for three INDEPENDENT facts about a model. They must stay
/// independent: GPT-5.4-mini accepts `temperature: 0` yet is a reasoning
/// model, and `gpt-5-chat-latest` is Chat-Completions-capable yet
/// non-reasoning — collapsing these into one "is reasoning" bit is the
/// conflation that produced the silent gpt-5.5 polish outage (#1330).
///
/// Consumers: `LLMPolishStep.resolveThinking` reads `thinkingControl` to build
/// the request; `OpenAIConnector` reads `temperaturePolicy` and preflights
/// `supportsChatCompletions`; `LLMModelDiscovery` filters the picker on
/// `supportsChatCompletions`.
public struct LLMModelCapabilities: Sendable, Equatable {
  /// How a model expresses "how hard to think", and the one value we send it
  /// (#1770; collapsed from a fast/deep pair by #1831).
  ///
  /// Dialect and value travel TOGETHER because providers disagree on both the
  /// KEY and the legal values per model: Gemini 2.5 takes an integer
  /// `thinkingBudget`, Gemini 3 takes a string `thinkingLevel` and rejects
  /// `thinkingBudget: 0` outright. A dialect without its value is exactly what
  /// let `thinkingBudget: 0` reach models that refuse it. The three dialect
  /// CASES therefore stay distinct — collapsing them into one "is reasoning"
  /// bit is the #1330 conflation this type exists to prevent. #1831 collapsed
  /// only the pair, never the dialect.
  ///
  /// Keyed on EXACT model ids, never prefixes. A `gemini-3` prefix row would
  /// silently capture a future `gemini-3.7-flash` we have never tested and send
  /// it an unverified value; with exact ids anything unknown reaches
  /// `.unsupported`, which sends no thinking field at all. That shape succeeded
  /// on all eleven working Gemini models measured on 2026-07-28/29; future
  /// models are unverified by construction, so it is the safest first attempt
  /// rather than a guarantee.
  public enum ThinkingControl: Sendable, Equatable {
    /// Send no thinking parameter. Covers two different situations: providers
    /// that have no thinking control at all (Claude, Ollama, Apple
    /// Intelligence, EG-1) and Gemini/OpenAI ids absent from the tables below.
    /// What the provider then does is its own business — Gemini 3 Flash, for
    /// instance, thinks by default and is measurably slower for it.
    case unsupported
    /// Gemini 2.5 dialect: integer token budget.
    case budget(Int)
    /// Gemini 3 dialect: string level (minimal/low/medium/high).
    case level(String)
    /// OpenAI dialect: `reasoning_effort`.
    case effort(String)
  }

  public enum TemperaturePolicy: Sendable, Equatable {
    /// Classic chat models: send `temperature: 0` for deterministic polish.
    case include
    /// Reasoning-shape models: never send `temperature`. GPT-5.5 rejects a
    /// non-default temperature even when no reasoning-effort field is
    /// present (11/11 rejections, #1330), so omission is unconditional.
    /// A conditional policy would recreate the failure after an effort
    /// strip. Models that tolerate the field, such as GPT-5.4-mini, remain
    /// API-compatible when it is omitted, but their output behavior may
    /// change because the provider default is not temperature zero.
    case omit
  }

  public let thinkingControl: ThinkingControl
  /// Whether this model takes a thinking parameter at all.
  ///
  /// DERIVED, never stored: two statements about one fact drift when both are
  /// stored (#1770).
  public var supportsReasoning: Bool { thinkingControl != .unsupported }
  public let temperaturePolicy: TemperaturePolicy
  /// Primary-endpoint (Chat Completions) eligibility. Meaningful for
  /// `.openAI` only — Responses-API-only families (`-pro`, codex) can never
  /// be called by our connector. Other providers return `false` as a
  /// documented constant; nothing consults the field for them.
  public let supportsChatCompletions: Bool

  public init(
    thinkingControl: ThinkingControl,
    temperaturePolicy: TemperaturePolicy,
    supportsChatCompletions: Bool
  ) {
    self.thinkingControl = thinkingControl
    self.temperaturePolicy = temperaturePolicy
    self.supportsChatCompletions = supportsChatCompletions
  }
}

extension LLMProvider {
  /// Resolve the request-shape capability profile for `model`.
  ///
  /// Static knowledge, deliberately: OpenAI publishes no machine-readable
  /// per-model parameter rules (their models endpoint returns IDs only), so
  /// a "live rules lookup" cannot exist. The runtime containment for this
  /// table going stale is `OpenAIConnector`'s unsupported-param
  /// strip-and-retry, which self-heals a mismatch in one extra round-trip
  /// and memoizes it for the rest of the process.
  public func modelCapabilities(model: String) -> LLMModelCapabilities {
    let id = model.lowercased()

    switch self {
    case .openAI:
      // Chat-tuned variants (gpt-5-chat-latest) are non-reasoning even
      // though they carry the gpt-5 prefix.
      let isChatVariant = id.contains("-chat")
      let isReasoning =
        id.hasPrefix("o1")
        || id.hasPrefix("o3")
        || id.hasPrefix("o4")
        || (id.hasPrefix("gpt-5") && !isChatVariant)

      let isResponsesOnly = id.contains("codex") || id.contains("-pro")

      return LLMModelCapabilities(
        // `low` is what every user has always received here: it was the
        // toggle's OFF value, the toggle shipped OFF by default (#1831), and
        // the prior resolver sent it before the toggle existed (#1330).
        thinkingControl: isReasoning ? .effort("low") : .unsupported,
        temperaturePolicy: isReasoning ? .omit : .include,
        supportsChatCompletions: !isResponsesOnly
      )

    case .gemini:
      return LLMModelCapabilities(
        thinkingControl: LLMModelCapabilities.geminiThinkingControl(id),
        temperaturePolicy: .include,
        supportsChatCompletions: false
      )

    case .claude:
      // v1: no extended thinking, ever. `.omit` (not `.include`) because
      // Claude generations released after Opus 4.6 reject a non-default
      // `temperature`, including 0, with an HTTP 400 — the same
      // unconditional-omit shape #1330 established for OpenAI's reasoning
      // family, applied here so a future catalog model doesn't silently break.
      return LLMModelCapabilities(
        thinkingControl: .unsupported,
        temperaturePolicy: .omit,
        supportsChatCompletions: false
      )

    case .ollama, .appleIntelligence, .egOne, .none:
      return LLMModelCapabilities(
        thinkingControl: .unsupported,
        temperaturePolicy: .include,
        supportsChatCompletions: false
      )
    }
  }
}

extension LLMModelCapabilities {
  /// Gemini's thinking dialect, keyed on EXACT model ids (#1770).
  ///
  /// Every value here was verified against the live API on 2026-07-28/29 by
  /// issuing the real request shape; none is inferred from documentation, which
  /// is wrong in both directions (it claims Gemini 3 Flash cannot disable
  /// thinking — `minimal` measurably spends zero thinking tokens — and it lists
  /// `gemini-3.1-flash-lite-preview` as withdrawn when it returns 200).
  ///
  /// Deliberately NOT prefix-matched. `gemini-3` would capture an untested
  /// future id and hand it an unverified value. Unlisted ids fall through to
  /// `.unsupported`, which sends no thinking field — a shape that succeeded on
  /// all eleven working Gemini models measured on 2026-07-28/29. Future models
  /// are unverified by construction, so that is the safest first attempt, not a
  /// guarantee; an unlisted model also loses the Deep-reasoning toggle until a
  /// row is added here.
  ///
  /// Every value below is the one the Deep-reasoning toggle sent in its OFF
  /// position, which was the shipped default, so this table is byte-identical
  /// on the wire for every user who never flipped it. The `deep:` half was
  /// removed by #1831 after #1832 measured it. Scope matters and is easy to
  /// overstate: 100 `topic_shift` cases from `type_b_parakeet`, NOT the
  /// 1,462-case `sealed_v1` run that chose this model. Pass rate 57.0 / 58.0 /
  /// 61.0% for low / medium / high, McNemar exact two-sided p=0.42 for low vs
  /// high, so the nominal edge is not distinguishable from chance at n=100;
  /// p90 2.83x. CRITICAL failures moved the other way, 1 -> 2 -> 3. Table:
  /// `benchmark-results/eval/runs/1832-gemini-thinking-topicshift-2026-08-23/`.
  fileprivate static func geminiThinkingControl(_ id: String) -> ThinkingControl {
    switch id {
    // Gemini 3 Flash tier: `minimal` returns 200 and spends 0 thinking tokens.
    case "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite",
      "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview",
      "gemini-3-flash-preview":
      return .level("minimal")

    // 3.7 Flash sits in the Pro tier's shape despite the Flash name: `minimal`
    // -> 400 "Thinking level MINIMAL is not supported for this model", verified
    // live 2026-08-16 and confirmed against Google's per-model table (3.7 Flash
    // accepts low/medium/high; 3.6 Flash still accepts minimal). It is the first
    // Flash-tier id that cannot reach zero thinking, so it must NOT join the
    // Flash `case` above — that would send `minimal` and 400 every request.
    //
    // This row is load-bearing for cost, not just correctness. An unlisted id
    // falls through to `.unsupported`, which sends no thinking field, and the
    // Gemini 3 default is now `medium`. Measured on sealed_v1 at `low`: 147
    // thinking tokens per dictation, billed at the OUTPUT rate. Defaulting to
    // medium would silently spend more than that on every polish, and the 93.5%
    // score this model was chosen on was measured at `low`, not at medium.
    case "gemini-3.7-flash":
      return .level("low")

    // Gemini 3 Pro tier: `minimal` -> 400 "Thinking level MINIMAL is not
    // supported for this model", so `low` is the floor Google permits.
    case "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools":
      return .level("low")

    // Gemini 2.5 Flash tier: budget 0 is legal and spends 0 thinking tokens.
    // NOTE 2.5-flash-lite rejects 128 ("choose a value between 512 and 24576")
    // while accepting 0 — which is why this value is per-model here and not a
    // per-tier rule.
    case "gemini-2.5-flash", "gemini-2.5-flash-lite":
      return .budget(0)

    // Gemini 2.5 Pro: budget 0 -> 400 "This model only works in thinking
    // mode"; 128 is the documented and measured minimum.
    case "gemini-2.5-pro":
      return .budget(128)

    default:
      return .unsupported
    }
  }
}
