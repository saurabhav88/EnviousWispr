import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Stage 1 harness): the routine's fallback sweep, driven offline.
/// Scripted vendors answer catalog reads and polish requests through the shipped connectors'
/// transport seams; nothing can reach a real provider, and the keys are fakes.
@Suite("Cloud model routine fallback sweep (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutineHarnessTests {

  static let keys = CloudModelRoutine.Keys(values: [
    .openAI: "fake-openai-key-41f0", .claude: "fake-claude-key-82aa",
    .gemini: "fake-gemini-key-c3d9",
  ])
  static let observedAt = Date(timeIntervalSince1970: 1_793_750_400)  // 2026-11-04 00:00 UTC
  static var seed: CloudModelList { CloudModelListSeed.current! }

  // MARK: - Scripted vendors

  /// Catalog replies by URL; polish replies from a responder that sees the provider and the
  /// request. Unknown requests throw. Every request is recorded.
  final class Vendors: @unchecked Sendable {
    struct Unexpected: Error {}
    typealias Responder = @Sendable (LLMProvider, URLRequest, Int) -> (Int, String)

    private let lock = NSLock()
    private var catalogs: [String: (Int, String)] = [:]
    private var polishCounts: [LLMProvider: Int] = [:]
    private(set) var log: [String] = []
    var responder: Responder = Vendors.echo

    func catalog(_ url: String, status: Int = 200, json: String) {
      lock.withLock { catalogs[url] = (status, json) }
    }

    var polishRequests: [String] { lock.withLock { log.filter { $0.hasPrefix("POST") } } }

    var transports: CloudModelRoutine.Transports {
      CloudModelRoutine.Transports(
        catalog: { [self] request in
          let url = request.url!.absoluteString
          let reply: (Int, String)? = lock.withLock {
            log.append("GET \(url)")
            return catalogs[url]
          }
          guard let reply else { throw Unexpected() }
          return (Data(reply.1.utf8), Self.response(url, reply.0))
        },
        polish: { [self] provider in
          { [self] request, _ in
            let url = request.url!.absoluteString
            let (count, respond): (Int, Responder) = lock.withLock {
              log.append("POST \(url)")
              polishCounts[provider, default: 0] += 1
              return (polishCounts[provider]!, responder)
            }
            let (status, body) = respond(provider, request, count)
            return (Data(body.utf8), Self.response(url, status))
          }
        })
    }

    static func response(_ url: String, _ status: Int) -> HTTPURLResponse {
      HTTPURLResponse(
        url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func json(_ object: Any) -> String {
      String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// The dictation the request carries, polished back unchanged.
    static func inputText(_ request: URLRequest) -> String {
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      return CloudModelRoutine.inputs.first { body.contains($0.text) }?.text ?? "unknown input"
    }

    static func success(_ provider: LLMProvider, text: String) -> String {
      switch provider {
      case .openAI:
        return json([
          "choices": [["message": ["content": text], "finish_reason": "stop"]],
          "usage": ["prompt_tokens": 900, "completion_tokens": 40],
        ])
      case .claude:
        return json([
          "content": [["type": "text", "text": text]], "stop_reason": "end_turn",
          "usage": ["input_tokens": 900, "output_tokens": 40],
        ])
      default:
        return json([
          "candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]],
          "usageMetadata": ["promptTokenCount": 900, "candidatesTokenCount": 40],
        ])
      }
    }

    static let echo: Responder = { provider, request, _ in
      (200, success(provider, text: inputText(request)))
    }
  }

  static let openAIModels = "https://api.openai.com/v1/models"
  static let claudeModels = "https://api.anthropic.com/v1/models?limit=1000"
  static let geminiModels =
    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"

  /// Every listed id present, plus excluded ids and one new model per provider (OpenAI's also
  /// with a dated copy, which yields to it).
  static func vendorsWithNewModels() -> Vendors {
    let vendors = Vendors()
    let listed = { (provider: LLMProvider) in
      seed.models.filter { $0.provider == provider }.map(\.id)
    }
    let openAI: [[String: Any]] =
      listed(.openAI).map { ["id": $0] }
      + [
        ["id": "gpt-9-zeta", "created": 1_790_812_800], ["id": "gpt-9-zeta-2026-10-01"],
        ["id": "dall-e-9"], ["id": "gpt-9-tts"],
      ]
    vendors.catalog(openAIModels, json: Vendors.json(["data": openAI]))
    let claude: [[String: Any]] =
      listed(.claude).map { ["id": $0] }
      + [
        [
          "id": "claude-zeta-9", "display_name": "Claude Zeta 9",
          "created_at": "2026-10-20T00:00:00Z",
        ]
      ]
    vendors.catalog(claudeModels, json: Vendors.json(["data": claude, "has_more": false]))
    let gemini: [[String: Any]] =
      (listed(.gemini) + ["gemini-9-flash"]).map {
        [
          "name": "models/\($0)", "displayName": $0,
          "supportedGenerationMethods": ["generateContent"],
        ]
      }
    vendors.catalog(geminiModels, json: Vendors.json(["models": gemini]))
    return vendors
  }

  static func run(_ vendors: Vendors, history: CloudModelRoutinePolicy.AbsenceHistory = .init())
    async -> CloudModelRoutineReceipt
  {
    await CloudModelRoutine.run(
      keys: keys, list: seed, history: history, observedAt: observedAt,
      transports: vendors.transports, provenance: .from(environment: [:]))
  }

  static func candidates(_ receipt: CloudModelRoutineReceipt, _ provider: LLMProvider)
    -> [CloudModelRoutineReceipt.CandidateResult]
  {
    receipt.providers.first { $0.provider == provider.rawValue }?.candidates ?? []
  }

  // MARK: - Keys

  @Test("all three routine keys are required; the missing ones are named, never shown")
  func missingKeys() {
    let result = CloudModelRoutine.Keys.from(environment: ["EW_ROUTINE_OPENAI_KEY": "x"])
    #expect(result.failure == CloudModelRoutine.MissingKeys(variables: [.claude, .gemini]))
    let empty = CloudModelRoutine.Keys.from(environment: ["EW_ROUTINE_OPENAI_KEY": ""])
    #expect(empty.failure?.variables == [.openAI, .claude, .gemini])
    let all = CloudModelRoutine.Keys.from(environment: [
      "EW_ROUTINE_OPENAI_KEY": "a", "EW_ROUTINE_CLAUDE_KEY": "b", "EW_ROUTINE_GEMINI_KEY": "c",
    ])
    #expect(all.success?.values == [.openAI: "a", .claude: "b", .gemini: "c"])
  }

  // MARK: - Whole run

  @Test("only the new models are polished: three dictations each, rows proposed, no key leaks")
  func newModelsOnly() async throws {
    let vendors = Self.vendorsWithNewModels()
    let receipt = await Self.run(vendors)

    #expect(receipt.outcome == "success")
    #expect(vendors.polishRequests.count == 9)
    #expect(receipt.logicalCalls == 9)
    #expect(receipt.physicalExchanges == 9)
    #expect(receipt.unrecordedExchanges == 0)
    #expect(receipt.refusals == 0)
    #expect(Self.candidates(receipt, .openAI).map(\.id) == ["gpt-9-zeta"])
    #expect(Self.candidates(receipt, .claude).map(\.id) == ["claude-zeta-9"])
    #expect(Self.candidates(receipt, .gemini).map(\.id) == ["gemini-9-flash"])
    let openAI = try #require(receipt.providers.first { $0.provider == "openAI" })
    #expect(openAI.dispositions["gpt-9-zeta-2026-10-01"] == "suppressedDatedCopy")
    // `dall-e-9` and the listed `chatgpt-4o-latest`.
    #expect(openAI.excluded["notChatTextFamily"] == 2)
    #expect(openAI.excluded["excludedPattern"] == 1)
    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let result = try #require(Self.candidates(receipt, provider).first)
      #expect(result.outcome == "pass", "\(provider)")
      #expect(result.perInputMs.count == 3, "\(provider)")
      #expect(result.resolvesTheSame == true, "\(provider)")
      #expect(result.row?.recommended == false)
      #expect(result.row?.hidden == false)
    }
    // Provider dates become list days; Gemini gives none.
    #expect(Self.candidates(receipt, .openAI).first?.row?.released == "2026-10-01")
    #expect(Self.candidates(receipt, .claude).first?.row?.released == "2026-10-20")
    #expect(Self.candidates(receipt, .gemini).first?.row?.released == nil)
    // Every listed row was in the catalog.
    #expect(
      receipt.providers.allSatisfy {
        $0.absence.values.allSatisfy { $0.state != "missingForRoutineKey" }
      })
    // Usage recorded per exchange.
    #expect(
      receipt.calls.allSatisfy {
        if case .reported(let usage)? = $0.usage { return usage.input == 900 && usage.output == 40 }
        return false
      })
    let data = try receipt.encoded(refusing: Array(Self.keys.values.values))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(CloudModelRoutine.inputs[0].text) == false)
    #expect(text.contains(#""publicationReady" : false"#))
  }

  @Test("the proposed row is the complete fallback the compiled rules send today")
  func proposedRowIsTheFallback() async throws {
    let receipt = await Self.run(Self.vendorsWithNewModels())
    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let result = try #require(Self.candidates(receipt, provider).first)
      let row = try #require(result.row)
      let capabilities = provider.modelCapabilities(model: row.id, list: Self.seed)
      let policy = try #require(
        CloudModelRoutine.fallbackPolicy(provider, capabilities: capabilities))
      #expect(row.request == CloudModelRoutine.RequestJSON(policy))
      #expect(row.supportsChatCompletions == capabilities.supportsChatCompletions)
      #expect(row.allowsFileBatch == provider.allowsFileBatch(model: row.id, list: Self.seed))
      #expect(result.setting == CloudModelRoutineCalls.Setting(policy, provider: provider)?.label)
    }
  }

  @Test("unsupported OpenAI thinking is written as omit, never none")
  func openAIUnsupportedThinkingIsOmit() throws {
    let capabilities = LLMModelCapabilities(
      thinkingControl: .unsupported, temperaturePolicy: .include, supportsChatCompletions: true)
    let policy = try #require(CloudModelRoutine.fallbackPolicy(.openAI, capabilities: capabilities))
    #expect(
      CloudModelRoutine.RequestJSON(policy) == .openAI(effort: "omit", temperature: "include"))
    let encoded = String(
      decoding: try JSONEncoder().encode(CloudModelRoutine.RequestJSON(policy)), as: UTF8.self)
    #expect(encoded.contains(#""openAIEffort":"omit""#))
  }

  @Test("a final bad request is recorded as requestRejected; no row, no search")
  func requestRejected() async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.responder = { provider, request, _ in
      if provider == .claude {
        return (
          400,
          #"{"type":"error","error":{"type":"invalid_request_error","message":"bad shape \#(Self.keys.values[.claude]!)"}}"#
        )
      }
      return Vendors.echo(provider, request, 0)
    }
    let receipt = await Self.run(vendors)
    let claude = try #require(Self.candidates(receipt, .claude).first)
    #expect(claude.outcome == "fail")
    #expect(claude.errorClass == .requestRejected)
    #expect(claude.row == nil)
    #expect(receipt.outcome == "partial")
    // A 400 is not retried and the sweep stops at the first failed dictation.
    #expect(vendors.polishRequests.filter { $0.contains("anthropic") }.count == 1)
    // The key in the error body never reaches the receipt.
    _ = try receipt.encoded(refusing: Array(Self.keys.values.values))
  }

  @Test("an OpenAI success after a parameter strip is a pass via adaptation with the unchanged row")
  func openAIAdaptation() async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.responder = { provider, request, count in
      guard provider == .openAI else { return Vendors.echo(provider, request, count) }
      let body =
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        ?? [:]
      if let param = ["temperature", "reasoning_effort"].first(where: { body[$0] != nil }) {
        return (
          400,
          Vendors.json([
            "error": [
              "message": "Unsupported parameter", "type": "invalid_request_error", "param": param,
              "code": "unsupported_parameter",
            ]
          ])
        )
      }
      return Vendors.echo(provider, request, count)
    }
    let capabilities = LLMProvider.openAI.modelCapabilities(model: "gpt-9-zeta", list: Self.seed)
    let sendsAParam =
      capabilities.temperaturePolicy == .include
      || { if case .effort = capabilities.thinkingControl { return true } else { return false } }()
    try #require(sendsAParam, "gpt-9-zeta's compiled request must carry a strippable parameter")
    let receipt = await Self.run(vendors)
    let result = try #require(Self.candidates(receipt, .openAI).first)
    #expect(result.outcome == "pass")
    #expect(result.passViaAdaptation == true)
    let policy = try #require(CloudModelRoutine.fallbackPolicy(.openAI, capabilities: capabilities))
    #expect(result.row?.request == CloudModelRoutine.RequestJSON(policy))
    // More physical exchanges than logical calls: the strips were counted.
    let openAICalls = receipt.calls.filter { $0.id.call.provider == .openAI }
    #expect(openAICalls.count > 3)
    #expect(
      openAICalls.allSatisfy {
        $0.id.attempt <= CloudModelRoutineCalls.Limits.physicalPerLogical(.openAI)
      })
  }

  @Test("a failed catalog proposes nothing, sends no polish and keeps that provider's history")
  func failedCatalog() async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.catalog(Self.geminiModels, status: 500, json: "{}")
    let receipt = await Self.run(vendors)
    let gemini = try #require(receipt.providers.first { $0.provider == "gemini" })
    #expect(gemini.catalog == "failed")
    #expect(gemini.candidates.isEmpty)
    #expect(vendors.polishRequests.contains { $0.contains("generativelanguage") } == false)
    #expect(receipt.history.latestObservedAt["gemini"] == nil)
    #expect(receipt.history.latestObservedAt["openAI"] == Self.observedAt)
    #expect(receipt.outcome == "failure")
  }

  @Test("a listed model missing from a complete catalog starts its absence history")
  func absenceRecorded() async throws {
    let vendors = Self.vendorsWithNewModels()
    let claudeIDs = Self.seed.models.filter { $0.provider == .claude && !$0.hidden }.map(\.id)
    let gone = try #require(claudeIDs.first)
    let kept = claudeIDs.dropFirst().map { ["id": $0] as [String: Any] }
    vendors.catalog(Self.claudeModels, json: Vendors.json(["data": kept, "has_more": false]))
    let receipt = await Self.run(vendors)
    let claude = try #require(receipt.providers.first { $0.provider == "claude" })
    #expect(
      claude.absence[gone] == .init(.missingForRoutineKey(firstMissingDay: "2026-11-04", weeks: 1)))
    #expect(receipt.history.entries.map(\.id).contains(gone))
  }

  // MARK: - Receipt evidence

  static func json(_ receipt: CloudModelRoutineReceipt, refusing: [String] = []) throws -> [String:
    Any]
  {
    let data = try receipt.encoded(refusing: refusing)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func providerJSON(_ root: [String: Any], _ provider: String) -> [String: Any]? {
    (root["providers"] as? [[String: Any]])?.first { $0["provider"] as? String == provider }
  }

  @Test("the serialized receipt names each excluded id with its reason")
  func excludedIDsInReceipt() async throws {
    let receipt = await Self.run(Self.vendorsWithNewModels())
    let openAI = try #require(Self.providerJSON(try Self.json(receipt), "openAI"))
    let excluded = try #require(openAI["excludedModels"] as? [[String: Any]])
    let pairs = Set(
      excluded.compactMap { item -> String? in
        guard let id = item["id"] as? String, let reason = item["reason"] as? String else {
          return nil
        }
        return "\(id)=\(reason)"
      })
    #expect(pairs.contains("dall-e-9=notChatTextFamily"))
    #expect(pairs.contains("gpt-9-tts=excludedPattern"))
    #expect(pairs.contains("chatgpt-4o-latest=notChatTextFamily"))
  }

  @Test("a secret inside an excluded id makes the receipt refuse to encode")
  func excludedIDCanary() async throws {
    let vendors = Self.vendorsWithNewModels()
    let canary = "tts-\(Self.keys.values[.openAI]!)"
    vendors.catalog(Self.openAIModels, json: Vendors.json(["data": [["id": canary]]]))
    let receipt = await Self.run(vendors)
    #expect(throws: CloudModelRoutine.HarnessFailure.secretInOutput) {
      _ = try receipt.encoded(refusing: Array(Self.keys.values.values))
    }
  }

  @Test("the receipt records which OpenAI parameters each physical exchange carried")
  func physicalRequestEvidence() async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.responder = { provider, request, count in
      guard provider == .openAI else { return Vendors.echo(provider, request, count) }
      let body =
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        ?? [:]
      if body["temperature"] != nil {
        return (
          400,
          Vendors.json([
            "error": [
              "message": "Unsupported parameter", "type": "invalid_request_error",
              "param": "temperature", "code": "unsupported_parameter",
            ]
          ])
        )
      }
      return Vendors.echo(provider, request, count)
    }
    let capabilities = LLMProvider.openAI.modelCapabilities(model: "gpt-9-zeta", list: Self.seed)
    try #require(capabilities.temperaturePolicy == .include, "gpt-9-zeta must send temperature")
    let receipt = await Self.run(vendors)
    let root = try Self.json(receipt)
    let evidence = try #require(root["physicalRequests"] as? [[String: Any]])
    let openAI = evidence.filter {
      (($0["id"] as? [String: Any])?["call"] as? [String: Any])?["provider"] as? String == "openAI"
    }
    // First dictation: one exchange with temperature (rejected), one without; then one each.
    let params = openAI.map { ($0["sentOpenAIParams"] as? [String]) ?? ["<missing>"] }
    #expect(params.first?.contains("temperature") == true)
    #expect(params.dropFirst().allSatisfy { $0.contains("temperature") == false })
    #expect(openAI.count == receipt.calls.filter { $0.id.call.provider == .openAI }.count)
    #expect(evidence.count == receipt.physicalExchanges)
    let result = try #require(Self.candidates(receipt, .openAI).first)
    #expect(result.passViaAdaptation == true)
  }

  @Test("a catalog failure is published as a closed class, never an error name or text")
  func catalogFailureIsClosed() async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.catalog(Self.openAIModels, status: 401, json: "{}")
    let receipt = await Self.run(vendors)
    let root = try Self.json(receipt, refusing: Array(Self.keys.values.values))
    #expect(Self.providerJSON(root, "openAI")?["catalogFailure"] as? String == "keyRejected")
    // An unknown transport error with a canary in its text becomes `other`.
    let leaky = Self.vendorsWithNewModels()
    let throwing = CloudModelRoutine.Transports(
      catalog: { request in
        if request.url?.host == "api.anthropic.com" {
          throw Leaky(text: "boom \(Self.keys.values[.claude]!)")
        }
        return try await leaky.transports.catalog(request)
      },
      polish: leaky.transports.polish)
    let second = await CloudModelRoutine.run(
      keys: Self.keys, list: Self.seed, history: .init(), observedAt: Self.observedAt,
      transports: throwing, provenance: .from(environment: [:]))
    let secondRoot = try Self.json(second, refusing: Array(Self.keys.values.values))
    #expect(Self.providerJSON(secondRoot, "claude")?["catalogFailure"] as? String == "other")
  }

  @Test(
    "Gemini catalog 400: only Google's structured reason is a rejected key",
    arguments: [
      (
        #"{"error": {"code": 400, "message": "API_KEY_INVALID: key \#(CloudModelRoutineHarnessTests.keys.values[.gemini]!)"}}"#,
        "other"
      ),
      (
        #"{"error": {"code": 400, "status": "INVALID_ARGUMENT", "message": "bad", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID"}]}}"#,
        "keyRejected"
      ),
    ])
  func geminiKeyRejectionNeedsStructuredReason(body: String, expected: String) async throws {
    let vendors = Self.vendorsWithNewModels()
    vendors.catalog(Self.geminiModels, status: 400, json: body)
    let receipt = await Self.run(vendors)
    let root = try Self.json(receipt, refusing: Array(Self.keys.values.values))
    #expect(Self.providerJSON(root, "gemini")?["catalogFailure"] as? String == expected)
    #expect(vendors.polishRequests.contains { $0.contains("generativelanguage") } == false)
  }

  struct Leaky: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
  }

  @Test("over the limit: five candidates are polished with the production output caps")
  func overLimitAndOutputCaps() async throws {
    let vendors = Self.vendorsWithNewModels()
    let listed = Self.seed.models.filter { $0.provider == .openAI }.map {
      ["id": $0.id] as [String: Any]
    }
    let fresh = (1...7).map {
      ["id": "gpt-9-n\($0)", "created": 1_790_812_800 + $0] as [String: Any]
    }
    vendors.catalog(Self.openAIModels, json: Vendors.json(["data": listed + fresh]))
    let bodies = BodyLog()
    let echo = vendors.responder
    vendors.responder = { provider, request, count in
      bodies.add(provider, request.httpBody ?? Data())
      return echo(provider, request, count)
    }
    let receipt = await Self.run(vendors)
    #expect(
      Self.candidates(receipt, .openAI).map(\.id) == [
        "gpt-9-n7", "gpt-9-n6", "gpt-9-n5", "gpt-9-n4", "gpt-9-n3",
      ])
    let openAI = try #require(receipt.providers.first { $0.provider == "openAI" })
    #expect(openAI.dispositions["gpt-9-n2"] == "overLimit")
    #expect(openAI.dispositions["gpt-9-n1"] == "overLimit")
    #expect(vendors.polishRequests.filter { $0.contains("api.openai.com") }.count == 15)
    for body in bodies.of(.claude) { #expect(body["max_tokens"] as? Int == 8192) }
    for body in bodies.of(.openAI) {
      #expect(body["max_completion_tokens"] == nil)
      #expect(body["max_tokens"] == nil)
    }
    for body in bodies.of(.gemini) {
      #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] == nil)
    }
    #expect(bodies.of(.claude).isEmpty == false)
    #expect(bodies.of(.gemini).isEmpty == false)
  }

  final class BodyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(LLMProvider, Data)] = []
    func add(_ provider: LLMProvider, _ body: Data) {
      lock.withLock { items.append((provider, body)) }
    }
    func of(_ provider: LLMProvider) -> [[String: Any]] {
      lock.withLock { items }.filter { $0.0 == provider }.compactMap {
        (try? JSONSerialization.jsonObject(with: $0.1)) as? [String: Any]
      }
    }
  }

  // MARK: - Physical boundary

  @Test("a send without an admitted call is refused before the vendor sees it")
  func meterRefusesUnadmittedSend() async throws {
    let meter = CloudModelRoutine.Meter()
    let sent = Counter()
    let executor = meter.wrap(
      { request, _ in
        sent.add()
        return (Data(), Vendors.response(request.url!.absoluteString, 200))
      }, provider: .claude)
    let request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    await #expect(throws: CloudModelRoutine.Meter.Refused.self) {
      _ = try await executor(request, LLMTaskMetricsCollector())
    }
    #expect(sent.value == 0)
    #expect(meter.refusals == 1)
  }

  @Test("a fourth physical send on a Claude call is refused and never sent")
  func meterRefusesPastTheBound() async throws {
    let meter = CloudModelRoutine.Meter()
    let sent = Counter()
    let executor = meter.wrap(
      { request, _ in
        sent.add()
        return (Data("{}".utf8), Vendors.response(request.url!.absoluteString, 500))
      }, provider: .claude)
    let setting = try #require(
      CloudModelRoutineCalls.Setting(.claude(shape: .thinkingDisabled), provider: .claude))
    try meter.begin(
      .init(provider: .claude, model: "c", setting: setting, phase: .fallback, input: 0))
    let request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    for _ in 0..<3 { _ = try await executor(request, LLMTaskMetricsCollector()) }
    await #expect(throws: CloudModelRoutine.Meter.Refused.self) {
      _ = try await executor(request, LLMTaskMetricsCollector())
    }
    #expect(sent.value == 3)
    #expect(meter.snapshot.physicalCount == 3)
    #expect(
      meter.snapshot.records.map(\.outcome) == Array(repeating: .replied(status: 500), count: 3))
  }

  @Test("the receipt's secret scan refuses output that contains a secret")
  func secretScanRefuses() async throws {
    let receipt = await Self.run(Self.vendorsWithNewModels())
    #expect(throws: CloudModelRoutine.HarnessFailure.secretInOutput) {
      _ = try receipt.encoded(refusing: ["gpt-9-zeta"])
    }
  }

  // MARK: - Connector seams keep app behavior

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  static func scripted(_ replies: [(Int, String)], sent: Counter, requests: RequestLog)
    -> CloudModelRoutine.Executor
  {
    { request, _ in
      let index = sent.value
      sent.add()
      requests.add(request)
      let reply = replies[min(index, replies.count - 1)]
      return (Data(reply.1.utf8), Vendors.response(request.url!.absoluteString, reply.0))
    }
  }

  final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []
    func add(_ request: URLRequest) { lock.withLock { items.append(request) } }
    var all: [URLRequest] { lock.withLock { items } }
  }

  static func config(_ provider: LLMProvider, model: String) -> LLMProviderConfig {
    LLMProviderConfig(
      model: model, apiKeyKeychainId: CloudModelRoutine.keyID(provider),
      outputTokens: provider == .claude
        ? .capped(LLMConstants.claudeMaxOutputTokens) : .providerDefault,
      temperature: 0,
      thinking: provider.modelCapabilities(model: model, list: seed).thinkingControl.resolved)
  }

  enum Scenario: String, CaseIterable {
    case success, retryThenSuccess, malformedBody, badRequest
  }

  static func replies(_ scenario: Scenario, _ provider: LLMProvider) -> [(Int, String)] {
    let ok = Vendors.success(provider, text: "Polished text.")
    switch scenario {
    case .success: return [(200, ok)]
    case .retryThenSuccess: return [(503, "{}"), (200, ok)]
    case .malformedBody: return [(200, "<html>not json</html>")]
    case .badRequest: return [(400, #"{"error":{"message":"invalid"}}"#)]
    }
  }

  @Test(
    "Claude and Gemini polish through the seam with the shipped request and error handling",
    arguments: [LLMProvider.claude, .gemini], Scenario.allCases)
  func connectorSeam(_ provider: LLMProvider, _ scenario: Scenario) async throws {
    let sent = Counter()
    let requests = RequestLog()
    let model = provider == .claude ? "claude-sonnet-4-5" : "gemini-2.5-flash"
    let executor = Self.scripted(Self.replies(scenario, provider), sent: sent, requests: requests)
    let connector = try #require(
      CloudModelRoutine.connector(
        provider, keychain: Self.keys.keychain, list: Self.seed, executor: executor))
    let envelope = LiveSweepSupport.productionEnvelope(
      provider: provider, modelID: model, transcript: "hello there")
    var outcome: Result<String, Error>
    do {
      outcome = .success(
        try await connector.polish(
          envelope: envelope, config: Self.config(provider, model: model), onToken: nil
        )
        .polishedText)
    } catch {
      outcome = .failure(error)
    }

    let request = try #require(requests.all.first)
    #expect(request.httpMethod == "POST")
    if provider == .claude {
      #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
      #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.keys.values[.claude])
      #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    } else {
      #expect(
        request.url?.absoluteString
          == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
      )
      #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.keys.values[.gemini])
    }
    switch scenario {
    case .success:
      #expect(try outcome.get() == "Polished text.")
      #expect(sent.value == 1)
    case .retryThenSuccess:
      #expect(try outcome.get() == "Polished text.")
      #expect(sent.value == 2)
    case .malformedBody:
      #expect(throws: (any Error).self) { _ = try outcome.get() }
      #expect(sent.value == 1)
    case .badRequest:
      #expect(throws: LLMError.classified(.badRequest)) { _ = try outcome.get() }
      #expect(sent.value == 1)
    }
  }
}

extension Result {
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
  fileprivate var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}
