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
  /// Keyed on EXACT model ids (a cloud model list row, #4353 D6), never prefixes. A
  /// `gemini-3` prefix row would silently capture a future `gemini-3.7-flash` we have never
  /// tested and send it an unverified value; with exact ids anything unknown reaches
  /// `.unsupported`, which sends no thinking field at all. That shape succeeded
  /// on all eleven working Gemini models measured on 2026-07-28/29; future
  /// models are unverified by construction, so it is the safest first attempt
  /// rather than a guarantee.
  public enum ThinkingControl: Sendable, Equatable {
    /// Send no thinking parameter. Covers two different situations: providers
    /// that have no thinking control in the pipeline's sense (Claude takes its thinking
    /// part from `claudeRequestShape` instead, #3425; Ollama, Apple
    /// Intelligence, EG-1 have none), Gemini ids the cloud model list does not name, and
    /// list rows that say `"none"` or `"omit"`.
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
  /// Resolve the request-shape capability profile for `model` from one operation's captured
  /// cloud model list (#4353 D6).
  ///
  /// For a cloud provider: the list row for the exact id, else the row for its dated base
  /// (`ProviderModelID.withoutDateSnapshot`), else the compiled fallback for unlisted ids. A
  /// listed row decides every field, so a listed `false` or "no thinking" never falls through
  /// to a heuristic. `list` is required: every caller names the snapshot its operation
  /// captured, and `nil` (no list was available) means every id is unlisted. The request keeps
  /// the original id; only this lookup uses the base.
  ///
  /// Static knowledge, deliberately: OpenAI publishes no machine-readable per-model parameter
  /// rules (their models endpoint returns IDs only). The runtime containment for a stale row
  /// is `OpenAIConnector`'s unsupported-param strip-and-retry, which self-heals a mismatch in
  /// one extra round-trip and memoizes it for the rest of the process.
  public func modelCapabilities(model: String, list: CloudModelList?) -> LLMModelCapabilities {
    if let row = listedRow(model: model, list: list) {
      return Self.capabilities(of: row)
    }
    return unlistedCapabilities(model: model)
  }

  /// Whether file import may send this model several parts in one request (#2905). A listed
  /// row answers with its `allowsFileBatch`; an unlisted id uses the compiled fallback below.
  public func allowsFileBatch(model: String, list: CloudModelList?) -> Bool {
    if let row = listedRow(model: model, list: list) { return row.allowsFileBatch }
    // #2905 prepared-input checks found a lost speaker-leading word in GPT-4o mini
    // batches and a changed source noun in Haiku 4.5, retained by matched ordinary
    // requests. Keep these families, including dated aliases, on individual calls:
    // valid section tags alone cannot establish that cleanup preserved meaning.
    // Prefixes on purpose, so any suffix (dated or not) of an unlisted id inherits.
    let id = model.lowercased()
    switch self {
    case .openAI: return !id.hasPrefix("gpt-4o-mini")
    case .claude: return !id.hasPrefix("claude-haiku-4-5")
    case .gemini: return true
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
    }
  }

  /// The list row that decides `model` for this provider: exact id first, then the dated
  /// base. Nil for a non-cloud provider, a missing list, or an unlisted id.
  public func listedRow(model: String, list: CloudModelList?) -> CloudModelList.Row? {
    guard let list, [.openAI, .gemini, .claude].contains(self) else { return nil }
    let id = model.lowercased()
    func row(_ candidate: String) -> CloudModelList.Row? {
      list.models.first { $0.provider == self && $0.id == candidate }
    }
    if let exact = row(id) { return exact }
    return ProviderModelID.withoutDateSnapshot(id).flatMap(row)
  }

  private static func capabilities(of row: CloudModelList.Row) -> LLMModelCapabilities {
    switch row.request {
    case .openAI(let effort, let temperature):
      let thinking: LLMModelCapabilities.ThinkingControl =
        switch effort {
        case .omit: .unsupported
        case .none, .low, .minimal: .effort(effort.rawValue)
        }
      return LLMModelCapabilities(
        thinkingControl: thinking, temperaturePolicy: temperature,
        supportsChatCompletions: row.supportsChatCompletions)
    case .gemini(let geminiThinking):
      let thinking: LLMModelCapabilities.ThinkingControl =
        switch geminiThinking {
        case .none: .unsupported
        case .budget(let budget): .budget(budget)
        case .level(let level): .level(level)
        }
      return LLMModelCapabilities(
        thinkingControl: thinking, temperaturePolicy: .include, supportsChatCompletions: false)
    case .claude(let shape):
      return LLMModelCapabilities(
        thinkingControl: .unsupported, temperaturePolicy: .omit, supportsChatCompletions: false,
        claudeRequestShape: shape)
    }
  }

  /// The compiled rule for an id the list does not name (plan D6 decision 4).
  private func unlistedCapabilities(model: String) -> LLMModelCapabilities {
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

      // `low` is what every user has always received for an unprobed reasoning id: it was
      // the Deep-reasoning toggle's OFF value, the toggle shipped OFF by default (#1831),
      // and the prior resolver sent it before the toggle existed (#1330).
      return LLMModelCapabilities(
        thinkingControl: isReasoning ? .effort("low") : .unsupported,
        temperaturePolicy: isReasoning ? .omit : .include,
        supportsChatCompletions: !isResponsesOnly
      )

    case .gemini:
      // Deliberately NOT prefix-matched. `gemini-3` would capture an untested future id and
      // hand it an unverified value. Unlisted ids send no thinking field — a shape that
      // succeeded on all eleven working Gemini models measured on 2026-07-28/29. Future
      // models are unverified by construction, so that is the safest first attempt, not a
      // guarantee. Note the Gemini 3 default is `medium`: an unlisted Gemini 3 id thinks
      // by default and is billed for it until a list row is added.
      return LLMModelCapabilities(
        thinkingControl: .unsupported,
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
      // Everything unlisted keeps `thinking: disabled`, today's body.
      return LLMModelCapabilities(
        thinkingControl: .unsupported,
        temperaturePolicy: .omit,
        supportsChatCompletions: false,
        claudeRequestShape: .thinkingDisabled
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

// MARK: - Seed provenance
//
// #4353 D6 moved the exact-id tables below into `cloud-models.json` (bundled copy
// `Sources/EnviousWispr/Resources/cloud-models.json`). Their evidence stays here, verbatim,
// because the JSON cannot carry it. Change a row's value in the list only with new live
// evidence (plan D7: a failing-then-passing sweep receipt).
//
// Gemini thinking (#1770). Every value was verified against the live API on 2026-07-28/29 by
// issuing the real request shape; none is inferred from documentation, which is wrong in both
// directions (it claims Gemini 3 Flash cannot disable thinking — `minimal` measurably spends
// zero thinking tokens — and it lists `gemini-3.1-flash-lite-preview` as withdrawn when it
// returns 200). Every value is the one the Deep-reasoning toggle sent in its OFF position,
// which was the shipped default, so the table was byte-identical on the wire for every user
// who never flipped it. The `deep:` half was removed by #1831 after #1832 measured it: 100
// `topic_shift` cases from `type_b_parakeet`, NOT the 1,462-case `sealed_v1` run; pass rate
// 57.0 / 58.0 / 61.0% for low / medium / high, McNemar exact two-sided p=0.42 for low vs high,
// p90 2.83x; CRITICAL failures moved the other way, 1 -> 2 -> 3. Table:
// `benchmark-results/eval/runs/1832-gemini-thinking-topicshift-2026-08-23/`.
// - Gemini 3 Flash tier (`gemini-3.6-flash`, `3.5-flash`, `3.5-flash-lite`, `3.1-flash-lite`,
//   `3.1-flash-lite-preview`, `3-flash-preview`): `minimal` returns 200 and spends 0 thinking
//   tokens.
// - `gemini-3.7-flash` sits in the Pro tier's shape despite the Flash name: `minimal` -> 400
//   "Thinking level MINIMAL is not supported for this model", verified live 2026-08-16 and
//   confirmed against Google's per-model table (3.7 Flash accepts low/medium/high; 3.6 Flash
//   still accepts minimal). Load-bearing for cost: with no row the Gemini 3 default is
//   `medium`; measured on sealed_v1 at `low`: 147 thinking tokens per dictation, billed at the
//   OUTPUT rate, and the 93.5% score this model was chosen on was measured at `low`.
// - `gemini-3.8-flash` has 3.7 Flash's shape: `minimal` -> 400, `low` accepted, verified live
//   2026-10-03 (#3425). With no row it thought by default: 3.2 to 6.0s and 600 to 1,200
//   thinking tokens per short dictation, against 0.7 to 1.4s and 0 tokens at `low` (3 requests
//   per cell).
// - Gemini 3 Pro tier (`gemini-3.1-pro-preview`, `-customtools`): `minimal` -> 400, so `low`
//   is the floor Google permits.
// - Gemini 2.5 Flash tier (`gemini-2.5-flash`, `-lite`): budget 0 is legal and spends 0
//   thinking tokens. 2.5-flash-lite rejects 128 ("choose a value between 512 and 24576") while
//   accepting 0, which is why the value is per model and not a per-tier rule.
// - `gemini-2.5-pro`: budget 0 -> 400 "This model only works in thinking mode"; 128 is the
//   documented and measured minimum.
// - The five ids that predate thinking (`gemini-1.5-pro`, `1.5-flash`, `1.5-flash-8b`,
//   `2.0-flash`, `2.0-flash-lite`) take no thinking parameter: their rows say `"none"`.
//
// OpenAI reasoning effort (#3425). `none` (the fastest setting) goes to every id the
// 2026-10-03 live probe confirmed returns 200 at `none` (3 requests per cell, short dictation
// text): `gpt-6-luna`, `gpt-6-sol`, `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol`, `gpt-5.5`,
// `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`. Four of them already spent zero reasoning tokens at
// `low`, so for those `none` is a guaranteed floor rather than a measured gain; three requests
// per cell cannot prove that on future dictations. `gpt-6-astra` and `gpt-6.1-sol` REJECT
// `none` (400) and OpenAI documents `low` as their floor, so they stay on `low`. A dated
// snapshot of a listed id gets its alias's value: a snapshot is an immutable copy of the
// alias, the model picker offers snapshots, and the live sweep polishes every offered id.
// Cleanup quality at `none` is NOT VERIFIED: the founder waived the check for speed (#3425).
// The 2026-09 bench scored `gpt-5.4-mini` at `none` lowest of four models.
//
// Claude request shape (#3425). Verified live 2026-10-03: `thinking: disabled` returns 200 on
// `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`, `claude-opus-4-5` through `-4-8`,
// `claude-sonnet-4-5` and `-4-6`. It returns 400 on `claude-sonnet-5-5`, `claude-opus-5-5`,
// `claude-fable-5` and `claude-fable-5-1`, whose 400 bodies name the replacement.
// `between_tools` works only on Sonnet 5.5 (Opus 5.5 rejects it). `output_config.effort:
// "low"` with no `thinking` field returns 200 on Opus 5.5, Fable 5 and Fable 5.1, which think
// regardless; `minimal` is not a legal effort value.

extension LLMModelCapabilities.ThinkingControl {
  /// The thinking value a request sends for this control: the dialect and its value as the
  /// table holds them, nil for `.unsupported`. The one mapping, shared by polish
  /// (`LLMPolishStep.resolveThinking`, whose comment holds the reasons) and the meeting
  /// summary (#3972).
  public var resolved: ResolvedThinking? {
    switch self {
    case .unsupported: return nil
    case .budget(let v): return .budget(v)
    case .level(let v): return .level(v)
    case .effort(let v): return .effort(v)
    }
  }
}

extension ResolvedThinking {
  /// Ollama's thinking value from the daemon's own report for the model: `"low"` only for a
  /// reported thinking model, never `think: false`, nothing when unknown. The one rule, shared
  /// by polish (`LLMPolishStep.ollamaThinking`, whose comment holds the measurements) and the
  /// meeting summary (#3972).
  public static func ollama(thinks: Bool?) -> ResolvedThinking? {
    thinks == true ? .level("low") : nil
  }
}
