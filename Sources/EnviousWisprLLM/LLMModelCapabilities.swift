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
    /// that have no thinking control in the pipeline's sense (Claude takes its thinking
    /// part from `claudeRequestShape` instead, #3425; Ollama, Apple
    /// Intelligence, EG-1 have none) and Gemini/OpenAI ids absent from the tables below.
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

  /// Whether this model takes a thinking parameter, and in which dialect.
  ///
  /// `.unsupported` IS the "takes no thinking parameter" answer; read it
  /// directly rather than reintroducing a derived Bool. #1770 added
  /// `supportsReasoning` for the Deep-reasoning toggle's visibility gate,
  /// #1831 deleted that gate, and Periphery then reported the property dead in
  /// production — its only remaining callers were tests, which that scan
  /// excludes, so they never kept it alive. One fact, one spelling.
  public let thinkingControl: ThinkingControl
  public let temperaturePolicy: TemperaturePolicy
  /// Primary-endpoint (Chat Completions) eligibility. Meaningful for
  /// `.openAI` only — Responses-API-only families (`-pro`, codex) can never
  /// be called by our connector. Other providers return `false` as a
  /// documented constant; nothing consults the field for them.
  public let supportsChatCompletions: Bool
  /// The thinking part of a Claude request body (#3425). Meaningful for
  /// `.claude` only; every other provider carries the default and nothing
  /// consults it. Kept apart from `thinkingControl` on purpose: the pipeline's
  /// `ResolvedThinking` cannot express these shapes, and Claude's connector
  /// reads this field directly in `ClaudeConnector.makeRequestBody`, which
  /// polish, the picker probe and the network warmup all share.
  public let claudeRequestShape: ClaudeRequestShape

  /// How a Claude request asks for its thinking behaviour. Verified live on
  /// 2026-10-03 (#3425): the generations that reject `thinking: disabled`
  /// name a replacement in the 400 body, and no single shape works for all of
  /// them, so the shape is per exact model id.
  public enum ClaudeRequestShape: Sendable, Equatable {
    /// `thinking: {"type": "disabled"}`. Today's body for every Claude id
    /// that accepts it, and the default for any id not listed below.
    case thinkingDisabled
    /// `thinking: {"type": "between_tools"}`, no effort field. The model does
    /// not think before answering (Sonnet 5.5 refuses `disabled`).
    case thinkingBetweenTools
    /// No `thinking` field, `output_config: {"effort": "low"}`. For models that
    /// refuse both `disabled` and `between_tools` and always think (Opus 5.5,
    /// Fable 5, Fable 5.1); `low` is the least they will do.
    case effortLow
  }

  public init(
    thinkingControl: ThinkingControl,
    temperaturePolicy: TemperaturePolicy,
    supportsChatCompletions: Bool,
    claudeRequestShape: ClaudeRequestShape = .thinkingDisabled
  ) {
    self.thinkingControl = thinkingControl
    self.temperaturePolicy = temperaturePolicy
    self.supportsChatCompletions = supportsChatCompletions
    self.claudeRequestShape = claudeRequestShape
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
      // #3425: the gpt-6 generation is reasoning-shaped too (every one rejects
      // `temperature: 0`, live 2026-10-03). Bounded on purpose: `gpt-60-future`
      // must not match, so "gpt-6" is exact or followed by `-` or `.`.
      let isGPT6Family = id == "gpt-6" || id.hasPrefix("gpt-6-") || id.hasPrefix("gpt-6.")
      let isReasoning =
        id.hasPrefix("o1")
        || id.hasPrefix("o3")
        || id.hasPrefix("o4")
        || ((id.hasPrefix("gpt-5") || isGPT6Family) && !isChatVariant)

      let isResponsesOnly = id.contains("codex") || id.contains("-pro")

      return LLMModelCapabilities(
        thinkingControl: isReasoning
          ? .effort(LLMModelCapabilities.openAIReasoningEffort(id)) : .unsupported,
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
      // `thinkingControl` stays `.unsupported`: the pipeline never sends Claude
      // a thinking value; the connector builds the thinking part of its own body
      // from `claudeRequestShape` (#3425). `.omit` (not `.include`) because
      // Claude generations released after Opus 4.6 reject a non-default
      // `temperature`, including 0, with an HTTP 400 — the same
      // unconditional-omit shape #1330 established for OpenAI's reasoning
      // family, applied here so a future catalog model doesn't silently break.
      return LLMModelCapabilities(
        thinkingControl: .unsupported,
        temperaturePolicy: .omit,
        supportsChatCompletions: false,
        claudeRequestShape: LLMModelCapabilities.claudeShape(forModel: id)
      )

    // #2649: `.s1Mini` joins this arm rather than getting one of its own. The
    // model DOES have a think block, but it is suppressed at LAUNCH by
    // `--chat-template-kwargs '{"enable_thinking":false}'`, not by a per-request
    // field — so there is no thinking control to express here. Sending one is
    // precisely the #2634 failure mode: a request-level thinking parameter
    // returns 0 characters of content after 11.6 s.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
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

    // 3.8 Flash has 3.7 Flash's shape: `minimal` -> 400 "Thinking level MINIMAL
    // is not supported for this model", `low` accepted, verified live 2026-10-03
    // (#3425). With no row it fell through to `.unsupported` and thought by
    // default: 3.2 to 6.0s and 600 to 1,200 thinking tokens per short dictation,
    // against 0.7 to 1.4s and 0 tokens at `low` (3 requests per cell).
    case "gemini-3.8-flash":
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

  /// Gemini ids the app knows that take NO thinking parameter at all (#3425).
  /// They exist so "no row" is a recorded decision rather than an omission:
  /// `SettingsChangeTelemetryTests` requires every curated Gemini id to either
  /// resolve a thinking value or appear here. All five predate thinking.
  public static let geminiIDsWithoutThinkingControl: Set<String> = [
    "gemini-1.5-pro", "gemini-1.5-flash", "gemini-1.5-flash-8b",
    "gemini-2.0-flash", "gemini-2.0-flash-lite",
  ]

  /// OpenAI reasoning effort, keyed on EXACT model ids (#3425).
  ///
  /// `low` is what every user has always received here: it was the toggle's OFF
  /// value, the toggle shipped OFF by default (#1831), and the prior resolver
  /// sent it before the toggle existed (#1330). It stays the answer for every id
  /// not listed, including every id nobody has probed.
  ///
  /// `none` (the fastest setting) goes to every id the 2026-10-03 live probe
  /// confirmed returns 200 at `none` (3 requests per cell, short dictation text):
  /// `gpt-6-luna`, `gpt-6-sol`, `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol`,
  /// `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`. Four of them already spent zero
  /// reasoning tokens at `low`, so for those `none` is a guaranteed floor rather than
  /// a measured gain; three requests per cell cannot prove that on future dictations.
  /// `gpt-6-astra` and `gpt-6.1-sol` REJECT `none` (400) and OpenAI documents `low` as
  /// their floor, so they stay on `low`.
  ///
  /// A dated snapshot of a listed id (`gpt-5.5-2026-04-23`) gets its alias's value: a
  /// snapshot is an immutable copy of the alias, the model picker offers snapshots, and
  /// the live sweep polishes every offered id. Only a trailing `-YYYY-MM-DD` is removed,
  /// and only for this lookup; the request keeps the original id.
  ///
  /// Cleanup quality at `none` is NOT VERIFIED: the founder waived the check for
  /// speed (#3425). The 2026-09 bench scored `gpt-5.4-mini` at `none` lowest of
  /// four models.
  fileprivate static func openAIReasoningEffort(_ id: String) -> String {
    switch withoutTrailingISODate(id) {
    case "gpt-6-luna", "gpt-6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
      "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2":
      return "none"
    default:
      return "low"
    }
  }

  /// `gpt-5.5-2026-04-23` -> `gpt-5.5`. Only a trailing `-YYYY-MM-DD` made of ASCII digits and
  /// naming a real Gregorian date (month lengths, leap years) is removed; anything else,
  /// including `-2026-02-31` and a signed component such as `-+1`, is returned unchanged.
  fileprivate static func withoutTrailingISODate(_ id: String) -> String {
    let parts = id.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count >= 4 else { return id }
    func digits(_ part: Substring, count: Int) -> Int? {
      guard part.count == count, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
      return Int(part)
    }
    guard let year = digits(parts[parts.count - 3], count: 4), year >= 2000,
      let month = digits(parts[parts.count - 2], count: 2), (1...12).contains(month),
      let day = digits(parts[parts.count - 1], count: 2)
    else { return id }
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let monthLengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...monthLengths[month - 1]).contains(day) else { return id }
    return parts.dropLast(3).joined(separator: "-")
  }

  /// Claude's request shape, keyed on EXACT model ids (#3425). Everything not
  /// listed keeps `thinking: disabled`, today's body.
  ///
  /// Verified live 2026-10-03: `thinking: disabled` returns 200 on
  /// `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`, `claude-opus-4-5`
  /// through `-4-8`, `claude-sonnet-4-5` and `-4-6`. It returns 400 on the four
  /// ids below, whose 400 bodies name the replacement. `between_tools` works
  /// only on Sonnet 5.5 (Opus 5.5 rejects it). `output_config.effort: "low"` with
  /// no `thinking` field returns 200 on Opus 5.5, Fable 5 and Fable 5.1, which
  /// think regardless; `minimal` is not a legal effort value.
  fileprivate static func claudeShape(forModel id: String) -> ClaudeRequestShape {
    switch id {
    case "claude-sonnet-5-5":
      return .thinkingBetweenTools
    case "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1":
      return .effortLow
    default:
      return .thinkingDisabled
    }
  }
}
