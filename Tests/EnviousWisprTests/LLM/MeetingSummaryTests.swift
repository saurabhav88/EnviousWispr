import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #3972 R39, R44 (build chunk C12): when these fail, a summary is written by a model that
/// cannot summarize, a long meeting overflows the model's window or makes unbounded attempts, a
/// bad key is retried, or a local model starts work while the user dictates.
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
    contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens)
  static let large = MeetingSummary.Window(contextTokens: 128_000, outputReserveTokens: 9_500)

  /// Whether a call's prompt, with the instructions beside it, fits `window`.
  static func fits(_ prompt: String, _ window: MeetingSummary.Window) -> Bool {
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

  @Test("the token estimate is never below one token per non-Latin character or per digit")
  func estimate() {
    #expect(MeetingSummary.estimatedTokens("") == 0)
    #expect(MeetingSummary.estimatedTokens("abc def gh") == 4)
    #expect(MeetingSummary.estimatedTokens("2026") == 4)
    #expect(MeetingSummary.estimatedTokens("会議の議事録") == 6)
    #expect(MeetingSummary.estimatedTokens("Привет") == 6)
    #expect(MeetingSummary.estimatedTokens("café") == 2)
    #expect(MeetingSummary.prefix("会議の議事録", tokens: 4) == "会議の議")
    #expect(MeetingSummary.prefix("👍🏽👍🏽", tokens: 3) == "👍🏽", "never splits a character")
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
    let budget = try MeetingSummary.inputBudget(Self.small)
    let parts = MeetingSummary.parts(of: transcript, budget: budget)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { MeetingSummary.estimatedTokens($0) <= budget })
    #expect(parts.joined(separator: "\n") == transcript, "no words lost or added by the cut")
    #expect(long.prompts.count == parts.count + 1, "one call per part and one join")
    #expect(long.prompts.last?.contains("Join them into one summary") == true)
    #expect(long.prompts.allSatisfy { Self.fits($0, Self.small) })
    #expect(long.admissions == long.prompts.count, "admitted before every attempt")
  }

  @Test(
    "on a small window, long answers are combined in rounds and every call fits, in any script",
    arguments: [
      "Speaker 1: " + String(repeating: "word ", count: 40),
      "話者1: " + String(repeating: "会議の議事録", count: 30),
    ])
  func smallWindowRounds(line: String) async throws {
    let transcript = Array(repeating: line, count: 300).joined(separator: "\n")
    let budget = try MeetingSummary.inputBudget(Self.small)
    let parts = MeetingSummary.parts(of: transcript, budget: budget)
    #expect(parts.joined(separator: "\n") == transcript)
    // Every answer is far over the kept length, in the transcript's own script.
    let long = Calls()
    long.answers = Array(
      repeating: .success(String(repeating: line + "\n", count: 40)), count: 200)
    let summary = try await Self.write(
      long, transcript: transcript, notes: "Ask Priya", window: Self.small)
    #expect(!summary.isEmpty)
    #expect(long.prompts.count > parts.count + 1, "the answers needed at least one combine round")
    #expect(long.prompts.allSatisfy { Self.fits($0, Self.small) }, "no call overflows the window")
    #expect(long.prompts.last?.contains("Ask Priya") == true, "notes reach the final call")
    #expect(long.prompts.dropLast().allSatisfy { !$0.contains("Ask Priya") })
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "Ask Priya", window: Self.small)
    #expect(long.prompts.count <= plan.worstCaseCalls)
  }

  @Test("notes too long for the final call are summarized in parts, not dropped or cut")
  func longNotes() async throws {
    let budget = try MeetingSummary.inputBudget(Self.small)
    let notes = Array(repeating: "my note line", count: budget / 3).joined(separator: "\n")
    let transcript = String(repeating: "t ", count: budget * 2)
    let calls = Calls()
    _ = try await Self.write(calls, transcript: transcript, notes: notes, window: Self.small)
    #expect(
      calls.prompts.contains { $0.contains("the user's own notes") && $0.contains("my note") })
    #expect(calls.prompts.allSatisfy { Self.fits($0, Self.small) })
    #expect(calls.prompts.last?.contains("my note line") == false)
    let sent = calls.prompts.joined()
    #expect(sent.components(separatedBy: "my note line").count - 1 >= budget / 3)
  }

  @Test("notes count toward the window")
  func notesCountTowardTheWindow() throws {
    let budget = try MeetingSummary.inputBudget(Self.small)
    let plan = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 30) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small)
    #expect(plan.pieces != nil)
    let fits = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 100) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small)
    #expect(fits.pieces == nil)
  }

  @Test("a window too small for any transcript is refused before any call, never enlarged")
  func windowTooSmall() async throws {
    let calls = Calls()
    await #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try await Self.write(
        calls, transcript: "t",
        window: MeetingSummary.Window(contextTokens: 2_048, outputReserveTokens: 1_500))
    }
    #expect(calls.prompts.isEmpty)
  }

  @Test("a meeting needing more than the call limit is refused before any call")
  func tooLong() async throws {
    let calls = Calls()
    let transcript = String(repeating: "会", count: 4_000 * (MeetingSummary.maxCalls + 2))
    await #expect(throws: MeetingSummary.Failure.tooLong) {
      _ = try await Self.write(calls, transcript: transcript, window: Self.small)
    }
    #expect(calls.prompts.isEmpty)
  }

  @Test("network and rate-limit failures are tried at most twice more; each try is admitted")
  func retries() async throws {
    let flaky = Calls()
    flaky.answers = [.failure(LLMError.rateLimited), .failure(URLError(.timedOut)), .success("ok")]
    #expect(try await Self.write(flaky, transcript: "t") == "ok")
    #expect(flaky.prompts.count == 3)
    #expect(flaky.admissions == 3, "every attempt waits for admission again")

    let down = Calls()
    down.answers = Array(repeating: .failure(LLMError.rateLimited), count: 5)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await Self.write(down, transcript: "t")
    }
    #expect(down.prompts.count == 3, "one call and two retries, never more")

    let badKey = Calls()
    badKey.answers = [.failure(LLMError.invalidAPIKey)]
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await Self.write(badKey, transcript: "t")
    }
    #expect(badKey.prompts.count == 1)

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

  /// Counts readiness probes and network requests, and answers each request from `replies`.
  final class Ollama: @unchecked Sendable {
    // Test-only recorder; the summary's calls run one after another.
    var probes = 0
    var requests: [[String: Any]] = []
    var replies: [Result<String, Error>] = []
    let facts: OllamaModelFacts?

    init(facts: OllamaModelFacts?) { self.facts = facts }

    func readiness(_ model: String) async -> OllamaReadiness {
      probes += 1
      guard let facts else { return .serverDown }
      return .ready(facts: facts)
    }

    func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
      requests.append(body as? [String: Any] ?? [:])
      let text = try (replies.isEmpty ? .success("summary") : replies.removeFirst()).get()
      let reply = try JSONSerialization.data(withJSONObject: [
        "message": ["role": "assistant", "content": text], "done": true, "done_reason": "stop",
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
    // Every request fails: the summary's own one call and two retries are the only requests,
    // so a connector that also retried would multiply them.
    local.replies = Array(repeating: .failure(URLError(.timedOut)), count: 20)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
        complete: prepared.complete)
    }
    #expect(local.requests.count == 3, "the connector tries once; the summary owns the retries")
    local.replies = []
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
      complete: prepared.complete)
    #expect(summary == "summary")
    let options = try #require(local.requests.first?["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == MeetingSummaryProviders.ollamaContextTokens)
    #expect(options["num_predict"] as? Int == prepared.window.outputReserveTokens)
    #expect(local.requests.first?["think"] as? String == "low", "the same thinking rule as polish")

    let hosted = Ollama(facts: OllamaModelFacts(isRemote: true, thinks: false))
    let remote = try #require(
      await Self.prepare(.ollama, "gpt-oss:120b-cloud", hosted).successValue)
    #expect(remote.execution == .hosted)
    #expect(remote.window.outputReserveTokens == MeetingSummary.outputTokens)
  }

  @Test("polish requests keep the daemon's window: no num_ctx unless a caller sets one")
  func polishBodyUnchanged() {
    let body = OllamaConnector.makeRequestBody(
      model: "m", messages: [], maxTokens: 256, temperature: 0, thinking: nil)
    let options = body["options"] as? [String: Any]
    #expect(options?["num_ctx"] == nil)
    #expect(options?.count == 2)
  }

  @Test("hosted windows are planned small for models outside the known families")
  func hostedWindows() {
    func window(_ provider: LLMProvider, _ model: String) -> Int {
      MeetingSummaryProviders.hostedContextTokens(provider, model: model)
    }
    #expect(window(.openAI, "gpt-4o-mini") == 128_000)
    #expect(window(.openAI, "gpt-4") == 8_000)
    #expect(window(.openAI, "gpt-3.5-turbo") == 8_000)
    #expect(window(.gemini, "gemini-2.5-flash") == 128_000)
    #expect(window(.claude, "claude-sonnet-5-5") == 128_000)
  }
}

extension Result {
  fileprivate var successValue: Success? { try? get() }
  fileprivate var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
