import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Settings search, founder decisions 10 and 11), driven offline through
/// the shipped connectors' transport seams with fake keys. Expected orders, request fields and
/// outcomes are literals written from the plan, not read from the search code.
@Suite("Cloud model routine settings search (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutineSearchTests {
  typealias H = CloudModelRoutineHarnessTests
  typealias Vendors = H.Vendors

  static let models: [LLMProvider: String] = [
    .openAI: "gpt-9-zeta", .claude: "claude-zeta-9", .gemini: "gemini-9-flash",
  ]

  // MARK: - Reading what was sent

  static func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
  }

  /// The setting a request carried, read from its body in the vendors' own field names.
  static func sentSetting(_ provider: LLMProvider, _ request: URLRequest) -> String {
    let body = body(request)
    switch provider {
    case .openAI:
      let effort = body["reasoning_effort"] as? String ?? "omit"
      return "\(effort)/\(body["temperature"] == nil ? "omit" : "include")"
    case .claude:
      if let config = body["output_config"] as? [String: Any] {
        return "output_config.effort=\(config["effort"] as? String ?? "?")"
      }
      let thinking = (body["thinking"] as? [String: Any])?["type"] as? String ?? "absent"
      return "thinking=\(thinking)"
    default:
      let generation = body["generationConfig"] as? [String: Any] ?? [:]
      guard let thinking = generation["thinkingConfig"] as? [String: Any] else { return "none" }
      if let level = thinking["thinkingLevel"] as? String { return "level:\(level)" }
      if let budget = thinking["thinkingBudget"] { return "budget:\(budget)" }
      return "other"
    }
  }

  /// The model the request names (Gemini puts it in the URL).
  static func sentModel(_ provider: LLMProvider, _ request: URLRequest) -> String? {
    if provider == .gemini {
      let path = request.url?.path ?? ""
      return path.split(separator: "/").last.map { String($0.split(separator: ":")[0]) }
    }
    return body(request)["model"] as? String
  }

  static func reject(_ provider: LLMProvider) -> (Int, String) {
    let canary = H.keys.values[provider]!
    switch provider {
    case .openAI:
      return (
        400,
        Vendors.json([
          "error": ["message": "Invalid request shape \(canary)", "type": "invalid_request_error"]
        ])
      )
    case .claude:
      return (
        400,
        Vendors.json([
          "type": "error",
          "error": ["type": "invalid_request_error", "message": "bad shape \(canary)"],
        ])
      )
    default:
      return (
        400,
        Vendors.json([
          "error": [
            "code": 400, "message": "Invalid argument \(canary)", "status": "INVALID_ARGUMENT",
          ]
        ])
      )
    }
  }

  final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(LLMProvider, String, String?, String)] = []
    func add(_ provider: LLMProvider, _ request: URLRequest) {
      let entry = (
        provider, CloudModelRoutineSearchTests.sentSetting(provider, request),
        CloudModelRoutineSearchTests.sentModel(provider, request), Vendors.inputText(request)
      )
      lock.withLock { items.append(entry) }
    }
    func settings(_ provider: LLMProvider) -> [String] {
      lock.withLock { items.filter { $0.0 == provider }.map(\.1) }
    }
    func models(_ provider: LLMProvider) -> [String?] {
      lock.withLock { items.filter { $0.0 == provider }.map(\.2) }
    }
  }

  /// Vendors where `provider` answers with `decide` (setting, input text) and the other two
  /// echo. Every polish request is logged.
  static func vendors(
    _ provider: LLMProvider, sent: Sent,
    decide: @escaping @Sendable (String, String) -> (Int, String)?
  ) -> Vendors {
    let vendors = H.vendorsWithNewModels()
    vendors.responder = { p, request, count in
      sent.add(p, request)
      if p == provider, let reply = decide(sentSetting(p, request), Vendors.inputText(request)) {
        return reply
      }
      return Vendors.echo(p, request, count)
    }
    return vendors
  }

  static func candidate(_ receipt: CloudModelRoutineReceipt, _ provider: LLMProvider) throws
    -> CloudModelRoutineReceipt.CandidateResult
  {
    try #require(H.candidates(receipt, provider).first)
  }

  /// POSTs to the provider, ledger records for it and physical evidence for it agree.
  static func reconcile(
    _ receipt: CloudModelRoutineReceipt, _ vendors: Vendors, _ provider: LLMProvider,
    expected: Int
  ) {
    let host: String =
      switch provider {
      case .openAI: "api.openai.com"
      case .claude: "api.anthropic.com"
      default: "generativelanguage"
      }
    #expect(vendors.polishRequests.filter { $0.contains(host) }.count == expected)
    #expect(receipt.calls.filter { $0.id.call.provider == provider }.count == expected)
    #expect(receipt.physicalRequests.filter { $0.id.call.provider == provider }.count == expected)
    #expect(receipt.physicalExchanges == receipt.physicalRequests.count)
    #expect(receipt.unrecordedExchanges == 0)
    #expect(receipt.refusals == 0)
  }

  // MARK: - Order and exhaustion

  /// Fallback first, then the approved alternatives in plan order, as each vendor sees them.
  static let exhaustionOrder: [(LLMProvider, [String])] = [
    (
      .openAI,
      [
        "omit/include", "omit/omit", "none/include", "none/omit", "minimal/include",
        "minimal/omit", "low/include", "low/omit",
      ]
    ),
    (.gemini, ["none", "level:minimal", "level:low", "level:medium", "level:high"]),
    (
      .claude,
      ["thinking=disabled", "output_config.effort=low", "thinking=between_tools"]
    ),
  ]

  @Test(
    "every alternative rejected: plan order, one screening each, exhaustion and the issue intent",
    arguments: exhaustionOrder)
  func exhaustion(provider: LLMProvider, order: [String]) async throws {
    let sent = Sent()
    let vendors = Self.vendors(provider, sent: sent) { _, _ in Self.reject(provider) }
    let receipt = await H.run(vendors)
    #expect(sent.settings(provider) == order)
    #expect(sent.models(provider).allSatisfy { $0 == Self.models[provider] })
    let result = try Self.candidate(receipt, provider)
    #expect(result.outcome == "fail")
    #expect(result.errorClass == .requestRejected)
    #expect(result.row == nil)
    #expect(result.fallback?.errorClass == .requestRejected)
    #expect(result.fallback?.perInputMs.isEmpty == true)
    let search = try #require(result.search)
    #expect(search.trigger == .requestRejected)
    #expect(search.outcome == .requestRejectedSearchExhausted)
    #expect(search.issueIntent == "Cloud model routine: call recipe")
    #expect(search.attempts.count == order.count - 1)
    #expect(search.attempts.allSatisfy { $0.confirmation == nil && !$0.qualified })
    #expect(search.attempts.allSatisfy { $0.screening.inputs == [0] })
    #expect(receipt.outcome == "partial")
    Self.reconcile(receipt, vendors, provider, expected: order.count)
    // The canary in every rejection never reaches the receipt.
    _ = try receipt.encoded(refusing: Array(H.keys.values.values))
  }

  // MARK: - First full pass

  static let passCases: [(LLMProvider, String, [String], CloudModelRoutine.RequestJSON, String)] = [
    (
      .openAI, "none/omit",
      [
        "omit/include", "omit/omit", "none/include", "none/omit", "none/omit", "none/omit",
        "none/omit",
      ],
      .openAI(effort: "none", temperature: "omit"), "openAI:none/omit"
    ),
    (
      .gemini, "level:medium",
      [
        "none", "level:minimal", "level:low", "level:medium", "level:medium", "level:medium",
        "level:medium",
      ],
      .gemini(none: false, budget: nil, level: "medium"), "gemini:level:medium"
    ),
    (
      .claude, "output_config.effort=low",
      [
        "thinking=disabled", "output_config.effort=low", "output_config.effort=low",
        "output_config.effort=low", "output_config.effort=low",
      ],
      .claude(shape: "effortLow"), "claude:effortLow"
    ),
  ]

  @Test(
    "the first setting that passes screening and three confirmations is proposed",
    arguments: passCases)
  func firstFullPass(
    provider: LLMProvider, accepted: String, order: [String],
    request: CloudModelRoutine.RequestJSON, label: String
  ) async throws {
    let sent = Sent()
    let vendors = Self.vendors(provider, sent: sent) { setting, _ in
      setting == accepted ? nil : Self.reject(provider)
    }
    let receipt = await H.run(vendors)
    #expect(sent.settings(provider) == order)
    #expect(sent.models(provider).allSatisfy { $0 == Self.models[provider] })
    let result = try Self.candidate(receipt, provider)
    #expect(result.outcome == "passViaSearch")
    // The failed fallback is kept as measured.
    #expect(result.errorClass == .requestRejected)
    #expect(result.fallback?.errorClass == .requestRejected)
    let search = try #require(result.search)
    #expect(search.outcome == .passed)
    #expect(search.chosenSetting == label)
    #expect(search.issueIntent == nil)
    let chosen = try #require(search.attempts.last)
    #expect(chosen.qualified)
    #expect(chosen.screening.inputs == [0])
    #expect(chosen.confirmation?.inputs == [0, 1, 2])
    #expect(chosen.confirmation?.perInputMs.count == 3)
    #expect(search.attempts.dropLast().allSatisfy { !$0.qualified })

    // The row: the chosen setting, the fallback's chat eligibility and file batching.
    let row = try #require(result.row)
    let id = try #require(Self.models[provider])
    #expect(row.id == id)
    #expect(row.request == request)
    #expect(row.recommended == false && row.hidden == false)
    let fallback = provider.modelCapabilities(model: id, list: H.seed)
    #expect(row.supportsChatCompletions == fallback.supportsChatCompletions)
    #expect(row.allowsFileBatch == provider.allowsFileBatch(model: id, list: H.seed))
    #expect(result.resolvesTheSame == true)
    // The proposed list resolves the id and both dated spellings to the chosen request.
    let proposed = try CloudModelRoutine.listAdding(row, to: H.seed)
    for variant in [id, "\(id)-2030-01-01", "\(id)-20300101"] {
      let listed = try #require(provider.listedRow(model: variant, list: proposed))
      #expect(CloudModelRoutine.RequestJSON(listed.request) == request)
      #expect(
        provider.allowsFileBatch(model: variant, list: proposed)
          == provider.allowsFileBatch(model: id, list: H.seed))
    }
    // The captured list is unchanged.
    #expect(H.seed.models.contains { $0.id == id } == false)
    #expect(receipt.outcome == "success")
    Self.reconcile(receipt, vendors, provider, expected: order.count)
    _ = try receipt.encoded(refusing: Array(H.keys.values.values))
  }

  // MARK: - Disqualification

  @Test("a setting rejected during confirmation does not qualify; the next one is tried")
  func confirmationRejection() async throws {
    let sent = Sent()
    let second = CloudModelRoutine.inputs[1].text
    let vendors = Self.vendors(.openAI, sent: sent) { setting, input in
      switch setting {
      case "omit/omit": return input == second ? Self.reject(.openAI) : nil
      case "none/include": return nil
      default: return Self.reject(.openAI)
      }
    }
    let receipt = await H.run(vendors)
    #expect(
      sent.settings(.openAI) == [
        "omit/include", "omit/omit", "omit/omit", "omit/omit", "none/include", "none/include",
        "none/include", "none/include",
      ])
    let search = try #require(try Self.candidate(receipt, .openAI).search)
    #expect(search.attempts.count == 2)
    let first = search.attempts[0]
    #expect(first.setting == "openAI:omit/omit")
    #expect(first.screening.completed)
    #expect(first.confirmation?.errorClass == .requestRejected)
    #expect(first.confirmation?.perInputMs.count == 1)
    #expect(first.qualified == false)
    #expect(search.chosenSetting == "openAI:none/include")
    #expect(
      try Self.candidate(receipt, .openAI).row?.request
        == .openAI(effort: "none", temperature: "include"))
    Self.reconcile(receipt, vendors, .openAI, expected: 8)
  }

  @Test("a success that needed a parameter strip does not prove its setting")
  func adaptedSuccessDisqualified() async throws {
    let sent = Sent()
    let vendors = Self.vendors(.openAI, sent: sent) { setting, _ in
      switch setting {
      // Both parameters: reject `temperature` as unsupported, so the connector strips it.
      case "none/include":
        return (
          400,
          Vendors.json([
            "error": [
              "message": "Unsupported parameter", "type": "invalid_request_error",
              "param": "temperature", "code": "unsupported_parameter",
            ]
          ])
        )
      case "none/omit": return nil
      default: return Self.reject(.openAI)
      }
    }
    let receipt = await H.run(vendors)
    // none/include: the screening's first request, then the stripped reissue (none/omit
    // shape) which succeeded; then none/omit itself, screening and three confirmations.
    #expect(
      sent.settings(.openAI) == [
        "omit/include", "omit/omit", "none/include", "none/omit", "none/omit", "none/omit",
        "none/omit", "none/omit",
      ])
    let search = try #require(try Self.candidate(receipt, .openAI).search)
    let adapted = try #require(search.attempts.first { $0.setting == "openAI:none/include" })
    #expect(adapted.screening.completed)
    #expect(adapted.screening.memoAdapted)
    #expect(adapted.screening.requestsMatchedSetting == false)
    #expect(adapted.screening.physicalAttempts == 2)
    #expect(adapted.qualified == false)
    #expect(adapted.confirmation == nil)
    #expect(search.chosenSetting == "openAI:none/omit")
    let chosen = try #require(search.attempts.last)
    #expect(chosen.screening.memoAdapted == false)
    #expect(chosen.confirmation?.memoAdapted == false)
    #expect(chosen.confirmation?.requestsMatchedSetting == true)
    Self.reconcile(receipt, vendors, .openAI, expected: 8)
  }

  @Test("unusable output moves on, but a search without every rejection is not exhaustion")
  func unusableOutputIsNotExhaustion() async throws {
    let sent = Sent()
    let canary = H.keys.values[.claude]!
    let vendors = Self.vendors(.claude, sent: sent) { setting, _ in
      if setting == "output_config.effort=low" {
        // A reply with a thinking artifact (unusable), carrying the canary.
        return (200, Vendors.success(.claude, text: "<thinking>plan</thinking> \(canary)"))
      }
      return Self.reject(.claude)
    }
    let receipt = await H.run(vendors)
    #expect(
      sent.settings(.claude) == [
        "thinking=disabled", "output_config.effort=low", "thinking=between_tools",
      ])
    let result = try Self.candidate(receipt, .claude)
    let search = try #require(result.search)
    #expect(search.attempts.first?.screening.errorClass == .unusableOutput)
    #expect(search.outcome == .noQualifyingSetting)
    #expect(search.issueIntent == nil)
    #expect(result.outcome == "fail")
    Self.reconcile(receipt, vendors, .claude, expected: 3)
    _ = try receipt.encoded(refusing: Array(H.keys.values.values))
  }

  // MARK: - Interruption and triggers

  static let interruptions: [(Int, String, CloudModelRoutine.ErrorClass)] = [
    (401, #"{"error":{"message":"bad key"}}"#, .keyRejected),
    (404, #"{"error":{"message":"no such model"}}"#, .notAvailable),
    (403, #"{"error":{"message":"forbidden"}}"#, .notAvailable),
  ]

  @Test(
    "a failure that is not about the setting stops the search and is named",
    arguments: interruptions)
  func interruption(status: Int, body: String, expected: CloudModelRoutine.ErrorClass) async throws
  {
    let sent = Sent()
    let vendors = Self.vendors(.openAI, sent: sent) { setting, _ in
      setting == "omit/include" ? Self.reject(.openAI) : (status, body)
    }
    let receipt = await H.run(vendors)
    #expect(sent.settings(.openAI) == ["omit/include", "omit/omit"])
    let search = try #require(try Self.candidate(receipt, .openAI).search)
    #expect(search.outcome == .interrupted)
    #expect(search.interruption == expected)
    #expect(search.issueIntent == nil)
    #expect(search.attempts.count == 1)
    Self.reconcile(receipt, vendors, .openAI, expected: 2)
  }

  static let nonTriggers: [(Int, String, CloudModelRoutine.ErrorClass)] = [
    (401, #"{"error":{"message":"bad key"}}"#, .keyRejected),
    // A 400 the connector classifies as too long, not as a bad request.
    (400, #"{"error":{"code":"context_length_exceeded","message":"too long"}}"#, .other),
    (400, #"{"error":{"code":"content_filter","message":"blocked"}}"#, .other),
    (429, #"{"error":{"type":"insufficient_quota","message":"quota"}}"#, .quotaOrRate),
  ]

  @Test("only a final bad request starts the search", arguments: nonTriggers)
  func onlyBadRequestTriggers(status: Int, body: String, expected: CloudModelRoutine.ErrorClass)
    async throws
  {
    let sent = Sent()
    let vendors = Self.vendors(.openAI, sent: sent) { _, _ in (status, body) }
    let receipt = await H.run(vendors)
    let result = try Self.candidate(receipt, .openAI)
    #expect(result.errorClass == expected)
    #expect(result.search == nil)
    #expect(sent.settings(.openAI).allSatisfy { $0 == "omit/include" })
  }

  @Test("an unusable fallback output does not start the search")
  func unusableFallbackDoesNotTrigger() async throws {
    let sent = Sent()
    let vendors = Self.vendors(.gemini, sent: sent) { _, _ in
      (200, Vendors.success(.gemini, text: "<thinking>plan</thinking>"))
    }
    let receipt = await H.run(vendors)
    let result = try Self.candidate(receipt, .gemini)
    #expect(result.errorClass == .unusableOutput)
    #expect(result.search == nil)
    #expect(sent.settings(.gemini) == ["none"])
  }

  @Test("three fallback successes keep the fallback row and send no search request")
  func fallbackSuccessNoSearch() async throws {
    let vendors = H.vendorsWithNewModels()
    let receipt = await H.run(vendors)
    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let result = try Self.candidate(receipt, provider)
      #expect(result.outcome == "pass")
      #expect(result.search == nil)
      #expect(result.fallback?.inputs == [0, 1, 2])
    }
    #expect(receipt.calls.allSatisfy { $0.id.call.phase == .fallback })
    #expect(vendors.polishRequests.count == 9)
  }

  // MARK: - Bound

  @Test("an eighth alternative for one model is refused before anything is sent")
  func alternativeLimitRefusesBeforeSending() async throws {
    let vendors = H.vendorsWithNewModels()
    let meter = CloudModelRoutine.Meter()
    let menu = CloudModelRoutineCalls.Setting.searchMenu(.openAI)
    #expect(menu.count == 8)
    var results: [CloudModelRoutine.PhaseResult] = []
    for setting in menu {
      results.append(
        await CloudModelRoutine.runPhase(
          id: "gpt-9-zeta", provider: .openAI, setting: setting, phase: .screening,
          inputIndices: [0], list: H.seed, keychain: H.keys.keychain, meter: meter,
          transports: vendors.transports))
    }
    #expect(results.prefix(7).allSatisfy { $0.errorClass == nil })
    #expect(results.last?.errorClass == .harnessRefused)
    #expect(results.last?.physicalAttempts == 0)
    #expect(vendors.polishRequests.count == 7)
    #expect(meter.refusals == 1)
  }
}
