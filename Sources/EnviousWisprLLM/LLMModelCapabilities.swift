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
/// Consumers: `LLMPolishStep.resolveThinkingConfig` and
/// `AIPolishSettingsView.isReasoningModel` read `supportsReasoning`;
/// `OpenAIConnector` reads `temperaturePolicy` and preflights
/// `supportsChatCompletions`; `LLMModelDiscovery` filters the picker on
/// `supportsChatCompletions`.
public struct LLMModelCapabilities: Sendable, Equatable {
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

  public let supportsReasoning: Bool
  public let temperaturePolicy: TemperaturePolicy
  /// Primary-endpoint (Chat Completions) eligibility. Meaningful for
  /// `.openAI` only — Responses-API-only families (`-pro`, codex) can never
  /// be called by our connector. Other providers return `false` as a
  /// documented constant; nothing consults the field for them.
  public let supportsChatCompletions: Bool

  public init(
    supportsReasoning: Bool,
    temperaturePolicy: TemperaturePolicy,
    supportsChatCompletions: Bool
  ) {
    self.supportsReasoning = supportsReasoning
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
        supportsReasoning: isReasoning,
        temperaturePolicy: isReasoning ? .omit : .include,
        supportsChatCompletions: !isResponsesOnly
      )

    case .gemini:
      return LLMModelCapabilities(
        supportsReasoning: id.hasPrefix("gemini-2.5") || id.hasPrefix("gemini-3"),
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
        supportsReasoning: false,
        temperaturePolicy: .omit,
        supportsChatCompletions: false
      )

    case .ollama, .appleIntelligence, .egOne, .none:
      return LLMModelCapabilities(
        supportsReasoning: false,
        temperaturePolicy: .include,
        supportsChatCompletions: false
      )
    }
  }
}
