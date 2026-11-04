import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Cost bound under founder decision 12): the weekly routine's one
/// owner of CALL COUNTS and reported token USAGE. There is no price table and no dollar
/// ledger; the hard monthly limits on the routine keys bound spending. This owner makes the
/// call count finite before anything is sent, and records what each reply says it used.
///
/// A LOGICAL call is one polish of one dictation with one setting. A PHYSICAL exchange is one
/// HTTP request the connector sends for it (first try, transient retry, or OpenAI strip
/// reissue). Chunks 4-5 wire this owner around the real connectors; until then, connector
/// enforcement is not proven by this file.
enum CloudModelRoutineCalls {

  // MARK: - Limits

  enum Phase: String, Codable, Sendable, Equatable {
    /// The shipped fallback setting, three dictations.
    case fallback
    /// One dictation for an alternative setting in the settings search.
    case screening
    /// The full three dictations for an alternative setting that passed screening.
    case confirmation
  }

  enum Limits {
    /// From the selection policy, not a second copy.
    static let candidatesPerProvider = CloudModelRoutinePolicy.candidateLimitPerProvider
    static let fallbackDictations = 3
    static let screeningsPerSetting = 1
    static let confirmationsPerSetting = 3

    /// D7 Settings search: the search menu minus the fallback setting. OpenAI 8 - 1 = 7,
    /// Gemini 5 - 1 = 4, Claude 3 - 1 = 2. When a model's fallback is outside the menu (a
    /// Gemini budget), this cap still holds, so the search covers the first four menu entries.
    static func alternativeSettings(_ provider: LLMProvider) -> Int {
      max(0, Setting.searchMenu(provider).count - 1)
    }

    /// Physical exchanges one logical call can cause, read from the shipped loops:
    /// - Every connector tries `0...maxRetries` with `LLMRetryPolicy.defaultMaxRetries`
    ///   (OpenAIConnector.swift:181-182, ClaudeConnector.swift:397-398,
    ///   GeminiConnector.swift:521-522): `defaultMaxRetries + 1` attempts.
    /// - OpenAI also reissues inside an attempt after a qualifying 400, at most
    ///   `strippableParams.count` times per attempt (OpenAIConnector.swift:199-235). Each strip
    ///   records the parameter in the process-wide omission memo (`recordOmission`), and the
    ///   next body omits every memoized parameter, so one parameter is stripped at most once
    ///   per logical call: at most `strippableParams.count` reissues in total.
    /// The harness clears the memo only BETWEEN tested settings, never inside a logical call.
    static func physicalPerLogical(_ provider: LLMProvider) -> Int {
      let attempts = LLMRetryPolicy.defaultMaxRetries + 1
      switch provider {
      case .openAI: return attempts + OpenAIConnector.strippableParams.count
      case .gemini, .claude: return attempts
      case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return 0
      }
    }
  }

  // MARK: - Identity

  /// A tested request setting. It can only be built from the list's typed request policy for
  /// the matching provider, with Gemini levels and budgets inside the list's own bounds, so
  /// no other text can become a setting or reach a record.
  struct Setting: Hashable, Encodable, Sendable {
    let provider: LLMProvider
    /// Closed label, such as `openAI:low/omit`, `gemini:level:low`, `claude:effortLow`.
    let label: String

    init?(_ policy: CloudModelList.RequestPolicy, provider: LLMProvider) {
      switch (policy, provider) {
      case (.openAI(let effort, let temperature), .openAI):
        label = "openAI:\(effort.rawValue)/\(temperature == .include ? "include" : "omit")"
      case (.gemini(let thinking), .gemini):
        switch thinking {
        case .none: label = "gemini:none"
        case .level(let level):
          guard CloudModelList.geminiLevels.contains(level) else { return nil }
          label = "gemini:level:\(level)"
        case .budget(let budget):
          guard CloudModelList.geminiBudgetRange.contains(budget) else { return nil }
          label = "gemini:budget:\(budget)"
        }
      case (.claude(let shape), .claude):
        switch shape {
        case .thinkingDisabled: label = "claude:thinkingDisabled"
        case .thinkingBetweenTools: label = "claude:thinkingBetweenTools"
        case .effortLow: label = "claude:effortLow"
        }
      default:
        return nil
      }
      self.provider = provider
    }

    /// The settings search's fixed subset of the closed request menu, in D7 order. The one
    /// owner of that menu; the search (chunk 5) iterates it.
    static func searchMenu(_ provider: LLMProvider) -> [Setting] {
      let policies: [CloudModelList.RequestPolicy]
      switch provider {
      case .openAI:
        policies = [CloudModelList.OpenAIEffort.omit, .none, .minimal, .low].flatMap { effort in
          [LLMModelCapabilities.TemperaturePolicy.include, .omit].map {
            CloudModelList.RequestPolicy.openAI(effort: effort, temperature: $0)
          }
        }
      case .gemini:
        policies =
          [.gemini(thinking: .none)]
          + ["minimal", "low", "medium", "high"].map { .gemini(thinking: .level($0)) }
      case .claude:
        policies = [.thinkingDisabled, .effortLow, .thinkingBetweenTools].map {
          .claude(shape: $0)
        }
      case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
        policies = []
      }
      return policies.compactMap { Setting($0, provider: provider) }
    }
  }

  struct LogicalCallID: Encodable, Hashable, Sendable {
    let provider: LLMProvider
    let model: String
    let setting: Setting
    let phase: Phase
    /// Index into the fixed dictation inputs (0, 1 or 2).
    let input: Int
  }

  struct PhysicalExchangeID: Encodable, Hashable, Sendable {
    let call: LogicalCallID
    /// 1-based position among this logical call's physical exchanges.
    let attempt: Int
  }

  // MARK: - Usage

  /// Token usage exactly as the reply reported it. A field the reply did not report is nil,
  /// never zero. No price and no dollar figure is derived here.
  struct Usage: Codable, Equatable, Sendable {
    let input: Int?
    let output: Int?
    let thinking: Int?
    /// True when the provider counts thinking INSIDE `output` (OpenAI `reasoning_tokens`,
    /// Anthropic `thinking_tokens`); false when it reports thinking separately and bills it in
    /// addition (Gemini `thoughtsTokenCount`).
    let thinkingIncludedInOutput: Bool
  }

  enum UsageReading: Encodable, Equatable, Sendable {
    case reported(Usage)
    /// The reply is JSON but carries no usage object.
    case absent
    /// The reply is not JSON, or its usage object or a count in it is not a non-negative
    /// whole number. Never read as a measurement.
    case malformed
  }

  /// Usage from one complete non-streamed reply body. Field meanings (verified 2026-11-04):
  /// - OpenAI chat completions `usage.prompt_tokens`, `completion_tokens`,
  ///   `completion_tokens_details.reasoning_tokens`; reasoning is counted within completion
  ///   tokens (developers.openai.com/api/reference/resources/chat/subresources/completions).
  /// - Anthropic Messages `usage.input_tokens`, `output_tokens`,
  ///   `output_tokens_details.thinking_tokens`, always <= output
  ///   (platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost).
  /// - Gemini `usageMetadata.promptTokenCount`, `candidatesTokenCount`, `thoughtsTokenCount`;
  ///   thinking is reported separately and response pricing is output plus thinking
  ///   (ai.google.dev/gemini-api/docs/generate-content/tokens).
  static func usage(provider: LLMProvider, body: Data) -> UsageReading {
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      return .malformed
    }
    let (key, input, output, details, thinking, included):
      (
        String, String, String, String?, String, Bool
      )
    switch provider {
    case .openAI:
      (key, input, output, details, thinking, included) = (
        "usage", "prompt_tokens", "completion_tokens", "completion_tokens_details",
        "reasoning_tokens", true
      )
    case .claude:
      (key, input, output, details, thinking, included) = (
        "usage", "input_tokens", "output_tokens", "output_tokens_details", "thinking_tokens",
        true
      )
    case .gemini:
      (key, input, output, details, thinking, included) = (
        "usageMetadata", "promptTokenCount", "candidatesTokenCount", nil, "thoughtsTokenCount",
        false
      )
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return .malformed
    }
    guard let raw = root[key] else { return .absent }
    guard let usage = raw as? [String: Any] else { return .malformed }
    var thinkingSource: [String: Any]? = usage
    if let details {
      switch usage[details] {
      case nil: thinkingSource = nil
      case let object as [String: Any]: thinkingSource = object
      default: return .malformed
      }
    }
    return build(usage, input, output, thinkingSource, thinking, included)
  }

  private static func build(
    _ usage: [String: Any], _ input: String, _ output: String, _ thinkingSource: [String: Any]?,
    _ thinking: String, _ included: Bool
  ) -> UsageReading {
    guard let inputCount = count(usage[input]), let outputCount = count(usage[output]),
      let thinkingCount = count(thinkingSource?[thinking])
    else { return .malformed }
    if included, let t = thinkingCount, let o = outputCount, t > o { return .malformed }
    return .reported(
      Usage(
        input: inputCount, output: outputCount, thinking: thinkingCount,
        thinkingIncludedInOutput: included))
  }

  /// `.some(nil)` for a missing field, `.some(n)` for a non-negative whole JSON number, and
  /// `nil` (refuse) for anything else, including booleans and fractions.
  private static func count(_ value: Any?) -> Int?? {
    guard let value else { return .some(nil) }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double == double.rounded(),
      double <= Double(Int32.max)
    else { return nil }
    return .some(Int(double))
  }

  // MARK: - Records

  /// What one physical exchange came to. Closed, so no provider text survives.
  enum ExchangeOutcome: Encodable, Equatable, Sendable {
    /// An HTTP reply with this status. Its usage reading is recorded beside it.
    case replied(status: Int)
    /// No reply: transport failure, timeout or cancellation.
    case noReply
  }

  struct ExchangeRecord: Encodable, Equatable, Sendable {
    let id: PhysicalExchangeID
    let outcome: ExchangeOutcome
    /// nil when there was no reply; otherwise what the reply's usage was: reported, absent
    /// or malformed, kept apart.
    let usage: UsageReading?
  }

  // MARK: - Ledger

  enum Refusal: Error, Equatable {
    case unsupportedProvider
    /// A setting for another provider, or a search setting outside the search menu. Carries
    /// no value, so a bad setting is never echoed.
    case invalidSetting
    case candidateLimit(provider: LLMProvider)
    case inputOutOfRange(Int)
    case phaseLimit(LogicalCallID)
    case settingLimit(provider: LLMProvider, model: String)
    case physicalLimit(LogicalCallID)
    case unknownLogicalCall
    case unknownOrRecordedExchange
  }

  /// Per serialized run. Admission happens BEFORE a request is sent; a refused admission
  /// means the request must not be sent. Not thread-safe: one run drives it in order.
  struct Ledger: Sendable {
    private(set) var admitted: [LogicalCallID] = []
    private(set) var records: [ExchangeRecord] = []
    private var physicalIssued: [LogicalCallID: Int] = [:]
    private var openExchanges: Set<PhysicalExchangeID> = []

    /// Admit one logical call. Re-admitting the same id grants nothing new and counts once.
    mutating func admit(_ call: LogicalCallID) throws {
      if admitted.contains(call) { return }
      guard Limits.physicalPerLogical(call.provider) > 0 else {
        throw Refusal.unsupportedProvider
      }
      guard call.setting.provider == call.provider,
        call.phase == .fallback || Setting.searchMenu(call.provider).contains(call.setting)
      else { throw Refusal.invalidSetting }
      let models = Set(admitted.filter { $0.provider == call.provider }.map(\.model))
      if !models.contains(call.model), models.count >= Limits.candidatesPerProvider {
        throw Refusal.candidateLimit(provider: call.provider)
      }
      let perPhaseInputs: Int
      switch call.phase {
      case .fallback: perPhaseInputs = Limits.fallbackDictations
      case .screening: perPhaseInputs = Limits.screeningsPerSetting
      case .confirmation: perPhaseInputs = Limits.confirmationsPerSetting
      }
      guard (0..<Limits.fallbackDictations).contains(call.input) else {
        throw Refusal.inputOutOfRange(call.input)
      }
      let samePhase = admitted.filter {
        $0.provider == call.provider && $0.model == call.model && $0.setting == call.setting
          && $0.phase == call.phase
      }
      if samePhase.count >= perPhaseInputs { throw Refusal.phaseLimit(call) }
      // One fallback setting per model: the fallback is the shipped setting, not a search.
      if call.phase == .fallback,
        admitted.contains(where: {
          $0.provider == call.provider && $0.model == call.model && $0.phase == .fallback
            && $0.setting != call.setting
        })
      {
        throw Refusal.settingLimit(provider: call.provider, model: call.model)
      }
      if call.phase != .fallback {
        let alternatives = Set(
          admitted.filter {
            $0.provider == call.provider && $0.model == call.model && $0.phase != .fallback
          }.map(\.setting))
        if !alternatives.contains(call.setting),
          alternatives.count >= Limits.alternativeSettings(call.provider)
        {
          throw Refusal.settingLimit(provider: call.provider, model: call.model)
        }
      }
      admitted.append(call)
    }

    /// Permission for the next physical exchange of an admitted logical call; ask before
    /// sending. Each grant is a distinct exchange.
    mutating func admitExchange(for call: LogicalCallID) throws -> PhysicalExchangeID {
      guard admitted.contains(call) else { throw Refusal.unknownLogicalCall }
      let issued = physicalIssued[call, default: 0]
      guard issued < Limits.physicalPerLogical(call.provider) else {
        throw Refusal.physicalLimit(call)
      }
      physicalIssued[call] = issued + 1
      let id = PhysicalExchangeID(call: call, attempt: issued + 1)
      openExchanges.insert(id)
      return id
    }

    /// Record a granted exchange's outcome exactly once.
    mutating func record(
      _ id: PhysicalExchangeID, outcome: ExchangeOutcome, usage: UsageReading?
    ) throws {
      guard openExchanges.remove(id) != nil else { throw Refusal.unknownOrRecordedExchange }
      let reading: UsageReading?
      switch outcome {
      case .noReply:
        reading = nil
      case .replied:
        reading = usage ?? .malformed
      }
      records.append(ExchangeRecord(id: id, outcome: outcome, usage: reading))
    }

    var logicalCount: Int { admitted.count }
    var physicalCount: Int { physicalIssued.values.reduce(0, +) }
    /// Granted exchanges never recorded (a crash or a lost reply): they still count.
    var unrecordedCount: Int { openExchanges.count }
  }
}
