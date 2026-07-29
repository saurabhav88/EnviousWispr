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
/// the request; `AIPolishSettingsView.isReasoningModel` reads the derived
/// `supportsReasoning` to decide whether to show the Deep-reasoning toggle;
/// `OpenAIConnector` reads `temperaturePolicy` and preflights
/// `supportsChatCompletions`; `LLMModelDiscovery` filters the picker on
/// `supportsChatCompletions`.
public struct LLMModelCapabilities: Sendable, Equatable {
  /// How a model expresses "how hard to think", and the two values our
  /// Deep-reasoning toggle maps onto (#1770).
  ///
  /// Dialect and values travel TOGETHER because providers disagree on both the
  /// KEY and the legal values per model: Gemini 2.5 takes an integer
  /// `thinkingBudget`, Gemini 3 takes a string `thinkingLevel` and rejects
  /// `thinkingBudget: 0` outright. A dialect without its values is exactly what
  /// let `thinkingBudget: 0` reach models that refuse it.
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
    case budget(fast: Int, deep: Int)
    /// Gemini 3 dialect: string level (minimal/low/medium/high).
    case level(fast: String, deep: String)
    /// OpenAI dialect: `reasoning_effort`.
    case effort(fast: String, deep: String)
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
  /// Whether the Deep-reasoning toggle is meaningful for this model.
  ///
  /// DERIVED, never stored: toggle visibility and request shape are two
  /// statements about one fact, and storing both is how they drift (#1770).
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
        // Unchanged behaviour, restated as a dialect: the prior resolver
        // has always sent low/medium for these ids (#1330).
        thinkingControl: isReasoning ? .effort(fast: "low", deep: "medium") : .unsupported,
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
  /// The `deep:` values are provisional — #1832 measures whether thinking level
  /// changes polish quality at all. `"high"` is the widest separation from
  /// `minimal`, not an evidence-backed optimum.
  fileprivate static func geminiThinkingControl(_ id: String) -> ThinkingControl {
    switch id {
    // Gemini 3 Flash tier: `minimal` returns 200 and spends 0 thinking tokens.
    case "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite",
      "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview",
      "gemini-3-flash-preview":
      return .level(fast: "minimal", deep: "high")

    // Gemini 3 Pro tier: `minimal` -> 400 "Thinking level MINIMAL is not
    // supported for this model", so `low` is the floor Google permits.
    case "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools":
      return .level(fast: "low", deep: "high")

    // Gemini 2.5 Flash tier: budget 0 is legal and spends 0 thinking tokens.
    // NOTE 2.5-flash-lite rejects 128 ("choose a value between 512 and 24576")
    // while accepting 0 — which is why the off-state value is per-model here
    // and not a per-tier rule.
    case "gemini-2.5-flash", "gemini-2.5-flash-lite":
      return .budget(fast: 0, deep: 8192)

    // Gemini 2.5 Pro: budget 0 -> 400 "This model only works in thinking
    // mode"; 128 is the documented and measured minimum.
    case "gemini-2.5-pro":
      return .budget(fast: 128, deep: 8192)

    default:
      return .unsupported
    }
  }
}
