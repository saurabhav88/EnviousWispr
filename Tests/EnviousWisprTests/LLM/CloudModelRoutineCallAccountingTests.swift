import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 Cost bound, founder decision 12): the routine's call-count limits and its
/// record of reported token usage. Offline: scripted reply bodies and a fake sender only.
@Suite("Cloud model routine call accounting (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutineCallAccountingTests {

  typealias Calls = CloudModelRoutineCalls
  static let fakeKey = "fake-routine-key-9c1d"

  static func s(_ policy: CloudModelList.RequestPolicy, _ provider: LLMProvider) -> Calls.Setting {
    Calls.Setting(policy, provider: provider)!
  }

  /// The first search-menu setting, used as a fallback setting in tests (any provider-matched
  /// setting may be a fallback); an OpenAI setting for providers without a menu.
  static func fallback(_ provider: LLMProvider) -> Calls.Setting {
    Calls.Setting.searchMenu(provider).first ?? Calls.Setting.searchMenu(.openAI)[0]
  }

  static func call(
    _ provider: LLMProvider, _ model: String, _ setting: Calls.Setting? = nil,
    _ phase: Calls.Phase = .fallback, input: Int = 0
  ) -> Calls.LogicalCallID {
    Calls.LogicalCallID(
      provider: provider, model: model, setting: setting ?? fallback(provider), phase: phase,
      input: input)
  }

  // MARK: - Limits

  @Test("the limits are the approved numbers and the shipped retry and strip bounds")
  func limitValues() {
    #expect(Calls.Limits.candidatesPerProvider == 5)
    #expect(Calls.Limits.fallbackDictations == 3)
    #expect(Calls.Limits.screeningsPerSetting == 1)
    #expect(Calls.Limits.confirmationsPerSetting == 3)
    #expect(Calls.Limits.alternativeSettings(.openAI) == 7)
    #expect(Calls.Limits.alternativeSettings(.gemini) == 4)
    #expect(Calls.Limits.alternativeSettings(.claude) == 2)
    // 2 retries -> 3 attempts; OpenAI adds at most 2 strip reissues per logical call.
    #expect(LLMRetryPolicy.defaultMaxRetries == 2)
    #expect(OpenAIConnector.strippableParams.count == 2)
    #expect(Calls.Limits.physicalPerLogical(.openAI) == 5)
    #expect(Calls.Limits.physicalPerLogical(.gemini) == 3)
    #expect(Calls.Limits.physicalPerLogical(.claude) == 3)
    #expect(Calls.Limits.physicalPerLogical(.ollama) == 0)
  }

  @Test("five models per provider; the sixth is refused; providers count separately")
  func candidateLimit() throws {
    var ledger = Calls.Ledger()
    for index in 1...5 { try ledger.admit(Self.call(.openAI, "gpt-\(index)")) }
    #expect(throws: Calls.Refusal.candidateLimit(provider: .openAI)) {
      try ledger.admit(Self.call(.openAI, "gpt-6"))
    }
    try ledger.admit(Self.call(.claude, "claude-1"))
    // An admitted model can still take more calls.
    try ledger.admit(Self.call(.openAI, "gpt-1", input: 1))
    #expect(ledger.logicalCount == 7)
  }

  @Test("three fallback dictations per model with one fallback setting")
  func fallbackLimit() throws {
    var ledger = Calls.Ledger()
    for input in 0..<3 { try ledger.admit(Self.call(.gemini, "g", Self.s(.gemini(thinking: .none), .gemini), input: input)) }
    #expect(throws: Calls.Refusal.inputOutOfRange(3)) {
      try ledger.admit(Self.call(.gemini, "g", Self.s(.gemini(thinking: .none), .gemini), input: 3))
    }
    #expect(throws: Calls.Refusal.settingLimit(provider: .gemini, model: "g")) {
      try ledger.admit(Self.call(.gemini, "g", Self.s(.gemini(thinking: .level("low")), .gemini), input: 0))
    }
  }

  @Test("one screening and three confirmations per alternative setting")
  func searchPhaseLimits() throws {
    var ledger = Calls.Ledger()
    try ledger.admit(Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening, input: 0))
    #expect(
      throws: Calls.Refusal.phaseLimit(
        Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening, input: 1))
    ) {
      try ledger.admit(Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening, input: 1))
    }
    for input in 0..<3 {
      try ledger.admit(Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .confirmation, input: input))
    }
    #expect(ledger.logicalCount == 4)
  }

  @Test(
    "alternative settings per model stop at the provider's search size",
    arguments: [(LLMProvider.openAI, 7), (.gemini, 4), (.claude, 2)])
  func settingLimit(_ provider: LLMProvider, _ allowed: Int) throws {
    var ledger = Calls.Ledger()
    for index in 0..<allowed {
      try ledger.admit(Self.call(provider, "m", Calls.Setting.searchMenu(provider)[index], .screening))
    }
    #expect(throws: Calls.Refusal.settingLimit(provider: provider, model: "m")) {
      try ledger.admit(Self.call(provider, "m", Calls.Setting.searchMenu(provider)[allowed], .screening))
    }
    // The fallback does not use an alternative slot.
    try ledger.admit(Self.call(provider, "m", Self.fallback(provider), .fallback))
  }

  @Test("re-admitting the same call grants nothing new and counts once")
  func readmissionIsIdempotent() throws {
    var ledger = Calls.Ledger()
    let call = Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening)
    try ledger.admit(call)
    try ledger.admit(call)
    #expect(ledger.logicalCount == 1)
    #expect(
      throws: Calls.Refusal.phaseLimit(
        Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening, input: 2))
    ) {
      try ledger.admit(Self.call(.claude, "c", Self.s(.claude(shape: .effortLow), .claude), .screening, input: 2))
    }
  }

  @Test("local and fixed providers are refused")
  func unsupportedProvider() {
    var ledger = Calls.Ledger()
    #expect(throws: Calls.Refusal.unsupportedProvider) {
      try ledger.admit(Self.call(.ollama, "llama"))
    }
  }

  @Test(
    "physical exchanges stop at the provider's bound; each grant is distinct",
    arguments: [(LLMProvider.openAI, 5), (.gemini, 3), (.claude, 3)])
  func physicalLimit(_ provider: LLMProvider, _ bound: Int) throws {
    var ledger = Calls.Ledger()
    let call = Self.call(provider, "m")
    try ledger.admit(call)
    var attempts: [Int] = []
    for _ in 0..<bound { attempts.append(try ledger.admitExchange(for: call).attempt) }
    #expect(attempts == Array(1...bound))
    #expect(throws: Calls.Refusal.physicalLimit(call)) { _ = try ledger.admitExchange(for: call) }
    #expect(ledger.physicalCount == bound)
  }

  @Test("an exchange needs an admitted call; each exchange is recorded once")
  func recordOnce() throws {
    var ledger = Calls.Ledger()
    let call = Self.call(.openAI, "gpt-x")
    #expect(throws: Calls.Refusal.unknownLogicalCall) { _ = try ledger.admitExchange(for: call) }
    try ledger.admit(call)
    let first = try ledger.admitExchange(for: call)
    let second = try ledger.admitExchange(for: call)
    try ledger.record(first, outcome: .noReply, usage: nil)
    #expect(throws: Calls.Refusal.unknownOrRecordedExchange) {
      try ledger.record(first, outcome: .noReply, usage: nil)
    }
    // A granted exchange with no recorded outcome still counts.
    #expect(ledger.physicalCount == 2)
    #expect(ledger.unrecordedCount == 1)
    try ledger.record(second, outcome: .replied(status: 200), usage: .absent)
    #expect(ledger.records.map(\.usage) == [nil, .absent])
    #expect(ledger.records.map(\.outcome) == [.noReply, .replied(status: 200)])
  }

  // MARK: - Usage

  @Test("OpenAI: reasoning is part of completion tokens")
  func openAIUsage() {
    let body =
      #"{"usage":{"prompt_tokens":812,"completion_tokens":190,"total_tokens":1002,"completion_tokens_details":{"reasoning_tokens":64}}}"#
    #expect(
      Calls.usage(provider: .openAI, body: Data(body.utf8))
        == .reported(.init(input: 812, output: 190, thinking: 64, thinkingIncludedInOutput: true)))
  }

  @Test("Claude: thinking is part of output tokens; a missing breakdown stays unreported")
  func claudeUsage() {
    let with =
      #"{"usage":{"input_tokens":700,"output_tokens":300,"output_tokens_details":{"thinking_tokens":120}}}"#
    let without = #"{"usage":{"input_tokens":700,"output_tokens":300}}"#
    #expect(
      Calls.usage(provider: .claude, body: Data(with.utf8))
        == .reported(.init(input: 700, output: 300, thinking: 120, thinkingIncludedInOutput: true)))
    #expect(
      Calls.usage(provider: .claude, body: Data(without.utf8))
        == .reported(.init(input: 700, output: 300, thinking: nil, thinkingIncludedInOutput: true)))
  }

  @Test("Gemini: thinking is reported apart from output")
  func geminiUsage() {
    let body =
      #"{"candidates":[],"usageMetadata":{"promptTokenCount":650,"candidatesTokenCount":150,"thoughtsTokenCount":400,"totalTokenCount":1200}}"#
    #expect(
      Calls.usage(provider: .gemini, body: Data(body.utf8))
        == .reported(.init(input: 650, output: 150, thinking: 400, thinkingIncludedInOutput: false))
    )
  }

  enum BadUsage: String, CaseIterable {
    case notJSON, usageNotObject, stringCount, negativeCount, fractionalCount, booleanCount
    case detailsNotObject, thinkingAboveOutput

    var body: String {
      switch self {
      case .notJSON: return "<html>502</html>"
      case .usageNotObject: return #"{"usage":7}"#
      case .stringCount: return #"{"usage":{"prompt_tokens":"812","completion_tokens":1}}"#
      case .negativeCount: return #"{"usage":{"prompt_tokens":-1,"completion_tokens":1}}"#
      case .fractionalCount: return #"{"usage":{"prompt_tokens":1.5,"completion_tokens":1}}"#
      case .booleanCount: return #"{"usage":{"prompt_tokens":true,"completion_tokens":1}}"#
      case .detailsNotObject:
        return #"{"usage":{"prompt_tokens":1,"completion_tokens":1,"completion_tokens_details":3}}"#
      case .thinkingAboveOutput:
        return
          #"{"usage":{"prompt_tokens":1,"completion_tokens":10,"completion_tokens_details":{"reasoning_tokens":11}}}"#
      }
    }
  }

  @Test("malformed usage is never read as a measurement", arguments: BadUsage.allCases)
  func malformedUsage(_ bad: BadUsage) {
    #expect(Calls.usage(provider: .openAI, body: Data(bad.body.utf8)) == .malformed, "\(bad)")
  }

  @Test("a reply without usage is absent, not zero")
  func absentUsage() {
    let error = #"{"error":{"message":"bad request","type":"invalid_request_error"}}"#
    #expect(Calls.usage(provider: .openAI, body: Data(error.utf8)) == .absent)
    #expect(Calls.usage(provider: .gemini, body: Data(#"{"candidates":[]}"#.utf8)) == .absent)
  }

  // MARK: - Fake sender and safe records

  /// Drives one logical call the way the harness will: admit, then ask before every send.
  static func drive(
    _ ledger: inout Calls.Ledger, _ call: Calls.LogicalCallID, replies: [(Int, String)?],
    sends: inout Int
  ) throws {
    try ledger.admit(call)
    for reply in replies {
      let exchange = try ledger.admitExchange(for: call)
      sends += 1
      if let (status, body) = reply {
        try ledger.record(
          exchange, outcome: .replied(status: status),
          usage: Calls.usage(provider: call.provider, body: Data(body.utf8)))
      } else {
        try ledger.record(exchange, outcome: .noReply, usage: nil)
      }
    }
  }

  @Test("admission comes before every send; a refused call sends nothing")
  func fakeSender() throws {
    var ledger = Calls.Ledger()
    var sends = 0
    // OpenAI: a timeout, a 400 that strips a parameter, then success.
    try Self.drive(
      &ledger, Self.call(.openAI, "gpt-x"),
      replies: [
        nil,
        (400, #"{"error":{"message":"Unsupported parameter: 'temperature'"}}"#),
        (200, #"{"usage":{"prompt_tokens":10,"completion_tokens":5}}"#),
      ], sends: &sends)
    #expect(sends == 3)
    // A sixth physical exchange on a bounded call is refused before sending.
    let claude = Self.call(.claude, "c")
    #expect(throws: Calls.Refusal.physicalLimit(claude)) {
      try Self.drive(&ledger, claude, replies: [nil, nil, nil, nil], sends: &sends)
    }
    #expect(sends == 6)
    // A call over the candidate limit sends nothing at all.
    for index in 1...4 { try ledger.admit(Self.call(.openAI, "gpt-\(index)")) }
    #expect(throws: Calls.Refusal.candidateLimit(provider: .openAI)) {
      try Self.drive(&ledger, Self.call(.openAI, "gpt-6"), replies: [nil], sends: &sends)
    }
    #expect(sends == 6)
    #expect(ledger.physicalCount == 6)
    #expect(
      ledger.records.map(\.usage) == [
        nil, .absent,
        .reported(.init(input: 10, output: 5, thinking: nil, thinkingIncludedInOutput: true)),
        nil, nil, nil,
      ])
  }

  @Test("a serialized record carries no key, prompt, reply text or header")
  func recordsAreSecretSafe() throws {
    var ledger = Calls.Ledger()
    var sends = 0
    let leaky = """
      {"error":{"message":"Incorrect API key provided: \(Self.fakeKey)"},\
      "usage":{"prompt_tokens":3,"completion_tokens":1},\
      "choices":[{"message":{"content":"secret polished text \(Self.fakeKey)"}}]}
      """
    try Self.drive(
      &ledger, Self.call(.openAI, "gpt-x", Self.s(.openAI(effort: .low, temperature: .omit), .openAI)), replies: [(401, leaky)],
      sends: &sends)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(ledger.records), as: UTF8.self)
    #expect(json.contains(Self.fakeKey) == false)
    #expect(json.contains("secret polished text") == false)
    #expect(json.contains("Incorrect API key") == false)
    #expect(json.contains(#""status":401"#))
    #expect(json.contains(#""input":3"#))
  }

  @Test("only provider-matched settings inside the list's bounds can be built")
  func settingConstruction() {
    #expect(Calls.Setting(.gemini(thinking: .level(Self.fakeKey)), provider: .gemini) == nil)
    #expect(Calls.Setting(.gemini(thinking: .budget(40_000)), provider: .gemini) == nil)
    #expect(Calls.Setting(.openAI(effort: .low, temperature: .omit), provider: .claude) == nil)
    #expect(Calls.Setting(.claude(shape: .effortLow), provider: .ollama) == nil)
    #expect(Self.s(.gemini(thinking: .budget(128)), .gemini).label == "gemini:budget:128")
  }

  @Test("an invalid setting is refused before any send and leaves accounting unchanged")
  func invalidSettingSendsNothing() throws {
    var ledger = Calls.Ledger()
    var sends = 0
    // A budget is a valid fallback but is not in the search menu.
    let budget = Self.s(.gemini(thinking: .budget(128)), .gemini)
    #expect(throws: Calls.Refusal.invalidSetting) {
      try Self.drive(&ledger, Self.call(.gemini, "g", budget, .screening), replies: [nil], sends: &sends)
    }
    // A setting built for one provider cannot be used for another.
    let openAISetting = Self.s(.openAI(effort: .low, temperature: .omit), .openAI)
    #expect(throws: Calls.Refusal.invalidSetting) {
      try Self.drive(&ledger, Self.call(.claude, "c", openAISetting), replies: [nil], sends: &sends)
    }
    #expect(sends == 0)
    #expect(ledger.logicalCount == 0)
    #expect(ledger.records.isEmpty)
    // The same budget is accepted as a fallback.
    try Self.drive(&ledger, Self.call(.gemini, "g", budget, .fallback), replies: [nil], sends: &sends)
    #expect(sends == 1)
  }

  @Test("reported, absent, malformed and no-reply usage stay distinct in serialized records")
  func usageStatesSerializeDistinctly() throws {
    var ledger = Calls.Ledger()
    var sends = 0
    try Self.drive(
      &ledger, Self.call(.openAI, "gpt-x"),
      replies: [
        (200, #"{"usage":{"prompt_tokens":3,"completion_tokens":1}}"#),
        (200, #"{"choices":[]}"#),
        (200, #"{"usage":7,"note":"\#(Self.fakeKey)"}"#),
        nil,
      ], sends: &sends)
    #expect(
      ledger.records.map(\.usage) == [
        .reported(.init(input: 3, output: 1, thinking: nil, thinkingIncludedInOutput: true)),
        .absent, .malformed, nil,
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try ledger.records.map { String(decoding: try encoder.encode($0.usage), as: UTF8.self) }
    #expect(Set(encoded).count == 4)
    let json = String(decoding: try encoder.encode(ledger.records), as: UTF8.self)
    #expect(json.contains(Self.fakeKey) == false)
  }

  @Test("setting labels and the search menu are the D7 subset, in order")
  func settingLabels() {
    #expect(Self.s(.openAI(effort: .low, temperature: .omit), .openAI).label == "openAI:low/omit")
    #expect(
      Calls.Setting.searchMenu(.openAI).map(\.label) == [
        "openAI:omit/include", "openAI:omit/omit", "openAI:none/include", "openAI:none/omit",
        "openAI:minimal/include", "openAI:minimal/omit", "openAI:low/include", "openAI:low/omit",
      ])
    #expect(
      Calls.Setting.searchMenu(.gemini).map(\.label) == [
        "gemini:none", "gemini:level:minimal", "gemini:level:low", "gemini:level:medium",
        "gemini:level:high",
      ])
    #expect(
      Calls.Setting.searchMenu(.claude).map(\.label) == [
        "claude:thinkingDisabled", "claude:effortLow", "claude:thinkingBetweenTools",
      ])
    #expect(Calls.Setting.searchMenu(.ollama).isEmpty)
  }
}
