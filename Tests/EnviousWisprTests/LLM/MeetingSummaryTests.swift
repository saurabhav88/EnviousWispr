import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #3972 R39, R44 (build chunk C12): when these fail, a summary is written by a model that
/// cannot summarize, a long meeting overflows the provider's window or makes unbounded calls, a
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

  @Test("every selectable provider has a capability, and the cleanup models are refused")
  func capabilityMatrix() {
    let hosted = MeetingSummary.Capability.supported(.hosted)
    let local = MeetingSummary.Capability.supported(.local)
    #expect(MeetingSummary.capability(.openAI, ollamaModelIsRemote: nil) == hosted)
    #expect(MeetingSummary.capability(.gemini, ollamaModelIsRemote: nil) == hosted)
    #expect(MeetingSummary.capability(.claude, ollamaModelIsRemote: nil) == hosted)
    #expect(MeetingSummary.capability(.ollama, ollamaModelIsRemote: false) == local)
    #expect(MeetingSummary.capability(.ollama, ollamaModelIsRemote: true) == hosted)
    #expect(
      MeetingSummary.capability(.ollama, ollamaModelIsRemote: nil) == hosted,
      "an Ollama model of unknown location counts as hosted")
    #expect(MeetingSummary.capability(.appleIntelligence, ollamaModelIsRemote: nil) == local)
    #expect(MeetingSummary.capability(.egOne, ollamaModelIsRemote: nil) == .notForSummaries)
    #expect(MeetingSummary.capability(.s1Mini, ollamaModelIsRemote: nil) == .notForSummaries)
    #expect(MeetingSummary.capability(.none, ollamaModelIsRemote: nil) == .noProvider)
    // Every case is covered: a new provider must be classified here.
    for provider in LLMProvider.allCases {
      _ = MeetingSummary.capability(provider, ollamaModelIsRemote: nil)
    }
  }

  @Test("a meeting that fits is one call with the notes; a long one is parts plus one join")
  func mapReduce() async throws {
    let short = Calls()
    let one = try await MeetingSummary.write(
      transcript: "You: we ship Friday", notes: "Ask Priya", contextTokens: 100_000,
      admit: { short.admissions += 1 }, complete: short.complete)
    #expect(one == "summary 1")
    #expect(short.prompts.count == 1)
    #expect(short.prompts[0].contains("Ask Priya"))
    #expect(short.prompts[0].contains("You: we ship Friday"))

    // About 30,000 characters on a 4,096-token window: several parts, each within the budget.
    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 150).joined(separator: "\n")
    let long = Calls()
    _ = try await MeetingSummary.write(
      transcript: transcript, notes: "", contextTokens: 4_096, admit: { long.admissions += 1 },
      complete: long.complete)
    let budget = (4_096 - MeetingSummary.outputTokens - 700) * 3
    #expect(MeetingSummary.promptBudget(4_096) == budget)
    let parts = MeetingSummary.parts(of: transcript, budget: budget)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.count <= budget })
    #expect(parts.joined(separator: "\n") == transcript, "no words lost or added by the cut")
    #expect(long.prompts.count == parts.count + 1, "one call per part and one join")
    #expect(long.prompts.last?.contains("Join them into one summary") == true)
    #expect(long.admissions == long.prompts.count, "admitted before every call")
  }

  /// The framing every prompt adds around its content, at most: the final shape, labels and
  /// the instruction lines.
  static let framing = 900

  @Test("on a small window, long answers are combined in rounds and every call fits")
  func smallWindowRounds() async throws {
    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 300).joined(separator: "\n")
    let budget = MeetingSummary.promptBudget(4_096)
    let pieces = MeetingSummary.parts(of: transcript, budget: budget).count
    // Every answer is as long as a model might write: far over the kept length.
    let long = Calls()
    long.answers = Array(
      repeating: .success(String(repeating: "- point\n", count: 2_000)), count: 200)
    let summary = try await MeetingSummary.write(
      transcript: transcript, notes: "Ask Priya", contextTokens: 4_096,
      admit: { long.admissions += 1 }, complete: long.complete)
    #expect(!summary.isEmpty)
    #expect(long.prompts.count > pieces + 1, "the answers needed at least one combine round")
    #expect(long.prompts.count <= MeetingSummary.maxCalls)
    #expect(
      long.prompts.allSatisfy { $0.count <= budget + Self.framing },
      "no call carries more than the window holds")
    #expect(long.prompts.last?.contains("Ask Priya") == true, "notes reach the final call")
    #expect(
      long.prompts.dropLast().allSatisfy { !$0.contains("Ask Priya") },
      "short notes go only to the final call")
    let plan = try MeetingSummary.plan(transcript: transcript, notes: "", contextTokens: 4_096)
    #expect(long.prompts.count <= plan.worstCaseCalls)
  }

  @Test("notes too long for the final call are summarized in parts, not dropped or cut")
  func longNotes() async throws {
    let budget = MeetingSummary.promptBudget(4_096)
    let notes = Array(repeating: "my note line", count: budget / 10).joined(separator: "\n")
    let transcript = String(repeating: "t ", count: budget)
    let calls = Calls()
    _ = try await MeetingSummary.write(
      transcript: transcript, notes: notes, contextTokens: 4_096, admit: {},
      complete: calls.complete)
    #expect(
      calls.prompts.contains { $0.contains("the user's own notes") && $0.contains("my note") })
    #expect(calls.prompts.allSatisfy { $0.count <= budget + Self.framing })
    #expect(calls.prompts.last?.contains("my note line") == false)
    // Every note line reaches a call.
    let sent = calls.prompts.joined()
    #expect(sent.components(separatedBy: "my note line").count - 1 >= budget / 10)
  }

  @Test("a short meeting with notes that do not fit beside it is cut in parts")
  func notesCountTowardTheWindow() throws {
    let budget = MeetingSummary.promptBudget(4_096)
    let plan = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: budget - 100),
      notes: String(repeating: "n", count: 200), contextTokens: 4_096)
    #expect(plan.pieces != nil)
    let fits = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: budget - 300),
      notes: String(repeating: "n", count: 200), contextTokens: 4_096)
    #expect(fits.pieces == nil)
  }

  @Test("a meeting needing more than the call limit is refused before any call")
  func tooLong() async throws {
    let calls = Calls()
    let transcript = String(repeating: "x", count: 2_000 * (MeetingSummary.maxCalls + 2))
    await #expect(throws: MeetingSummary.Failure.tooLong) {
      _ = try await MeetingSummary.write(
        transcript: transcript, notes: "", contextTokens: 1, admit: {},
        complete: calls.complete)
    }
    #expect(calls.prompts.isEmpty)
  }

  @Test("network and rate-limit failures are tried at most twice more; a bad key is not")
  func retries() async throws {
    let flaky = Calls()
    flaky.answers = [.failure(LLMError.rateLimited), .failure(URLError(.timedOut)), .success("ok")]
    #expect(
      try await MeetingSummary.write(
        transcript: "t", notes: "", contextTokens: 100_000, admit: {}, complete: flaky.complete)
        == "ok")
    #expect(flaky.prompts.count == 3)

    let down = Calls()
    down.answers = Array(repeating: .failure(LLMError.rateLimited), count: 5)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", contextTokens: 100_000, admit: {}, complete: down.complete)
    }
    #expect(down.prompts.count == 3, "one call and two retries, never more")

    let badKey = Calls()
    badKey.answers = [.failure(LLMError.invalidAPIKey)]
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", contextTokens: 100_000, admit: {}, complete: badKey.complete)
    }
    #expect(badKey.prompts.count == 1)

    let empty = Calls()
    empty.answers = [.success("   ")]
    await #expect(throws: MeetingSummary.Failure.empty) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", contextTokens: 100_000, admit: {}, complete: empty.complete)
    }
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

  @Test("the cleanup models and no provider have no summary call")
  func noCallForUnsupported() {
    // An isolated key folder: never the real Keychain or key files.
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "ew-tests-3972-summary-\(UUID().uuidString)")
    let keychain = KeychainManager(
      backend: .legacyFiles, legacyStore: FileLegacyKeyStore(storageDirectory: folder))
    #expect(
      MeetingSummaryProviders.complete(provider: .egOne, model: "", keychain: keychain) == nil)
    #expect(
      MeetingSummaryProviders.complete(provider: .s1Mini, model: "", keychain: keychain) == nil)
    #expect(MeetingSummaryProviders.complete(provider: .none, model: "", keychain: keychain) == nil)
    #expect(
      MeetingSummaryProviders.complete(provider: .openAI, model: "m", keychain: keychain) != nil)
  }
}
