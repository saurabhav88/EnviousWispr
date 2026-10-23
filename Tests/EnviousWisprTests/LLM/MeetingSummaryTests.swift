import Foundation
import Testing
import os

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #3972 R39, R44 (build chunk C12): when these fail, a summary is written by a model that
/// cannot summarize, a long meeting overflows the model's window or loses words silently, a cut
/// answer is saved as a summary, a bad key is retried, or a local model starts work while the
/// user dictates.
@Suite("Meeting summary writer", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryTests {
  /// Records every call, answers from `answers` in order, and counts admissions.
  final class Calls: @unchecked Sendable {
    // Test-only recorder touched from the summary's sequential calls; never concurrently.
    var prompts: [String] = []
    var admissions = 0
    var answers: [Result<String, Error>] = []

    func complete(_ instructions: String, _ prompt: String) async throws -> String {
      prompts.append(prompt)
      guard !answers.isEmpty else { return "summary \(prompts.count)" }
      return try answers.removeFirst().get()
    }
  }

  /// Apple Intelligence's window today.
  static let small = MeetingSummary.Window(
    contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens,
    reportsOverflow: true)
  /// Ollama's summary window: silent overflow, so planned with the byte bound.
  static let silent = MeetingSummary.Window(
    contextTokens: 8_192, outputReserveTokens: 3_548, reportsOverflow: false)
  static let large = MeetingSummary.Window(
    contextTokens: 128_000, outputReserveTokens: 9_500, reportsOverflow: true)

  /// Whether a call's prompt, with the instructions beside it, fits `window` when counted as
  /// UTF-8 bytes, a count no tokenizer's token count exceeds. Independent of the planner's
  /// estimate.
  static func fitsInBytes(_ prompt: String, _ window: MeetingSummary.Window) -> Bool {
    prompt.utf8.count + MeetingSummary.instructions.utf8.count
      <= window.contextTokens - window.outputReserveTokens - MeetingSummary.safetyMarginTokens
  }

  /// The same, counted with the planner's estimate (for windows that report an overflow).
  static func fitsInEstimate(_ prompt: String, _ window: MeetingSummary.Window) -> Bool {
    MeetingSummary.estimatedTokens(prompt)
      + MeetingSummary.estimatedTokens(MeetingSummary.instructions)
      <= window.contextTokens - window.outputReserveTokens - MeetingSummary.safetyMarginTokens
  }

  static func write(
    _ calls: Calls, transcript: String, notes: String = "",
    window: MeetingSummary.Window = large, timeout: Double = 60
  ) async throws -> String {
    try await MeetingSummary.write(
      transcript: transcript, notes: notes, window: window, callTimeoutSeconds: timeout,
      admit: { calls.admissions += 1 }, complete: calls.complete)
  }

  @Test("every provider has a capability; cleanup models are refused under any provider")
  func capabilityMatrix() {
    let hosted = MeetingSummary.Capability.supported(.hosted)
    let local = MeetingSummary.Capability.supported(.local)
    func of(_ provider: LLMProvider, _ model: String = "m", remote: Bool? = nil)
      -> MeetingSummary.Capability
    {
      MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: remote)
    }
    #expect(of(.openAI) == hosted)
    #expect(of(.gemini) == hosted)
    #expect(of(.claude) == hosted)
    #expect(of(.ollama, "llama3.2", remote: false) == local)
    #expect(of(.ollama, "gpt-oss:120b-cloud", remote: true) == hosted)
    #expect(
      of(.ollama, "llama3.2", remote: nil) == local,
      "an Ollama model of unknown location waits for dictation like a local one")
    #expect(of(.appleIntelligence) == local)
    #expect(of(.egOne) == .notForSummaries)
    #expect(of(.s1Mini) == .notForSummaries)
    #expect(of(.none) == .noProvider)
    // The cleanup models picked through Ollama, with any tag or case.
    #expect(of(.ollama, "eg-1", remote: false) == .notForSummaries)
    #expect(of(.ollama, "eg-1:q4", remote: false) == .notForSummaries)
    #expect(of(.ollama, "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M") == .notForSummaries)
    // Similar names are other models.
    #expect(of(.ollama, "eg-10", remote: false) == local)
    #expect(of(.ollama, "s1-mini-acme", remote: false) == local)
    // Every case is covered: a new provider must be classified here.
    for provider in LLMProvider.allCases { _ = of(provider) }
  }

  @Test("the estimate counts every script; the byte count is the UTF-8 length")
  func counting() {
    #expect(MeetingSummary.estimatedTokens("") == 0)
    #expect(MeetingSummary.estimatedTokens("abc def gh") == 4)
    #expect(MeetingSummary.estimatedTokens("2026") == 4)
    #expect(MeetingSummary.estimatedTokens("会議の議事録") == 6)
    #expect(MeetingSummary.estimatedTokens("Привет") == 6)
    #expect(MeetingSummary.estimatedTokens("café") == 2)
    for text in ["abc def gh", "会議の議事録", "Привет", "café", "👍🏽"] {
      #expect(MeetingSummary.tokens(text, .bytes) == text.utf8.count)
    }
    #expect(MeetingSummary.prefix("会議の議事録", tokens: 4, .estimate) == "会議の議")
    #expect(MeetingSummary.prefix("会議の議事録", tokens: 7, .bytes) == "会議")
    #expect(
      MeetingSummary.prefix("👍🏽👍🏽", tokens: 3, .estimate) == "👍🏽", "never splits a character")
  }

  @Test("one character larger than a whole part is cut between its scalars and the cut ends")
  func oversizedCharacter() async throws {
    // One grapheme: a letter with 5,000 combining marks (10,001 bytes).
    let huge = "a" + String(repeating: "\u{0301}", count: 5_000)
    #expect(huge.count == 1)
    let text = "before\n" + huge + "\nafter"
    for counting in [MeetingSummary.Counting.estimate, .bytes] {
      let budget = try MeetingSummary.inputBudget(Self.small, counting)
      let parts = MeetingSummary.parts(of: text, budget: budget, counting)
      #expect(parts.count > 1)
      #expect(parts.allSatisfy { MeetingSummary.tokens($0, counting) <= budget })
      // Lines are cut at their ends and the long line between its scalars: every scalar but
      // the two line breaks is in exactly one part.
      #expect(
        parts.joined().unicodeScalars.filter { $0 != "\n" }.count
          == text.unicodeScalars.filter { $0 != "\n" }.count, "no scalar lost or added")
      #expect(parts.allSatisfy { !$0.isEmpty })
    }
    let calls = Calls()
    _ = try await Self.write(calls, transcript: text, window: Self.small)
    #expect(calls.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
  }

  @Test("a meeting that fits is one call with the notes; a long one is parts plus one join")
  func mapReduce() async throws {
    let short = Calls()
    let one = try await Self.write(short, transcript: "You: we ship Friday", notes: "Ask Priya")
    #expect(one == "summary 1")
    #expect(short.prompts.count == 1)
    #expect(short.prompts[0].contains("Ask Priya"))
    #expect(short.prompts[0].contains("You: we ship Friday"))

    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 150).joined(separator: "\n")
    let long = Calls()
    _ = try await Self.write(long, transcript: transcript, window: Self.small)
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let parts = MeetingSummary.parts(of: transcript, budget: budget, .estimate)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { MeetingSummary.estimatedTokens($0) <= budget })
    #expect(parts.joined(separator: "\n") == transcript, "no words lost or added by the cut")
    #expect(long.prompts.count == parts.count + 1, "one call per part and one join")
    #expect(long.prompts.last?.contains("Join them into one summary") == true)
    #expect(long.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    #expect(long.admissions == long.prompts.count, "admitted before every attempt")
  }

  static let lines = [
    "Speaker 1: " + String(repeating: "word ", count: 40),
    "話者1: " + String(repeating: "会議の議事録", count: 30),
  ]

  @Test(
    "a window that drops words silently is planned with the byte bound, in any script",
    arguments: lines)
  func silentWindowUsesBytes(line: String) async throws {
    // 120 lines: about 22,000 bytes of English or 66,000 of Japanese, under the 64-call limit
    // in bytes on Ollama's window (`tooLong` covers a meeting over it).
    let transcript = Array(repeating: line, count: 120).joined(separator: "\n")
    let long = Calls()
    long.answers = Array(
      repeating: .success(String(repeating: line + "\n", count: 40)), count: 200)
    let summary = try await Self.write(
      long, transcript: transcript, notes: "Ask Priya", window: Self.silent)
    #expect(!summary.isEmpty)
    #expect(
      long.prompts.allSatisfy { Self.fitsInBytes($0, Self.silent) },
      "every call fits the window counted in bytes, a bound for every tokenizer")
    #expect(long.prompts.last?.contains("Ask Priya") == true, "notes reach the final call")
    #expect(long.prompts.dropLast().allSatisfy { !$0.contains("Ask Priya") })
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "Ask Priya", window: Self.silent, counting: .bytes)
    #expect(long.prompts.count <= plan.worstCaseCalls)
  }

  @Test(
    "on a small window, long answers are combined in rounds and every call fits, in any script",
    arguments: lines)
  func smallWindowRounds(line: String) async throws {
    let transcript = Array(repeating: line, count: 300).joined(separator: "\n")
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let parts = MeetingSummary.parts(of: transcript, budget: budget, .estimate)
    #expect(parts.joined(separator: "\n") == transcript)
    let long = Calls()
    long.answers = Array(
      repeating: .success(String(repeating: line + "\n", count: 40)), count: 200)
    let summary = try await Self.write(
      long, transcript: transcript, notes: "Ask Priya", window: Self.small)
    #expect(!summary.isEmpty)
    #expect(long.prompts.count > parts.count + 1, "the answers needed at least one combine round")
    #expect(long.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "Ask Priya", window: Self.small, counting: .estimate)
    #expect(long.prompts.count <= plan.worstCaseCalls)
  }

  @Test("a reported overflow re-plans once with the byte bound; a second one is too long")
  func overflowReplans() async throws {
    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 150).joined(separator: "\n")
    let once = Calls()
    once.answers = [.failure(LLMError.classified(.inputTooLong))]
    _ = try await Self.write(once, transcript: transcript, window: Self.small)
    let estimateFirst = MeetingSummary.parts(
      of: transcript, budget: try MeetingSummary.inputBudget(Self.small, .estimate), .estimate)
    let bytes = try MeetingSummary.plan(
      transcript: transcript, notes: "", window: Self.small, counting: .bytes)
    #expect(once.prompts.first?.contains(estimateFirst[0]) == true, "the estimate went first")
    #expect(once.prompts.count == 1 + (bytes.pieces?.count ?? 0) + 1, "then the byte plan, whole")
    #expect(once.prompts.dropFirst().allSatisfy { Self.fitsInBytes($0, Self.small) })

    let always = Calls()
    always.answers = Array(repeating: .failure(LLMError.classified(.inputTooLong)), count: 10)
    await #expect(throws: MeetingSummary.Failure.tooLong) {
      _ = try await Self.write(always, transcript: transcript, window: Self.small)
    }
    #expect(always.prompts.count == 2, "one try per plan, never retried")
  }

  @Test("notes too long for the final call are summarized in parts, not dropped or cut")
  func longNotes() async throws {
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let notes = Array(repeating: "my note line", count: budget / 3).joined(separator: "\n")
    let transcript = String(repeating: "t ", count: budget * 2)
    let calls = Calls()
    _ = try await Self.write(calls, transcript: transcript, notes: notes, window: Self.small)
    #expect(
      calls.prompts.contains { $0.contains("the user's own notes") && $0.contains("my note") })
    #expect(calls.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    #expect(calls.prompts.last?.contains("my note line") == false)
    let sent = calls.prompts.joined()
    #expect(sent.components(separatedBy: "my note line").count - 1 >= budget / 3)
  }

  @Test("notes count toward the window")
  func notesCountTowardTheWindow() throws {
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let plan = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 30) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small, counting: .estimate)
    #expect(plan.pieces != nil)
    let fits = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 100) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small, counting: .estimate)
    #expect(fits.pieces == nil)
  }

  @Test("a window too small for any transcript is refused before any call, never enlarged")
  func windowTooSmall() async throws {
    let calls = Calls()
    await #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try await Self.write(
        calls, transcript: "t",
        window: MeetingSummary.Window(
          contextTokens: 2_048, outputReserveTokens: 1_500, reportsOverflow: true))
    }
    #expect(calls.prompts.isEmpty)
  }

  @Test("a meeting needing more than the call limit is refused before any call")
  func tooLong() async throws {
    for window in [Self.small, Self.silent] {
      let calls = Calls()
      let transcript = String(repeating: "会", count: 4_000 * (MeetingSummary.maxCalls + 2))
      await #expect(throws: MeetingSummary.Failure.tooLong) {
        _ = try await Self.write(calls, transcript: transcript, window: window)
      }
      #expect(calls.prompts.isEmpty)
    }
  }

  @Test("the shared retry policy decides; each try is admitted; at most two retries")
  func retries() async throws {
    let flaky = Calls()
    flaky.answers = [
      .failure(LLMError.classified(.rateLimited)),
      .failure(LLMError.classified(.providerServerError)), .success("ok"),
    ]
    #expect(try await Self.write(flaky, transcript: "t") == "ok")
    #expect(flaky.prompts.count == 3)
    #expect(flaky.admissions == 3, "every attempt waits for admission again")

    let down = Calls()
    down.answers = Array(repeating: .failure(URLError(.timedOut)), count: 5)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await Self.write(down, transcript: "t")
    }
    #expect(down.prompts.count == 3, "one call and two retries, never more")

    for failFast in [PolishFailureReason.apiKeyRejected, .outOfCredits, .rateLimitedOrQuota] {
      let calls = Calls()
      calls.answers = [.failure(LLMError.classified(failFast))]
      await #expect(throws: MeetingSummary.Failure.providerFailed) {
        _ = try await Self.write(calls, transcript: "t")
      }
      #expect(calls.prompts.count == 1, "\(failFast) is not retried")
    }

    let empty = Calls()
    empty.answers = [.success("   ")]
    await #expect(throws: MeetingSummary.Failure.empty) {
      _ = try await Self.write(empty, transcript: "t")
    }
  }

  @Test("cancellation during admission starts no call; a cancelled request is not retried")
  func cancellation() async throws {
    let calls = Calls()
    let task = Task {
      try await MeetingSummary.write(
        transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 60,
        admit: { withUnsafeCurrentTask { $0?.cancel() } }, complete: calls.complete)
    }
    await #expect(throws: MeetingSummary.Failure.cancelled) { _ = try await task.value }
    #expect(calls.prompts.isEmpty, "the admission returned after cancel; no call started")

    let transport = Calls()
    transport.answers = [.failure(URLError(.cancelled)), .success("late")]
    await #expect(throws: MeetingSummary.Failure.cancelled) {
      _ = try await Self.write(transport, transcript: "t")
    }
    #expect(transport.prompts.count == 1)
  }

  @Test("a call past its time limit is stopped, ended and not tried again")
  func timeLimit() async throws {
    let calls = Calls()
    let ended = Calls()
    await #expect(throws: MeetingSummary.Failure.timedOut) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 0.05,
        admit: {},
        complete: { instructions, prompt in
          _ = try await calls.complete(instructions, prompt)
          do {
            // deadline-fallback: the model that never answers; only the time limit ends it.
            try await Task.sleep(for: .seconds(3_600))
          } catch {
            ended.prompts.append("cancelled")
            throw error
          }
          return "late"
        })
    }
    #expect(calls.prompts.count == 1, "a timed-out call is not tried again")
    #expect(ended.prompts == ["cancelled"], "the call ended before the writer returned")
  }

  @Test("the configuration fingerprint changes with the model and never carries a key")
  func fingerprint() {
    let a = MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4o-mini")
    let b = MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4.1")
    let c = MeetingSummary.configurationFingerprint(provider: .gemini, model: "gpt-4o-mini")
    #expect(a != b)
    #expect(a != c)
    #expect(a == MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4o-mini"))
    #expect(a.count == 64)
  }

  // MARK: - Providers

  /// An isolated key folder: never the real Keychain or key files.
  static func keychain() -> KeychainManager {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "ew-tests-3972-summary-\(UUID().uuidString)")
    return KeychainManager(
      backend: .legacyFiles, legacyStore: FileLegacyKeyStore(storageDirectory: folder))
  }

  /// Counts readiness probes and network requests, and answers each request from `replies`
  /// (text and Ollama's `done_reason`).
  final class Ollama: @unchecked Sendable {
    // Test-only recorder; the summary's calls run one after another.
    var probes = 0
    var requests: [[String: Any]] = []
    var replies: [Result<(String, String), Error>] = []
    let facts: OllamaModelFacts?

    init(facts: OllamaModelFacts?) { self.facts = facts }

    func readiness(_ model: String) async -> OllamaReadiness {
      probes += 1
      guard let facts else { return .serverDown }
      return .ready(facts: facts)
    }

    func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
      // swift-patterns RULE: fake-executor-must-yield-before-throw.
      await Task.yield()
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
      requests.append(body as? [String: Any] ?? [:])
      let (text, done) = try
        (replies.isEmpty ? .success(("summary", "stop")) : replies.removeFirst())
        .get()
      let reply = try JSONSerialization.data(withJSONObject: [
        "message": ["role": "assistant", "content": text], "done": true, "done_reason": done,
      ])
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (reply, response)
    }
  }

  static func prepare(_ provider: LLMProvider, _ model: String, _ ollama: Ollama) async
    -> Result<MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable>
  {
    await MeetingSummaryProviders.prepare(
      provider: provider, model: model, keychain: keychain(),
      ollamaReadiness: { await ollama.readiness($0) },
      ollamaExecutor: { try await ollama.execute($0) })
  }

  @Test("cleanup models and no provider are refused before Ollama is asked or called")
  func refusedProviders() async {
    let cases: [(LLMProvider, String)] = [
      (.egOne, ""), (.s1Mini, ""), (.none, ""), (.ollama, "eg-1:q4"),
      (.ollama, "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"),
    ]
    for (provider, model) in cases {
      let ollama = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
      let result = await Self.prepare(provider, model, ollama)
      #expect(
        result.failureValue == (provider == .none ? .noProvider : .notForSummaries),
        "\(provider) \(model)")
      #expect(ollama.probes == 0)
      #expect(ollama.requests.isEmpty)
    }
    let down = Ollama(facts: nil)
    #expect(await Self.prepare(.ollama, "llama3.2", down).failureValue == .notReady)
  }

  @Test(
    "an Ollama summary runs where the daemon says, in its planned window, without connector retries"
  )
  func ollamaRequests() async throws {
    let local = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: true))
    let prepared = try #require(await Self.prepare(.ollama, "qwen3", local).successValue)
    #expect(prepared.execution == .local)
    #expect(prepared.window.contextTokens == MeetingSummaryProviders.ollamaContextTokens)
    #expect(prepared.window.reportsOverflow == false)
    // Every request fails: the summary's own one call and two retries are the only requests,
    // so a connector that also retried would multiply them.
    local.replies = Array(repeating: .failure(URLError(.timedOut)), count: 20)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
        complete: prepared.complete)
    }
    #expect(local.requests.count == 3, "the connector tries once; the summary owns the retries")
    let options = try #require(local.requests.first?["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == MeetingSummaryProviders.ollamaContextTokens)
    #expect(options["num_predict"] as? Int == prepared.window.outputReserveTokens)
    #expect(local.requests.first?["think"] as? String == "low", "the same thinking rule as polish")

    local.replies = []
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
      complete: prepared.complete)
    #expect(summary == "summary")

    let hosted = Ollama(facts: OllamaModelFacts(isRemote: true, thinks: false))
    let remote = try #require(
      await Self.prepare(.ollama, "gpt-oss:120b-cloud", hosted).successValue)
    #expect(remote.execution == .hosted)
    #expect(remote.window.outputReserveTokens == MeetingSummary.outputTokens)
  }

  @Test("an Ollama answer cut at its output cap is refused, not saved as a summary")
  func ollamaTruncation() async throws {
    let local = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
    let prepared = try #require(await Self.prepare(.ollama, "llama3.2", local).successValue)
    local.replies = [.success(("## Overview\nThe team agreed to", "length"))]
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
        complete: prepared.complete)
    }
    #expect(local.requests.count == 1, "a cut answer is not retried")
  }

  @Test("polish requests keep the daemon's window: no num_ctx unless a caller sets one")
  func polishBodyUnchanged() {
    let body = OllamaConnector.makeRequestBody(
      model: "m", messages: [], maxTokens: 256, temperature: 0, thinking: nil)
    let options = body["options"] as? [String: Any]
    #expect(options?["num_ctx"] == nil)
    #expect(options?.count == 2)
  }

  @Test("each hosted profile sends the output cap it reserves; unknown models are planned small")
  func hostedProfiles() async throws {
    func window(_ provider: LLMProvider, _ model: String) -> Int {
      MeetingSummaryProviders.hostedContextTokens(provider, model: model)
    }
    #expect(window(.openAI, "gpt-4o-mini") == 128_000)
    #expect(window(.openAI, "gpt-4") == 8_000)
    #expect(window(.openAI, "gpt-3.5-turbo") == 8_000)
    #expect(window(.gemini, "gemini-2.5-flash") == 128_000)
    #expect(window(.gemini, "gemini-1.0-pro") == 8_000)
    #expect(window(.claude, "claude-sonnet-5-5") == 128_000)
    #expect(window(.claude, "claude-2.1") == 8_000)

    for (provider, model) in [
      (LLMProvider.openAI, "gpt-4o-mini"), (.openAI, "o3"), (.openAI, "gpt-4"),
      (.gemini, "gemini-2.5-flash"), (.claude, "claude-sonnet-5-5"),
    ] {
      let prepared = try #require(
        await MeetingSummaryProviders.prepare(
          provider: provider, model: model, keychain: Self.keychain()
        )
        .successValue)
      let config = MeetingSummaryProviders.hostedConfig(provider, model: model, keyID: "k")
      #expect(config.outputTokens == .capped(prepared.window.outputReserveTokens), "\(model)")
      #expect(config.maxRetries == 0)
      #expect(prepared.window.reportsOverflow)
    }
    #expect(MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "o3") == 9_500)
    #expect(MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "gpt-4o-mini") == 1_500)

    // An unknown model that may think does not fit the small planning window: refused before
    // any call. An unknown model that does not think fits it.
    let gemini10 = MeetingSummary.Window(
      contextTokens: window(.gemini, "gemini-1.0-pro"),
      outputReserveTokens: MeetingSummaryProviders.hostedOutputTokens(
        .gemini, model: "gemini-1.0-pro"),
      reportsOverflow: true)
    let calls = Calls()
    await #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try await Self.write(calls, transcript: "t", window: gemini10)
    }
    #expect(calls.prompts.isEmpty)
    let gpt4 = MeetingSummary.Window(
      contextTokens: window(.openAI, "gpt-4"),
      outputReserveTokens: MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "gpt-4"),
      reportsOverflow: true)
    #expect(try await Self.write(Calls(), transcript: "t", window: gpt4) == "summary 1")
  }

  // MARK: - The real OpenAI connector

  struct TestKey: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String { "sk-test-not-a-real-key" }
    func delete(key: String) throws {}
  }

  /// Pops one scripted HTTP reply per request and counts requests.
  final class Script: Sendable {
    private let state: OSAllocatedUnfairLock<(replies: [(Int, String)], bodies: [Data])>

    init(_ replies: [(Int, String)]) {
      state = OSAllocatedUnfairLock(initialState: (replies: replies, bodies: []))
    }

    var requests: Int { state.withLock { $0.bodies.count } }

    func body(_ index: Int) -> [String: Any] {
      let data = state.withLock { $0.bodies[index] }
      return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func executor() -> OpenAIConnector.RequestExecutor {
      { request, _ in
        // swift-patterns RULE: fake-executor-must-yield-before-throw.
        await Task.yield()
        return try self.state.withLock { state in
          state.bodies.append(request.httpBody ?? Data())
          guard !state.replies.isEmpty else { throw URLError(.badServerResponse) }
          let (code, body) = state.replies.removeFirst()
          let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
          return (Data(body.utf8), response)
        }
      }
    }
  }

  static let ok = (
    200, #"{"choices": [{"message": {"content": "Summary."}, "finish_reason": "stop"}]}"#
  )
  static let rateLimit = (429, #"{"error": {"type": "requests", "message": "Rate limit reached"}}"#)
  static let quota = (
    429, #"{"error": {"type": "insufficient_quota", "code": "insufficient_quota"}}"#
  )
  static let busy = (503, #"{"error": {"message": "The server is overloaded"}}"#)
  static let badKey = (401, #"{"error": {"message": "Incorrect API key provided"}}"#)
  static let tooLongReply = (
    400, #"{"error": {"code": "context_length_exceeded", "message": "maximum context length"}}"#
  )
  static let cut = (
    200, #"{"choices": [{"message": {"content": "Summary"}, "finish_reason": "length"}]}"#
  )

  static func openAI(_ script: Script, model: String = "gpt-4o-mini") -> MeetingSummary.Complete {
    MeetingSummaryProviders.envelope(
      OpenAIConnector(
        keychainManager: KeychainManager(backend: .legacyFiles, legacyStore: TestKey()),
        requestExecutor: script.executor()),
      MeetingSummaryProviders.hostedConfig(
        .openAI, model: model, keyID: KeychainManager.openAIKeyID))
  }

  @Test(
    "real OpenAI replies: busy and rate-limited are retried and admitted; quota and key are not")
  func openAIReplies() async throws {
    let retried = Script([Self.rateLimit, Self.busy, Self.ok])
    let admissions = Calls()
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 60,
      admit: { admissions.admissions += 1 }, complete: Self.openAI(retried))
    #expect(summary == "Summary.")
    #expect(retried.requests == 3)
    #expect(admissions.admissions == 3)
    #expect(retried.body(0)["max_completion_tokens"] as? Int == MeetingSummary.outputTokens)

    for failFast in [Self.quota, Self.badKey] {
      let script = Script([failFast, Self.ok])
      await #expect(throws: MeetingSummary.Failure.providerFailed) {
        _ = try await MeetingSummary.write(
          transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
          complete: Self.openAI(script))
      }
      #expect(script.requests == 1, "HTTP \(failFast.0) is not retried")
    }

    let cut = Script([Self.cut])
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
        complete: Self.openAI(cut))
    }
    #expect(cut.requests == 1)
  }

  @Test("a real OpenAI context-length error re-plans with the byte bound")
  func openAIOverflow() async throws {
    let script = Script([Self.tooLongReply, Self.ok])
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
      complete: Self.openAI(script))
    #expect(summary == "Summary.")
    #expect(script.requests == 2)
  }
}

extension Result {
  fileprivate var successValue: Success? { try? get() }
  fileprivate var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
