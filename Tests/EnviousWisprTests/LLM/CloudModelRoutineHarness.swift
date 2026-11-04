import CryptoKit
import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #4353 PR 5 (D7 detail, Stage 1 harness): the weekly cloud model routine's fallback sweep.
///
/// It reads each provider's complete catalog (Chunk 1), applies absence history and picks new
/// models (Chunk 2), then polishes three fixed real dictations per picked model through the
/// SHIPPED connectors with the SHIPPED request policy for that id. Every physical request goes
/// through the call ledger (Chunk 3) first. The settings search lives in
/// `CloudModelRoutineSearch.swift`.
enum CloudModelRoutine {

  // MARK: - Inputs and keys

  /// The three fixed dictations, by index into `LiveSweepSupport.realDictations`. The ids are
  /// stable; the settings search reuses them.
  static let inputIndices = [0, 1, 2]

  struct Input: Sendable {
    let id: String
    let text: String
  }

  static var inputs: [Input] {
    inputIndices.map {
      Input(id: "realDictations[\($0)]", text: LiveSweepSupport.realDictations[$0])
    }
  }

  /// The routine's three key variables, read inside the test process (the runner passes them
  /// as `TEST_RUNNER_EW_ROUTINE_*`, and Xcode strips the prefix).
  enum KeyVariable: String, CaseIterable, Encodable, Sendable {
    case openAI = "EW_ROUTINE_OPENAI_KEY"
    case claude = "EW_ROUTINE_CLAUDE_KEY"
    case gemini = "EW_ROUTINE_GEMINI_KEY"

    var provider: LLMProvider {
      switch self {
      case .openAI: return .openAI
      case .claude: return .claude
      case .gemini: return .gemini
      }
    }
  }

  struct Keys: Sendable {
    let values: [LLMProvider: String]

    /// All three keys or the list of missing variable NAMES (never values).
    static func from(environment: [String: String]) -> Result<Keys, MissingKeys> {
      var values: [LLMProvider: String] = [:]
      var missing: [KeyVariable] = []
      for variable in KeyVariable.allCases {
        if let value = environment[variable.rawValue], !value.isEmpty {
          values[variable.provider] = value
        } else {
          missing.append(variable)
        }
      }
      return missing.isEmpty
        ? .success(Keys(values: values)) : .failure(MissingKeys(variables: missing))
    }

    /// An in-memory `.legacyFiles` store with no telemetry: never the production Keychain and
    /// never the dev file store fallback.
    var keychain: KeychainManager {
      KeychainManager(
        backend: .legacyFiles,
        legacyStore: EnvironmentKeyStore(values: [
          KeychainManager.openAIKeyID: values[.openAI] ?? "",
          KeychainManager.claudeKeyID: values[.claude] ?? "",
          KeychainManager.geminiKeyID: values[.gemini] ?? "",
        ]),
        telemetrySink: .noop)
    }
  }

  struct MissingKeys: Error, Equatable {
    let variables: [KeyVariable]
  }

  static func keyID(_ provider: LLMProvider) -> String? {
    switch provider {
    case .openAI: return KeychainManager.openAIKeyID
    case .claude: return KeychainManager.claudeKeyID
    case .gemini: return KeychainManager.geminiKeyID
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return nil
    }
  }

  // MARK: - Transports

  typealias Executor = @Sendable (URLRequest, LLMTaskMetricsCollector) async throws -> (
    Data, URLResponse
  )

  /// Where requests go. `live` is the shared session; tests script both.
  struct Transports: Sendable {
    let catalog: LLMModelDiscovery.Transport
    let polish: @Sendable (LLMProvider) -> Executor

    static let live = Transports(
      catalog: { request in try await LLMNetworkSession.shared.session.data(for: request) },
      polish: { _ in
        { request, collector in
          try await LLMNetworkSession.shared.session.data(for: request, delegate: collector)
        }
      })
  }

  // MARK: - Physical boundary

  /// The ledger plus the logical call in progress. Every physical send asks it first; a
  /// refusal throws before the inner executor runs, and that error is not retryable
  /// (`LLMRetryPolicy.isRetryable` returns false for it), so it ends the logical call.
  final class Meter: @unchecked Sendable {
    struct Refused: Error, Equatable {}

    private let lock = NSLock()
    private var ledger = CloudModelRoutineCalls.Ledger()
    private var current: CloudModelRoutineCalls.LogicalCallID?
    private(set) var refusals = 0
    /// Allowlisted request-policy facts per granted exchange, in send order: which strippable
    /// OpenAI parameters the body carried. No header and no other body field is kept.
    private var evidence: [PhysicalRequestEvidence] = []

    var requestEvidence: [PhysicalRequestEvidence] { lock.withLock { evidence } }

    func begin(_ call: CloudModelRoutineCalls.LogicalCallID) throws {
      try lock.withLock {
        do {
          try ledger.admit(call)
          current = call
        } catch {
          refusals += 1
          current = nil
          throw Refused()
        }
      }
    }

    func end() { lock.withLock { current = nil } }

    var snapshot: CloudModelRoutineCalls.Ledger { lock.withLock { ledger } }

    func wrap(_ inner: @escaping Executor, provider: LLMProvider) -> Executor {
      { [self] request, collector in
        let exchange: CloudModelRoutineCalls.PhysicalExchangeID = try lock.withLock {
          guard let call = current, call.provider == provider else {
            refusals += 1
            throw Refused()
          }
          do {
            return try ledger.admitExchange(for: call)
          } catch {
            refusals += 1
            throw Refused()
          }
        }
        let params = Self.strippableParamsSent(request, provider: provider)
        lock.withLock {
          evidence.append(PhysicalRequestEvidence(id: exchange, sentOpenAIParams: params))
        }
        do {
          let (data, response) = try await inner(request, collector)
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          // Recorded before the connector parses the reply, so a parse failure keeps it.
          try lock.withLock {
            try ledger.record(
              exchange, outcome: .replied(status: status),
              usage: CloudModelRoutineCalls.usage(provider: provider, body: data))
          }
          return (data, response)
        } catch let error as CloudModelRoutineCalls.Refusal {
          throw error
        } catch {
          try? lock.withLock { try ledger.record(exchange, outcome: .noReply, usage: nil) }
          throw error
        }
      }
    }

    static func strippableParamsSent(_ request: URLRequest, provider: LLMProvider) -> [String] {
      guard provider == .openAI, let body = request.httpBody,
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
      else { return [] }
      return OpenAIConnector.strippableParams.filter { object[$0] != nil }.sorted()
    }
  }

  /// What one physical request carried, from the strippable-parameter allowlist only.
  struct PhysicalRequestEvidence: Encodable, Equatable, Sendable {
    let id: CloudModelRoutineCalls.PhysicalExchangeID
    let sentOpenAIParams: [String]
  }

  static func connector(
    _ provider: LLMProvider, keychain: KeychainManager, list: CloudModelList,
    executor: @escaping Executor
  ) -> (any TranscriptPolisher)? {
    switch provider {
    case .openAI:
      return OpenAIConnector(
        keychainManager: keychain, cloudModelList: list, requestExecutor: executor)
    case .claude:
      return ClaudeConnector(
        keychainManager: keychain, cloudModelList: list, requestExecutor: executor)
    case .gemini:
      return GeminiConnector(keychainManager: keychain, requestExecutor: executor)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return nil
    }
  }

  // MARK: - Fallback setting and equivalent row

  /// The list request policy that states exactly what the compiled rules send for an unlisted
  /// id. Nil when the compiled answer has no list spelling (then the candidate is not tried).
  static func fallbackPolicy(
    _ provider: LLMProvider, capabilities: LLMModelCapabilities
  ) -> CloudModelList.RequestPolicy? {
    switch provider {
    case .openAI:
      let effort: CloudModelList.OpenAIEffort
      switch capabilities.thinkingControl {
      // Unsupported thinking sends no `reasoning_effort` key: "omit", never "none".
      case .unsupported: effort = .omit
      case .effort(let value):
        guard let parsed = CloudModelList.OpenAIEffort(rawValue: value), parsed != .omit else {
          return nil
        }
        effort = parsed
      case .budget, .level: return nil
      }
      return .openAI(effort: effort, temperature: capabilities.temperaturePolicy)
    case .gemini:
      switch capabilities.thinkingControl {
      case .unsupported: return .gemini(thinking: .none)
      case .budget(let value): return .gemini(thinking: .budget(value))
      case .level(let value): return .gemini(thinking: .level(value))
      case .effort: return nil
      }
    case .claude:
      return .claude(shape: capabilities.claudeRequestShape)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return nil
    }
  }

  /// A request policy as the list writes it.
  enum RequestJSON: Encodable, Equatable, Sendable {
    case openAI(effort: String, temperature: String)
    case gemini(none: Bool, budget: Int?, level: String?)
    case claude(shape: String)

    init(_ policy: CloudModelList.RequestPolicy) {
      switch policy {
      case .openAI(let effort, let temperature):
        self = .openAI(
          effort: effort.rawValue, temperature: temperature == .include ? "include" : "omit")
      case .gemini(let thinking):
        switch thinking {
        case .none: self = .gemini(none: true, budget: nil, level: nil)
        case .budget(let value): self = .gemini(none: false, budget: value, level: nil)
        case .level(let value): self = .gemini(none: false, budget: nil, level: value)
        }
      case .claude(let shape):
        switch shape {
        case .thinkingDisabled: self = .claude(shape: "thinkingDisabled")
        case .thinkingBetweenTools: self = .claude(shape: "thinkingBetweenTools")
        case .effortLow: self = .claude(shape: "effortLow")
        }
      }
    }

    private struct Key: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(_ value: String) { stringValue = value }
      init?(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: Key.self)
      switch self {
      case .openAI(let effort, let temperature):
        try container.encode(effort, forKey: Key("openAIEffort"))
        try container.encode(temperature, forKey: Key("temperature"))
      case .gemini(_, let budget?, _):
        var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key("geminiThinking"))
        try nested.encode(budget, forKey: Key("budget"))
      case .gemini(_, _, let level?):
        var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key("geminiThinking"))
        try nested.encode(level, forKey: Key("level"))
      case .gemini:
        try container.encode("none", forKey: Key("geminiThinking"))
      case .claude(let shape):
        try container.encode(shape, forKey: Key("claudeShape"))
      }
    }
  }

  /// A complete list row in the list's own field names. `displayName` is never written, so
  /// the menu keeps today's label.
  struct ProposedRow: Encodable, Equatable, Sendable {
    let provider: String
    let id: String
    let released: String?
    let recommended: Bool
    let hidden: Bool
    let request: RequestJSON
    let supportsChatCompletions: Bool
    let allowsFileBatch: Bool
    let medianPolishMs: Int?
  }

  /// A provider's own date as a list day (UTC), or nil when absent or outside the list's
  /// 2000-2099 range. Never the scan date and never a date read from the id.
  static func releasedDay(_ date: Date?) -> String? {
    guard let date else { return nil }
    let day = CloudModelRoutinePolicy.utcDay(of: date)
    guard let year = Int(day.prefix(4)), (2000...2099).contains(year) else { return nil }
    return day
  }

  /// The captured list with `row` appended, validated by the shipped contract.
  static func listAdding(_ row: ProposedRow, to list: CloudModelList) throws -> CloudModelList {
    guard
      var document = try JSONSerialization.jsonObject(with: list.documentBytes) as? [String: Any],
      var models = document["models"] as? [Any]
    else { throw HarnessFailure.listUnreadable }
    let rowObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
    models.append(rowObject)
    document["models"] = models
    let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    switch CloudModelList.validated(from: bytes) {
    case .success(let proposed): return proposed
    case .failure: throw HarnessFailure.rowRejectedByContract
    }
  }

  /// The proposed list resolves the same request policy and file batching as today, for the
  /// id and for both supported dated spellings of it.
  static func resolvesTheSame(
    _ provider: LLMProvider, id: String, before: CloudModelList, after: CloudModelList
  ) -> Bool {
    [id, "\(id)-2030-01-01", "\(id)-20300101"].allSatisfy { variant in
      provider.modelCapabilities(model: variant, list: before)
        == provider.modelCapabilities(model: variant, list: after)
        && provider.allowsFileBatch(model: variant, list: before)
          == provider.allowsFileBatch(model: variant, list: after)
    }
  }

  enum HarnessFailure: Error, Equatable {
    case listUnreadable
    case rowRejectedByContract
    case secretInOutput
  }

  // MARK: - Outcomes

  enum ErrorClass: String, Encodable, Sendable {
    /// The connector's final error was `LLMError.classified(.badRequest)`: the settings
    /// search starts.
    case requestRejected
    case notAvailable
    case keyRejected
    case quotaOrRate
    case transient
    case unusableOutput
    case harnessRefused
    case other
  }

  static func errorClass(_ error: Error) -> ErrorClass {
    if error is Meter.Refused { return .harnessRefused }
    if error is URLError { return .transient }
    // Catalog reads (`fetchCatalog`) fail with discovery's own errors.
    if let discovery = error as? ModelDiscoveryFailure {
      switch discovery {
      case .httpStatus(let code) where code == 429: return .quotaOrRate
      case .httpStatus(let code) where (500...599).contains(code): return .transient
      case .network: return .transient
      // Text-only `API_KEY_INVALID` is not proof the key was refused (LLMModelDiscovery.geminiFailure).
      case .invalidKeyUnconfirmed: return .other
      case .permissionDenied: return .notAvailable
      default: return .other
      }
    }
    guard let llm = error as? LLMError else { return .other }
    switch llm {
    case .classified(let reason):
      switch reason {
      case .badRequest: return .requestRejected
      case .modelUnavailable, .accessDenied: return .notAvailable
      case .apiKeyMissing, .apiKeyUnreadable, .apiKeyRejected: return .keyRejected
      case .outOfCredits, .rateLimited, .rateLimitedOrQuota: return .quotaOrRate
      case .providerUnreachable, .providerServerError: return .transient
      case .emptyResponse: return .unusableOutput
      default: return .other
      }
    case .invalidAPIKey: return .keyRejected
    case .emptyResponse: return .unusableOutput
    case .modelNotFound: return .notAvailable
    default: return .other
    }
  }
}
